import Foundation

/// Storage for the bytes of every insertion (typing, paste) made to a
/// document. It only ever grows, so the piece-table pieces and undo records
/// that reference ranges of it never dangle.
///
/// The protocol is the seam for a future on-disk edit journal: a file-backed
/// store could replace the in-memory one — persisting unsaved edits and
/// keeping huge pastes out of memory — without touching the piece table.
protocol AddedByteStore: AnyObject {

    /// The total number of bytes appended so far.
    var count: Int { get }

    /// Appends `bytes` and returns the range they now occupy.
    @discardableResult
    func append(_ bytes: [UInt8]) -> Range<Int>

    /// Copies the bytes in `range`.
    func bytes(in range: Range<Int>) -> [UInt8]

    /// Calls `body` with a zero-copy view of the bytes in `range` — for
    /// streaming writers that must not materialise large pieces.
    func withUnsafeBytes<Result>(
        in range: Range<Int>,
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result
}

/// The in-memory added-byte store used while editing.
///
/// Reads may come from background scans (search, save) while the main thread
/// keeps appending, so access is serialised — appends can reallocate the
/// underlying storage, which would otherwise invalidate a concurrent reader.
final class AddBuffer: AddedByteStore {

    private let lock = NSLock()
    private var storage: ContiguousArray<UInt8> = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    @discardableResult
    func append(_ bytes: [UInt8]) -> Range<Int> {
        lock.lock()
        defer { lock.unlock() }
        let start = storage.count
        storage.append(contentsOf: bytes)
        return start..<storage.count
    }

    func bytes(in range: Range<Int>) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage[range])
    }

    func withUnsafeBytes<Result>(
        in range: Range<Int>,
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try storage.withUnsafeBytes { buffer in
            try body(UnsafeRawBufferPointer(rebasing: buffer[range]))
        }
    }
}
