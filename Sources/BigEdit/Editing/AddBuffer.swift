import Foundation

/// Storage for the bytes of every insertion (typing, paste) made to a
/// document. It only ever grows, so the piece-table pieces and undo records
/// that reference ranges of it never dangle.
///
/// The piece table reads it only through this protocol, so where the bytes
/// are kept is the store's own business.
protocol AddedByteStore: AnyObject {

    /// The total number of bytes appended so far.
    var count: Int { get }

    /// Appends `bytes` and returns the range they now occupy.
    @discardableResult
    func append(_ bytes: [UInt8]) -> Range<Int>

    /// Copies the bytes in `range`.
    func bytes(in range: Range<Int>) -> [UInt8]
}

extension AddedByteStore {

    /// Calls `body` with the bytes in `range`, at most `chunkLength` at a
    /// time — for streaming writers that must not materialise large pieces.
    func forEachChunk(in range: Range<Int>, chunkLength: Int = 4 * 1024 * 1024,
                      _ body: ([UInt8]) throws -> Void) rethrows {
        var offset = range.lowerBound
        while offset < range.upperBound {
            let end = min(range.upperBound, offset + chunkLength)
            try body(bytes(in: offset..<end))
            offset = end
        }
    }
}

/// The added-byte store used while editing: in memory while it is small,
/// and past `spillThreshold` in a `SpillFile`, so a huge paste costs disk
/// rather than memory. Should the disk refuse a write, the bytes come back
/// into memory and stay there.
///
/// Reads may come from background scans (search, save) while the main thread
/// keeps appending, so access is serialised — appends can reallocate the
/// underlying storage, which would otherwise invalidate a concurrent reader.
final class AddBuffer: AddedByteStore {

    static let defaultSpillThreshold = 8 * 1024 * 1024

    /// Where spill files are opened: BigEdit's own folder in the temporary
    /// directory.
    static let defaultSpillDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BigEdit Add Buffers", isDirectory: true)

    private let lock = NSLock()
    private var storage: ContiguousArray<UInt8> = []
    private var spillFile: SpillFile?
    private var maySpill = true
    private let spillThreshold: Int
    private let spillDirectory: URL

    init(spillThreshold: Int = AddBuffer.defaultSpillThreshold,
         spillDirectory: URL = AddBuffer.defaultSpillDirectory) {
        self.spillThreshold = spillThreshold
        self.spillDirectory = spillDirectory
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    /// Whether the bytes are on disk rather than in memory.
    var isSpilled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return spillFile != nil
    }

    private var storedCount: Int {
        spillFile?.count ?? storage.count
    }

    @discardableResult
    func append(_ bytes: [UInt8]) -> Range<Int> {
        lock.lock()
        defer { lock.unlock() }
        let start = storedCount
        if spillFile == nil && maySpill && start + bytes.count > spillThreshold {
            spill()
        }
        if let spillFile, !bytes.withUnsafeBytes(spillFile.append) {
            returnToMemory()
        }
        if spillFile == nil {
            storage.append(contentsOf: bytes)
        }
        return start..<(start + bytes.count)
    }

    func bytes(in range: Range<Int>) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return spillFile?.bytes(in: range) ?? Array(storage[range])
    }

    /// Moves the bytes held in memory to a new spill file.
    private func spill() {
        if let file = SpillFile(directory: spillDirectory), storage.withUnsafeBytes(file.append) {
            spillFile = file
            storage = []
        } else {
            maySpill = false
        }
    }

    /// Reads the spill file back into memory after a failed write, and keeps
    /// every later byte there.
    private func returnToMemory() {
        if let spillFile {
            storage = ContiguousArray(spillFile.bytes(in: 0..<spillFile.count))
        }
        spillFile = nil
        maySpill = false
    }

    /// Removes spill files a crash left in `directory`. Call it off the main
    /// thread.
    static func removeLeftoverSpillFiles(in directory: URL = AddBuffer.defaultSpillDirectory) {
        SpillFile.removeLeftovers(in: directory)
    }
}
