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

    /// Fails if `query` is empty (nothing to search for).
    init?(query: String, caseSensitive: Bool = true) {
        let bytes = Array(query.utf8)
        guard !bytes.isEmpty else {
            return nil
        }
        self.queryBytes = bytes
        self.caseSensitive = caseSensitive
        self.foldedQueryBytes = bytes.map(SearchScan.foldByte)
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
