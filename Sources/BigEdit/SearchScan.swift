import Foundation

/// A background literal (byte-for-byte) search over a `MappedFile`.
///
/// The scan uses `memmem`, which is fast enough to sweep many gigabytes in a
/// few seconds. Match byte offsets are collected into a sorted array (capped at
/// `matchLimit`), so navigation is array indexing and highlighting is a binary
/// search — both independent of file size.
///
/// A scan can be cancelled when the query changes; the owner discards a stale
/// scan's progress callbacks by identity.
final class SearchScan {

    /// Upper bound on collected matches, to keep memory and time bounded.
    static let matchLimit = 1_000_000

    /// The query encoded as UTF-8 bytes — the needle passed to `memmem`.
    let queryBytes: [UInt8]

    /// Whether matching distinguishes upper- and lower-case ASCII letters.
    let caseSensitive: Bool

    /// The query with ASCII letters folded to lowercase, used by the
    /// case-insensitive scan.
    private let foldedQueryBytes: [UInt8]

    private let lock = NSLock()
    private var offsets: [Int] = []
    private var scanComplete = false
    private var stopped = false
    private var bytesScanned = 0
    private var totalBytes = 0

    /// Window size for the piece-table scan — an init parameter so tests can
    /// shrink it and exercise the window-boundary handling.
    private let logicalScanWindow: Int

    /// Fails if `query` is empty (nothing to search for).
    init?(query: String, caseSensitive: Bool = true,
          logicalScanWindow: Int = 64 * 1024 * 1024) {
        let bytes = Array(query.utf8)
        guard !bytes.isEmpty, logicalScanWindow >= bytes.count else {
            return nil
        }
        self.queryBytes = bytes
        self.caseSensitive = caseSensitive
        self.foldedQueryBytes = bytes.map(SearchScan.foldByte)
        self.logicalScanWindow = logicalScanWindow
    }

    /// ASCII case-folds a single byte (A–Z → a–z; everything else passes
    /// through). Multi-byte UTF-8 sequences are not folded — case
    /// insensitivity is ASCII-only.
    private static func foldByte(_ byte: UInt8) -> UInt8 {
        return (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    /// The length of the query in bytes — also the length of every match.
    var queryByteLength: Int {
        queryBytes.count
    }

    var matchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return offsets.count
    }

    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return scanComplete
    }

