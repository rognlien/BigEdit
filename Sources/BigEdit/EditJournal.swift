import CryptoKit
import Foundation

/// Persists unsaved edits so they survive a crash or a forced quit.
///
/// A document's journal is a directory named by a hash of its path, holding:
///
/// - `bytes` — every inserted byte, appended in the same order as the
///   in-memory add buffer, so offsets in one are offsets in the other;
/// - `ops` — every splice since the last save, as a logical range and the
///   pieces put there;
/// - `manifest` — which file the ops apply to: its path, size, inode and
///   modification date. That is the *baseline*.
///
/// On relaunch, if the file on disk still matches the baseline, replaying the
/// ops over it rebuilds the document as it was. A save moves the baseline to
/// the freshly written file and empties the ops; the bytes file keeps growing,
/// as the add buffer does, until the document is closed cleanly.
///
/// Writes are appends without fsync: an application crash leaves the kernel's
/// buffers intact, and that is the failure this exists for. A kernel panic or
/// power loss may lose the last few operations.
final class EditJournal {

    let directory: URL
    private let bytesURL: URL
    private let operationsURL: URL
    private let manifestURL: URL
    private var bytesHandle: FileHandle?
    private var operationsHandle: FileHandle?

    /// Whether replaying the ops could rebuild the document. False once an
    /// operation referred to a mapping retired by an earlier save, which no
    /// relaunch can bring back; the journal then serves nothing and is
    /// discarded at the next opportunity.
    private(set) var isReplayable = true

    private static let manifestFormatVersion = 1
    private static let spliceKind: UInt8 = 1
    private static let unreplayableKind: UInt8 = 0xFF

    private init(directory: URL) {
        self.directory = directory
        self.bytesURL = directory.appendingPathComponent("bytes")
        self.operationsURL = directory.appendingPathComponent("ops")
        self.manifestURL = directory.appendingPathComponent("manifest.json")
    }

    // MARK: - Locating

    /// The root every journal lives under: Application Support, unless a test
    /// points it somewhere temporary.
    static var root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BigEdit/Journals", isDirectory: true)

    /// The journal directory for `path`, whether or not anything is in it.
    static func directory(for path: String, in root: URL = EditJournal.root) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Opens the journal for `path`, creating its directory. Nothing in it is
    /// touched: a pending journal from a crashed run stays pending until the
    /// caller decides to recover it or start fresh.
    static func open(for path: String, in root: URL = EditJournal.root) -> EditJournal {
        let directory = directory(for: path, in: root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return EditJournal(directory: directory)
    }

    // MARK: - The baseline

    private struct Manifest: Codable {
        var version: Int
        var path: String
        var size: Int
        var inode: UInt64
        var modified: Double
    }

    /// Makes `file` the baseline: records what it is and empties the ops.
    /// Called on open (when nothing is pending) and after every save.
    ///
    /// The bytes file mirrors the add buffer offset for offset, so it is kept
    /// only if the buffer carried over (`retainingAddedBytes`); a document
    /// starting with an empty buffer starts with an empty bytes file.
    func setBaseline(_ file: MappedFile, retainingAddedBytes: Bool = false) {
        operationsHandle?.closeFile()
        operationsHandle = nil
        try? Data().write(to: operationsURL)
        if !retainingAddedBytes {
            bytesHandle?.closeFile()
            bytesHandle = nil
            try? Data().write(to: bytesURL)
        }
        isReplayable = true
        if let manifest = EditJournal.manifest(describing: file),
           let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }
    }

    /// Whether `file` is still the file the ops apply to.
    func matchesBaseline(_ file: MappedFile) -> Bool {
        var result = false
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder().decode(Manifest.self, from: data),
           let current = EditJournal.manifest(describing: file) {
            result = saved.version == EditJournal.manifestFormatVersion
                && saved.path == current.path
                && saved.size == current.size
                && saved.inode == current.inode
                && saved.modified == current.modified
        }
        return result
    }

    private static func manifest(describing file: MappedFile) -> Manifest? {
        var info = stat()
        guard stat(file.path, &info) == 0 else {
            return nil
        }
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return Manifest(version: manifestFormatVersion, path: file.path, size: Int(info.st_size),
                        inode: UInt64(info.st_ino), modified: modified)
    }

