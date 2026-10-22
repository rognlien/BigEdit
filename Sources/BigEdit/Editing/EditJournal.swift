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
/// - `manifest` — which file the ops apply to: its path, size, inode,
///   modification date and a digest of its head and tail. That is the
///   *baseline*.
///
/// On relaunch, if the file on disk still matches the baseline, replaying the
/// ops over it rebuilds the document as it was. If it does not, the ops
/// describe edits to bytes that are no longer there, and are never applied
/// without the user's say. A save moves the baseline to
/// the freshly written file and empties the ops; the bytes file keeps growing,
/// as the add buffer does, until the document is closed cleanly.
///
/// Writes are plain appends: an application crash leaves the kernel's
/// buffers intact. For a kernel panic or power loss, the files are flushed to
/// the drive's permanent storage off the main thread once edits pause, and
/// at least every few seconds while they do not (`JournalFlushSchedule`), so
/// at most the last few seconds can be lost.
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

    private static let manifestFormatVersion = 2
    private static let spliceKind: UInt8 = 1
    private static let unreplayableKind: UInt8 = 0xFF

    /// Identifies the directory in the registry of journals in use.
    private let registryKey: String

    /// When the files are next flushed to permanent storage.
    private let flushSchedule: JournalFlushSchedule

    /// Where flushes run: one serial queue, so they never overlap.
    static let flushQueue = DispatchQueue(label: "BigEdit.EditJournal.flush", qos: .utility)

    private init(directory: URL, clock: FlushClock) {
        self.directory = directory
        self.bytesURL = directory.appendingPathComponent("bytes")
        self.operationsURL = directory.appendingPathComponent("ops")
        self.manifestURL = directory.appendingPathComponent(EditJournal.manifestName)
        self.registryKey = EditJournal.register(directory)
        let files = EditJournal.flushedFiles(in: directory)
        self.flushSchedule = JournalFlushSchedule(clock: clock) {
            EditJournal.flushQueue.async {
                EditJournal.synchronise(files)
            }
        }
    }

    deinit {
        if flushSchedule.hasUnflushedWrites {
            flushSchedule.flushNow()
        }
        EditJournal.unregister(registryKey)
    }

    private static let manifestName = "manifest.json"

    // MARK: - Locating

    /// The root journals live under: Application Support. A test passes a
    /// temporary one instead.
    static let root: URL = FileManager.default
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
    static func open(for path: String, in root: URL = EditJournal.root,
                     clock: FlushClock = MainQueueFlushClock.shared) -> EditJournal {
        EditJournal(directory: directory(for: path, in: root), clock: clock)
    }

    /// Whether the journal for `path` has operations recorded since its last
    /// baseline, read without opening it.
    static func hasPendingOperations(forPath path: String, in root: URL = EditJournal.root) -> Bool {
        let operations = directory(for: path, in: root).appendingPathComponent("ops")
        let attributes = try? FileManager.default.attributesOfItem(atPath: operations.path)
        return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 0
    }

    // MARK: - Journals in use

    private static let registryLock = NSLock()
    private static var instancesInUse: [String: Int] = [:]

    /// Creates `directory` and marks it in use, under the lock the cleanup
    /// takes, so a journal is never removed between being found and opened.
    private static func register(_ directory: URL) -> String {
        registryLock.lock()
        defer { registryLock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = registryKey(for: directory)
        instancesInUse[key, default: 0] += 1
        return key
    }

    private static func unregister(_ key: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        instancesInUse[key, default: 1] -= 1
        if instancesInUse[key] == 0 {
            instancesInUse[key] = nil
        }
    }

    private static func registryKey(for directory: URL) -> String {
        directory.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Cleaning up

    /// How long a journal may go untouched before it is assumed abandoned.
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    /// Removes journals no document can use any more: those whose file is
    /// gone, and those untouched for longer than `maximumAge`. A journal an
    /// open document holds is never removed. It reads only listings and
    /// manifests, but it touches the disk: call it off the main thread.
    static func removeStaleJournals(in root: URL = EditJournal.root, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-maximumAge)
        for directory in journalDirectories(in: root) where isStale(directory, cutoff: cutoff) {
            removeUnlessInUse(directory)
        }
    }

    private static func journalDirectories(in root: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func isStale(_ directory: URL, cutoff: Date) -> Bool {
        let manifest = readManifest(at: directory.appendingPathComponent(manifestName))
        let fileIsGone = manifest.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        return fileIsGone || lastModified(directory) < cutoff
    }

    /// The latest modification of the directory or anything in it: the ops
    /// and bytes files are appended to on every edit.
    private static func lastModified(_ directory: URL) -> Date {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dates = ([directory] + files).compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return dates.max() ?? .distantPast
    }

    private static func removeUnlessInUse(_ directory: URL) {
        registryLock.lock()
        defer { registryLock.unlock() }
        if instancesInUse[registryKey(for: directory)] == nil {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - The baseline

    private struct Manifest: Codable {
        var version: Int
        var path: String
        var size: Int
        var inode: UInt64
        var modified: Double
        /// A digest of the file's head and tail. Absent from manifests written
        /// before it was recorded.
        var sample: String?
    }

    /// How the file on disk compares with the baseline the ops apply to.
    enum BaselineComparison {
        /// The same file, unchanged: the ops replay onto exactly the bytes
        /// they were made against.
        case identical
        /// The same size and sampled content, but a different identity or
        /// modification date — touched, restored from a backup, or rewritten
        /// with the same length. Replaying may or may not be right.
        case uncertain
        /// A different file: the ops would splice onto the wrong bytes.
        case different
    }

    /// What an earlier run left for `file` — the question asked when a
    /// document is opened.
    enum RecoveryState {
        case nothingPending
        /// Unsaved edits against `file` exactly as it is now.
        case recoverable
        /// Unsaved edits against a file that may have changed since.
        case baselineUncertain
        /// Unsaved edits against a file that has since changed.
        case baselineChanged
    }

    /// The bytes sampled from each end of the file for its fingerprint.
    static let sampleLength = 64 * 1024

    /// Makes `file` the baseline: records what it is and empties the ops.
    /// Called on open (when nothing is pending) and after every save.
    ///
    /// The bytes file mirrors the add buffer offset for offset. When the
    /// buffer carried over a save it is passed as `addedBytes`: the bytes
    /// file is kept if it already holds them, and rewritten from the buffer
    /// if not — after a save to a new file, whose journal starts empty. A
    /// document starting with an empty buffer starts with an empty bytes file.
    func setBaseline(_ file: MappedFile, mirroring addedBytes: AddedByteStore? = nil) {
        operationsHandle?.closeFile()
        operationsHandle = nil
        try? Data().write(to: operationsURL)
        if recordedByteCount != (addedBytes?.count ?? 0) {
            rewriteBytes(from: addedBytes)
        }
        isReplayable = true
        adoptBaseline(file)
    }

    private var recordedByteCount: Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: bytesURL.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func rewriteBytes(from addedBytes: AddedByteStore?) {
        bytesHandle?.closeFile()
        bytesHandle = nil
        let count = addedBytes?.count ?? 0
        let data = addedBytes?.withUnsafeBytes(in: 0..<count) { Data($0) } ?? Data()
        try? data.write(to: bytesURL)
    }

    /// Records `file` as the baseline without touching the ops: after the
    /// user chose to recover onto a file that may have changed, the ops now
    /// stand against the file as it is.
    func adoptBaseline(_ file: MappedFile) {
        if let manifest = EditJournal.manifest(describing: file),
           let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }
        flushSchedule.noteWrite()
    }

    /// How `file` compares with the file the ops apply to. A missing or
    /// unreadable manifest gives no grounds to replay, so it is `different`.
    func compareBaseline(_ file: MappedFile) -> BaselineComparison {
        var result = BaselineComparison.different
        if let saved = readManifest(), let current = EditJournal.manifest(describing: file) {
            result = EditJournal.compare(saved, with: current)
        }
        return result
    }

    private static func compare(_ saved: Manifest, with current: Manifest) -> BaselineComparison {
        let sampleDiffers = saved.sample != nil && saved.sample != current.sample
        let sameIdentity = saved.inode == current.inode && saved.modified == current.modified
        var result = BaselineComparison.different
        if saved.path == current.path && saved.size == current.size && !sampleDiffers {
            result = sameIdentity ? .identical : .uncertain
        }
        return result
    }

    private func readManifest() -> Manifest? {
        EditJournal.readManifest(at: manifestURL)
    }

    private static func readManifest(at url: URL) -> Manifest? {
        var result: Manifest?
        if let data = try? Data(contentsOf: url) {
            result = try? JSONDecoder().decode(Manifest.self, from: data)
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
                        inode: UInt64(info.st_ino), modified: modified, sample: sample(of: file))
    }

    /// A digest of the first and last `sampleLength` bytes and the size, so a
    /// rewrite that kept the length and dates is still caught at either end.
    /// Constant work whatever the file's size.
    private static func sample(of file: MappedFile) -> String {
        let buffer = file.buffer
        let headLength = min(sampleLength, buffer.count)
        let tailStart = max(headLength, buffer.count - sampleLength)
        var hasher = SHA256()
        hasher.update(data: withUnsafeBytes(of: Int64(buffer.count).littleEndian) { Data($0) })
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<headLength]))
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[tailStart..<buffer.count]))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether there are unsaved operations recorded for this file, and
    /// whether the file is still the one they were made against.
    func recoveryState(for file: MappedFile) -> RecoveryState {
        var result = RecoveryState.nothingPending
        if let operations = readOperations(), !operations.isEmpty {
            switch compareBaseline(file) {
            case .identical:
                result = .recoverable
            case .uncertain:
                result = .baselineUncertain
            case .different:
                result = .baselineChanged
            }
        }
        return result
    }

    /// Whether there are unsaved operations recorded against `file` exactly
    /// as it is now.
    func hasRecoverableEdits(for file: MappedFile) -> Bool {
        recoveryState(for: file) == .recoverable
    }

    // MARK: - Recording

    /// Mirrors an append to the add buffer.
    func recordAppend(_ bytes: [UInt8]) {
        if bytesHandle == nil {
            bytesHandle = EditJournal.appendHandle(for: bytesURL)
        }
        bytesHandle?.write(Data(bytes))
        flushSchedule.noteWrite()
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
        flushSchedule.noteWrite()
    }

    private static func appendHandle(for url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }

    // MARK: - Flushing

    /// Whether something written has not been flushed yet.
    var hasUnflushedWrites: Bool {
        flushSchedule.hasUnflushedWrites
    }

    /// Flushes everything written so far to permanent storage before
    /// returning, after any flush already under way. For quitting and
    /// closing, when there is no later to wait for.
    func flush() {
        let files = hasUnflushedWrites ? EditJournal.flushedFiles(in: directory) : []
        flushSchedule.cancel()
        EditJournal.flushQueue.sync {
            EditJournal.synchronise(files)
        }
    }

    /// The files and, for the entries naming them, their directory.
    private static func flushedFiles(in directory: URL) -> [URL] {
        ["bytes", "ops", manifestName].map(directory.appendingPathComponent) + [directory]
    }

    /// Writes `files` through to permanent storage. Plain `fsync` on macOS
    /// stops at the drive's volatile cache, which a power loss empties;
    /// `F_FULLFSYNC` asks the drive to empty that cache too. It flushes the
    /// whole cache, so each file is synced and only the last one, the
    /// directory, takes the full flush — falling back to `fsync` where the
    /// file system does not support it. A file that is gone, the journal
    /// having been discarded, is skipped.
    private static func synchronise(_ files: [URL]) {
        for (position, url) in files.enumerated() {
            synchronise(url, throughDriveCache: position == files.count - 1)
        }
    }

    private static func synchronise(_ url: URL, throughDriveCache: Bool) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        if descriptor >= 0 {
            if !throughDriveCache || fcntl(descriptor, F_FULLFSYNC) == -1 {
                fsync(descriptor)
            }
            close(descriptor)
        }
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
        flushSchedule.cancel()
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