    /// Whether the `matchLimit` cap was reached.
    var isTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offsets.count >= SearchScan.matchLimit
    }

    /// Fraction of the file scanned so far. Useful for showing a `"Searching… N%"`
    /// indicator even when the scan is finding zero matches.
    var scanProgress: Double {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes > 0 ? Double(bytesScanned) / Double(totalBytes) : 1
    }

    /// Stops the background scan; further results are not published.
    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    // MARK: - Match access

    /// The byte offset of the match at `index`, or `nil` if out of range.
    func matchOffset(at index: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        var result: Int?
        if index >= 0 && index < offsets.count {
            result = offsets[index]
        }
        return result
    }

    /// The offsets of all matches that begin within `range`, for highlighting.
    func matchOffsets(beginningIn range: Range<Int>) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Int] = []
        var index = lowerBound(for: range.lowerBound)
        while index < offsets.count && offsets[index] < range.upperBound {
            result.append(offsets[index])
            index += 1
        }
        return result
    }

    /// First index whose offset is `>= value`. The caller must hold `lock`.
    private func lowerBound(for value: Int) -> Int {
        var low = 0
        var high = offsets.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - Scanning

    /// Scans `file` on a background queue, invoking `onProgress` on the main
    /// queue as matches accumulate.
    func start(in file: MappedFile, onProgress: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scan(file: file) {
                DispatchQueue.main.async(execute: onProgress)
            }
        }
    }

    /// Scans the logical (edited) document on a background queue. Without
    /// edits this is the zero-copy mmap scan; with edits, logical windows
    /// are assembled through a snapshot of the piece table, so the scan is
    /// stable even while further edits arrive (the owner cancels and re-runs
    /// on every edit). Match offsets are logical.
    func start(in document: EditedDocument, onProgress: @escaping () -> Void) {
        if document.hasEdits {
            let pieces = document.pieceTable.pieces(in: 0..<document.length)
            let length = document.length
            let file = document.file
            let added = document.addBuffer
            let retired = document.retiredFiles
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.scanLogical(pieces: pieces, length: length, file: file, added: added,
                                  retired: retired) {
                    DispatchQueue.main.async(execute: onProgress)
                }
            }
        } else {
            start(in: document.file, onProgress: onProgress)
        }
    }

    /// Logical scan on the current thread — used by tests.
    func runSynchronously(in document: EditedDocument) {
        if document.hasEdits {
            let pieces = document.pieceTable.pieces(in: 0..<document.length)
            scanLogical(pieces: pieces, length: document.length,
                        file: document.file, added: document.addBuffer,
                        retired: document.retiredFiles, onProgress: {})
        } else {
            runSynchronously(in: document.file)
        }
    }

    /// Scans `file` on the current thread and returns once the scan is done.
    /// Used by the headless `--search` mode.
    func runSynchronously(in file: MappedFile) {
        scan(file: file, onProgress: {})
    }

    private func scan(file: MappedFile, onProgress: () -> Void) {
        let buffer = file.buffer
        let total = buffer.count
        let needleLength = queryBytes.count

        // Record the file size up front so `scanProgress` is meaningful even
        // before the first batch is published.
        lock.lock()
        totalBytes = total
        bytesScanned = 0
        lock.unlock()

        guard let base = buffer.baseAddress, total >= needleLength else {
            lock.lock(); bytesScanned = total; lock.unlock()
            markComplete()
            onProgress()
            return
        }

        // Scan in fixed-size windows so progress is reported by *bytes
        // scanned*, not only by matches found. Without this a scan that
        // finds zero matches over many GB would show no progress at all.
        // Windows overlap by `needleLength - 1` so a match straddling a
        // boundary is still found by the next window.
        let scanWindow = 64 * 1024 * 1024
        let matchPublishThreshold = 16384

        var pending: [Int] = []
        var totalFound = 0
        var searchOffset = 0
        var bytesAtLastPublish = 0
        var matchesAtLastPublish = 0

        if caseSensitive {
            queryBytes.withUnsafeBytes { rawNeedle in
                let needlePointer = rawNeedle.baseAddress!
                while searchOffset + needleLength <= total && !isStopped() {
                    let windowEnd = min(total, searchOffset + scanWindow + needleLength - 1)
                    let windowLen = windowEnd - searchOffset

                    if let hit = memmem(base + searchOffset, windowLen, needlePointer, needleLength) {
                        let matchOffset = base.distance(to: UnsafeRawPointer(hit))
                        pending.append(matchOffset)
                        totalFound += 1
                        searchOffset = matchOffset + needleLength  // Non-overlapping matches.
                        if totalFound >= SearchScan.matchLimit {
                            break
                        }
                    } else {
                        if windowEnd >= total {
                            searchOffset = total
                            break
                        }
                        searchOffset = windowEnd - needleLength + 1
                    }

                    let bytesSince = searchOffset - bytesAtLastPublish
                    let matchesSince = totalFound - matchesAtLastPublish
                    if bytesSince >= scanWindow || matchesSince >= matchPublishThreshold {
                        publish(pending: &pending, bytesScanned: searchOffset)
                        bytesAtLastPublish = searchOffset
                        matchesAtLastPublish = totalFound
                        onProgress()
                    }
                }
            }
        } else {
            // Case-insensitive scan: byte-by-byte with ASCII case folding.
            // No `memmem` fast path; the cancel/progress check is amortised
            // over ~1M iterations to keep the inner loop tight.
            let bytePointer = base.assumingMemoryBound(to: UInt8.self)
            let iterationsPerCheck = 1 << 20
            var iterationsSinceCheck = 0

            while searchOffset + needleLength <= total {
                var matched = true
                for index in 0..<needleLength {
                    if SearchScan.foldByte(bytePointer[searchOffset + index]) != foldedQueryBytes[index] {
                        matched = false
                        break
                    }
                }
                if matched {
                    pending.append(searchOffset)
                    totalFound += 1
                    searchOffset += needleLength
                    if totalFound >= SearchScan.matchLimit {
                        break
                    }
                } else {
                    searchOffset += 1
                }

                iterationsSinceCheck += 1
                if iterationsSinceCheck >= iterationsPerCheck {
                    iterationsSinceCheck = 0
                    if isStopped() {
                        break
                    }
                    let bytesSince = searchOffset - bytesAtLastPublish
                    let matchesSince = totalFound - matchesAtLastPublish
                    if bytesSince >= scanWindow || matchesSince >= matchPublishThreshold {
                        publish(pending: &pending, bytesScanned: searchOffset)
                        bytesAtLastPublish = searchOffset
                        matchesAtLastPublish = totalFound
                        onProgress()
                    }
                }
            }
        }

        publish(pending: &pending, bytesScanned: searchOffset)
        markComplete()
        onProgress()
    }

    /// The piece-table scan: assemble fixed-size logical windows into a
    /// reusable buffer and search within each. Windows overlap by
    /// `needle - 1` bytes so straddling matches are found; the chain of
    /// non-overlapping matches continues across windows.
    private func scanLogical(
        pieces: [PieceTable.Piece],
        length: Int,
        file: MappedFile,
        added: AddedByteStore,
        retired: [MappedFile],
        onProgress: () -> Void
    ) {
        let needleLength = queryBytes.count

        lock.lock()
        totalBytes = length
        bytesScanned = 0
        lock.unlock()

        guard length >= needleLength else {
            lock.lock(); bytesScanned = length; lock.unlock()
            markComplete()
            onProgress()
            return
        }

        // Logical start offset of each piece, for window assembly.
        var pieceStarts: [Int] = []
        pieceStarts.reserveCapacity(pieces.count)
        var runningStart = 0
        for piece in pieces {
            pieceStarts.append(runningStart)
            runningStart += piece.length
        }

        var window: [UInt8] = []
        var pending: [Int] = []
        var totalFound = 0
        var searchOffset = 0

        while searchOffset + needleLength <= length && !isStopped()
            && totalFound < SearchScan.matchLimit {
            let windowEnd = min(length, searchOffset + logicalScanWindow)
            assembleWindow(searchOffset..<windowEnd, pieces: pieces, starts: pieceStarts,
                           file: file, added: added, retired: retired, into: &window)

            var cursor = 0
            while cursor + needleLength <= window.count && totalFound < SearchScan.matchLimit {
                if let hit = matchIndex(in: window, from: cursor) {
                    pending.append(searchOffset + hit)
                    totalFound += 1
                    cursor = hit + needleLength
                } else {
                    cursor = window.count
                }
            }

            // Continue after the last full position this window covered (or
            // after the last match, whichever is later).
            let coveredTo = windowEnd - needleLength + 1
            let lastMatchEnd = pending.last.map { $0 + needleLength } ?? 0
            searchOffset = max(coveredTo, lastMatchEnd)

            publish(pending: &pending, bytesScanned: min(windowEnd, length))
            onProgress()

            if windowEnd >= length {
                break
            }
        }

        publish(pending: &pending, bytesScanned: length)
        markComplete()
        onProgress()
    }

    /// Finds the next match at or after `from` within `buffer`, honouring the
    /// scan's case sensitivity.
    private func matchIndex(in buffer: [UInt8], from: Int) -> Int? {
        var result: Int?
        let needleLength = queryBytes.count
        if caseSensitive {
            buffer.withUnsafeBytes { raw in
                if let base = raw.baseAddress,
                   let hit = memmem(base + from, buffer.count - from,
                                    queryBytes, needleLength) {
                    result = base.distance(to: UnsafeRawPointer(hit))
                }
            }
        } else {
            var candidate = from
            while candidate + needleLength <= buffer.count && result == nil {
                var matched = true
                for index in 0..<needleLength
                    where SearchScan.foldByte(buffer[candidate + index]) != foldedQueryBytes[index] {
                    matched = false
                    break
                }
                if matched {
                    result = candidate
                } else {
                    candidate += 1
                }
            }
        }
        return result
    }

    /// Copies the logical bytes in `range` out of the piece snapshot.
    private func assembleWindow(
        _ range: Range<Int>,
        pieces: [PieceTable.Piece],
        starts: [Int],
        file: MappedFile,
        added: AddedByteStore,
        retired: [MappedFile],
        into buffer: inout [UInt8]
    ) {
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(range.count)

        // The last piece starting at or before the range.
        var pieceIndex = 0
        var low = 0
        var high = starts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= range.lowerBound {
                pieceIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        var cursor = range.lowerBound
        while cursor < range.upperBound && pieceIndex < pieces.count {
            let piece = pieces[pieceIndex]
            let within = cursor - starts[pieceIndex]
            let take = min(piece.length - within, range.upperBound - cursor)
            let sourceRange = (piece.start + within)..<(piece.start + within + take)
            switch piece.source {
            case .original:
                buffer.append(contentsOf: file.buffer[sourceRange])
            case .added:
                buffer.append(contentsOf: added.bytes(in: sourceRange))
            case .retired(let generation):
                buffer.append(contentsOf: retired[generation].buffer[sourceRange])
            }
            cursor += take
            pieceIndex += 1
        }
    }

    private func publish(pending: inout [Int], bytesScanned: Int) {
        lock.lock()
        if !pending.isEmpty {
            offsets.append(contentsOf: pending)
        }
        self.bytesScanned = bytesScanned
        lock.unlock()
        pending.removeAll(keepingCapacity: true)
    }

    private func markComplete() {
        lock.lock()
        scanComplete = true
        lock.unlock()
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