    /// Whether there are unsaved operations recorded against `file` as it is
    /// now — the question asked when a document is opened.
    func hasRecoverableEdits(for file: MappedFile) -> Bool {
        var result = false
        if matchesBaseline(file), let operations = readOperations(), !operations.isEmpty {
            result = true
        }
        return result
    }

    // MARK: - Recording

    /// Mirrors an append to the add buffer.
    func recordAppend(_ bytes: [UInt8]) {
        if bytesHandle == nil {
            bytesHandle = EditJournal.appendHandle(for: bytesURL)
        }
        bytesHandle?.write(Data(bytes))
    }

    /// Records one splice. A piece from a retired mapping cannot be replayed
    /// after a relaunch, so it marks the journal unreplayable instead.
    func recordSplice(_ range: Range<Int>, pieces: [PieceTable.Piece]) {
        guard isReplayable else {
            return
        }
        if operationsHandle == nil {
            operationsHandle = EditJournal.appendHandle(for: operationsURL)
        }
        var record = Data()
        var encodedPieces = Data()
        var replayable = true
        for piece in pieces where replayable {
            switch piece.source {
            case .original:
                encodedPieces.append(0)
            case .added:
                encodedPieces.append(1)
            default:
                replayable = false
            }
            encodedPieces.append(int64: piece.start)
            encodedPieces.append(int64: piece.length)
        }
        if replayable {
            record.append(EditJournal.spliceKind)
            record.append(int64: range.lowerBound)
            record.append(int64: range.upperBound)
            record.append(uint32: UInt32(pieces.count))
            record.append(encodedPieces)
        } else {
            record.append(EditJournal.unreplayableKind)
            isReplayable = false
        }
        operationsHandle?.write(record)
    }

    private static func appendHandle(for url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }

    // MARK: - Reading back

    /// Every inserted byte, in append order.
    func loadBytes() -> [UInt8] {
        (try? Data(contentsOf: bytesURL)).map(Array.init) ?? []
    }

    /// The recorded splices, in order — or `nil` if the journal is unreadable
    /// or was marked unreplayable. A partial record at the end (a crash while
    /// writing it) is dropped: everything before it still applies.
    func readOperations() -> [(range: Range<Int>, pieces: [PieceTable.Piece])]? {
        guard let data = try? Data(contentsOf: operationsURL) else {
            return nil
        }
        var operations: [(range: Range<Int>, pieces: [PieceTable.Piece])] = []
        var cursor = 0
        var valid = true
        while valid && cursor < data.count {
            let kind = data[cursor]
            if kind == EditJournal.unreplayableKind {
                valid = false
            } else if kind == EditJournal.spliceKind,
                      let lower = data.int64(at: cursor + 1),
                      let upper = data.int64(at: cursor + 9),
                      let count = data.uint32(at: cursor + 17) {
                var pieces: [PieceTable.Piece] = []
                var position = cursor + 21
                var complete = true
                for _ in 0..<count where complete {
                    if position < data.count,
                       let start = data.int64(at: position + 1),
                       let length = data.int64(at: position + 9) {
                        let source: PieceTable.Piece.Source = data[position] == 0 ? .original : .added
                        pieces.append(PieceTable.Piece(source: source, start: start, length: length))
                        position += 17
                    } else {
                        complete = false
                    }
                }
                if complete && lower <= upper {
                    operations.append((lower..<upper, pieces))
                    cursor = position
                } else {
                    cursor = data.count      // a torn final record: stop here
                }
            } else {
                cursor = data.count          // torn header, same treatment
            }
        }
        return valid ? operations : nil
    }

    /// Removes the journal entirely. Called when the edits it describes are
    /// no longer wanted: the document closed cleanly, or the user chose to
    /// discard them.
    func discard() {
        bytesHandle?.closeFile()
        operationsHandle?.closeFile()
        bytesHandle = nil
        operationsHandle = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Fixed-width little-endian fields

private extension Data {
    mutating func append(int64 value: Int) {
        var little = Int64(value).littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func int64(at offset: Int) -> Int? {
        var result: Int?
        if offset >= 0 && offset + 8 <= count {
            var value: Int64 = 0
            _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: offset..<(offset + 8)) }
            result = Int(Int64(littleEndian: value))
        }
        return result
    }

    func uint32(at offset: Int) -> UInt32? {
        var result: UInt32?
        if offset >= 0 && offset + 4 <= count {
            var value: UInt32 = 0
            _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: offset..<(offset + 4)) }
            result = UInt32(littleEndian: value)
        }
        return result
    }
}
