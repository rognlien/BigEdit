import Foundation

/// A background search over a `MappedFile`: literal bytes, or a regular
/// expression.
///
/// The literal scan uses `memmem`, which is fast enough to sweep many gigabytes
/// in a few seconds. The regular-expression scan hands `NSRegularExpression`
/// one window of lines at a time. Either way, match byte offsets are collected
/// into a sorted array (capped at `matchLimit`), so navigation is array
/// indexing and highlighting is a binary search — both independent of file
/// size.
///
/// A scan can be cancelled when the query changes; the owner discards a stale
/// scan's progress callbacks by identity.
final class SearchScan {

    /// Upper bound on collected matches, to keep memory and time bounded.
    static let matchLimit = 1_000_000

    /// How the query is interpreted.
    enum Mode {
        case literal
        case regularExpression
    }

    let mode: Mode

    /// The query encoded as UTF-8 bytes — the needle passed to `memmem`, or
    /// the pattern's text in regular-expression mode.
    let queryBytes: [UInt8]

    /// Whether matching distinguishes upper- and lower-case letters. Literal
    /// matching folds ASCII only; the regular-expression engine folds Unicode.
    let caseSensitive: Bool

    /// The compiled pattern, in regular-expression mode.
    private let expression: NSRegularExpression?

    /// The document's encoding: a literal query is encoded into it to make
    /// the needle, and a regular expression's windows are decoded from it.
    let encoding: TextEncoding

    /// Byte length of each match, parallel to `offsets`. Only kept in
    /// regular-expression mode — literal matches are all `queryByteLength`.
    private var lengths: [Int] = []
    private var longestLength = 0

    /// Regular-expression windows are cut at a line boundary below this size.
    /// A match cannot span two windows, so a pattern can only match across
    /// this many bytes of lines — not a limit anyone meets in practice.
    static let regularExpressionWindow = 4 * 1024 * 1024

    /// Windows are searched concurrently, this many at a time. Each holds its
    /// bytes and their decoded string while in flight, so this also bounds the
    /// scan's memory to a few tens of megabytes.
    static let regularExpressionWorkers = 8

    /// A window with no newline in it at all is one very long line; it grows
    /// until it finds one, so a match inside a long line is never cut in two,
    /// but only up to this size. A single line longer than this is searched in
    /// pieces, and a match straddling a piece boundary is missed.
    static let longestUnbrokenLine = 256 * 1024 * 1024

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

    /// Fails if `query` is empty, or cannot be written in the document's
    /// encoding at all — there is then nothing to look for.
    init?(query: String, caseSensitive: Bool = true,
          logicalScanWindow: Int = 64 * 1024 * 1024, encoding: TextEncoding = .utf8) {
        guard let bytes = encoding.encode(query), !bytes.isEmpty,
              logicalScanWindow >= bytes.count else {
            return nil
        }
        self.queryBytes = bytes
        self.caseSensitive = caseSensitive
        self.foldedQueryBytes = bytes.map(SearchScan.foldByte)
        self.logicalScanWindow = logicalScanWindow
        self.mode = .literal
        self.expression = nil
        self.encoding = encoding
    }

    /// Fails if `pattern` is empty or is not a valid regular expression.
    /// `^` and `$` match at line boundaries, as they do in `grep`.
    init?(regularExpression pattern: String, caseSensitive: Bool = true,
          logicalScanWindow: Int = 64 * 1024 * 1024, encoding: TextEncoding = .utf8) {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive {
            options.insert(.caseInsensitive)
        }
        guard !pattern.isEmpty, logicalScanWindow > 0,
              let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        self.queryBytes = Array(pattern.utf8)
        self.caseSensitive = caseSensitive
        self.foldedQueryBytes = []
        self.logicalScanWindow = logicalScanWindow
        self.mode = .regularExpression
        self.expression = compiled
        self.encoding = encoding
    }

    var isRegularExpression: Bool {
        mode == .regularExpression
    }

    /// ASCII case-folds a single byte (A–Z → a–z; everything else passes
    /// through). Multi-byte UTF-8 sequences are not folded — case
    /// insensitivity is ASCII-only.
    private static func foldByte(_ byte: UInt8) -> UInt8 {
        return (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    /// The length of the query in bytes — and, for a literal query, the
    /// length of every match. Regular-expression matches vary: ask
    /// `matchLength(at:)` or `matches(beginningIn:)`.
    var queryByteLength: Int {
        queryBytes.count
    }

    /// The byte length of the match at `index`.
    func matchLength(at index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var result = queryBytes.count
        if mode == .regularExpression && index >= 0 && index < lengths.count {
            result = lengths[index]
        }
        return result
    }

    /// The longest match found so far: how far before a row a match may begin
    /// and still reach into it.
    var longestMatchLength: Int {
        lock.lock()
        defer { lock.unlock() }
        return mode == .regularExpression ? longestLength : queryBytes.count
    }

    /// The byte ranges of all matches that begin within `range`.
    func matches(beginningIn range: Range<Int>) -> [Range<Int>] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Range<Int>] = []
        var index = lowerBound(for: range.lowerBound)
        while index < offsets.count && offsets[index] < range.upperBound {
            let length = mode == .regularExpression ? lengths[index] : queryBytes.count
            result.append(offsets[index]..<(offsets[index] + length))
            index += 1
        }
        return result
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
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.scanLogical(pieces: pieces, length: length, file: file, added: added) {
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
                        file: document.file, added: document.addBuffer, onProgress: {})
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

        if mode == .regularExpression {
            scanRegularExpression(length: total, onProgress: onProgress) { range in
                Array(buffer[range])
            }
            return
        }

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
        onProgress: () -> Void
    ) {
        let needleLength = queryBytes.count

        lock.lock()
        totalBytes = length
        bytesScanned = 0
        lock.unlock()

        guard length >= (mode == .regularExpression ? 1 : needleLength) else {
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

        if mode == .regularExpression {
            scanRegularExpression(length: length, onProgress: onProgress) { range in
                self.assembleWindow(range, pieces: pieces, starts: pieceStarts,
                                    file: file, added: added, into: &window)
                return window
            }
            return
        }

        var pending: [Int] = []
        var totalFound = 0
        var searchOffset = 0

        while searchOffset + needleLength <= length && !isStopped()
            && totalFound < SearchScan.matchLimit {
            let windowEnd = min(length, searchOffset + logicalScanWindow)
            assembleWindow(searchOffset..<windowEnd, pieces: pieces, starts: pieceStarts,
                           file: file, added: added, into: &window)

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
            }
            cursor += take
            pieceIndex += 1
        }
    }

    // MARK: - Regular expressions

    /// Runs the pattern over the document in windows, several at a time.
    /// `read` hands back the bytes in a logical range — straight from the
    /// mmap for a clean file, or assembled through the piece table for an
    /// edited one — and is only ever called from this thread.
    ///
    /// Each window is cut at a line boundary, so a match never straddles two
    /// windows, and that is also what makes the windows independent: a group
    /// of them is searched concurrently and the results appended in file
    /// order, so the match list stays sorted and the display cap is applied
    /// exactly as it would be serially. A window is decoded whole when it is
    /// valid UTF-8, which is nearly always; one with a broken byte in it falls
    /// back to line by line, skipping only the lines that do not decode. Empty
    /// matches are skipped, as `grep -o` skips them.
    private func scanRegularExpression(length: Int, onProgress: () -> Void,
                                       read: (Range<Int>) -> [UInt8]) {
        lock.lock()
        totalBytes = length
        bytesScanned = 0
        lock.unlock()

        let windowSize = max(1, min(logicalScanWindow, SearchScan.regularExpressionWindow))
        let workers = max(1, min(SearchScan.regularExpressionWorkers,
                                 ProcessInfo.processInfo.activeProcessorCount))
        var pending: [Int] = []
        var pendingLengths: [Int] = []
        var totalFound = 0
        var cursor = 0

        while cursor < length && !isStopped() && totalFound < SearchScan.matchLimit {
            // Carve one window per worker, each ending on a line boundary.
            var windows: [(start: Int, bytes: [UInt8])] = []
            while windows.count < workers && cursor < length {
                let window = nextWindow(from: cursor, length: length,
                                        windowSize: windowSize, read: read)
                windows.append((cursor, window.bytes))
                cursor = window.end
            }

            var results = [(offsets: [Int], lengths: [Int])](repeating: ([], []),
                                                             count: windows.count)
            results.withUnsafeMutableBufferPointer { slots in
                DispatchQueue.concurrentPerform(iterations: windows.count) { position in
                    var offsets: [Int] = []
                    var lengths: [Int] = []
                    var found = 0
                    self.collectMatches(in: windows[position].bytes,
                                        baseOffset: windows[position].start,
                                        into: &offsets, lengths: &lengths, totalFound: &found)
                    slots[position] = (offsets, lengths)
                }
            }

            for result in results {
                for (offset, matchLength) in zip(result.offsets, result.lengths)
                where totalFound < SearchScan.matchLimit {
                    pending.append(offset)
                    pendingLengths.append(matchLength)
                    totalFound += 1
                }
            }
            publish(pending: &pending, lengths: &pendingLengths, bytesScanned: cursor)
            onProgress()
        }

        publish(pending: &pending, lengths: &pendingLengths, bytesScanned: length)
        markComplete()
        onProgress()
    }

    /// The next window starting at `cursor`: grown until it holds a whole line
    /// if it began with none, then cut after its last newline so the boundary
    /// falls between lines.
    private func nextWindow(from cursor: Int, length: Int, windowSize: Int,
                            read: (Range<Int>) -> [UInt8]) -> (bytes: [UInt8], end: Int) {
        var windowEnd = min(length, cursor + windowSize)
        var bytes = read(cursor..<windowEnd)
        while windowEnd < length && !bytes.contains(0x0A)
            && bytes.count < SearchScan.longestUnbrokenLine {
            let grownEnd = min(length, windowEnd + max(windowSize, bytes.count))
            bytes.append(contentsOf: read(windowEnd..<grownEnd))
            windowEnd = grownEnd
        }
        if windowEnd < length, let lastNewline = bytes.lastIndex(of: 0x0A) {
            bytes.removeSubrange((lastNewline + 1)...)
            windowEnd = cursor + lastNewline + 1
        }
        return (bytes, windowEnd)
    }

    private func collectMatches(in bytes: [UInt8], baseOffset: Int, into pending: inout [Int],
                                lengths pendingLengths: inout [Int], totalFound: inout Int) {
        if let text = encoding.decodeStrictly(bytes) {
            collectMatches(in: text, baseOffset: baseOffset, into: &pending,
                           lengths: &pendingLengths, totalFound: &totalFound)
        } else {
            var lineStart = 0
            for (position, byte) in bytes.enumerated() where byte == 0x0A {
                if let line = encoding.decodeStrictly(Array(bytes[lineStart..<position])) {
                    collectMatches(in: line, baseOffset: baseOffset + lineStart, into: &pending,
                                   lengths: &pendingLengths, totalFound: &totalFound)
                }
                lineStart = position + 1
            }
            if lineStart < bytes.count,
               let line = encoding.decodeStrictly(Array(bytes[lineStart...])) {
                collectMatches(in: line, baseOffset: baseOffset + lineStart, into: &pending,
                               lengths: &pendingLengths, totalFound: &totalFound)
            }
        }
    }

    /// Enumerates matches in `text` — whose UTF-8 is exactly the bytes at
    /// `baseOffset` — converting each UTF-16 range to a byte range by walking
    /// the scalars forward once. Matches arrive in order, so the walk never
    /// backs up and the whole window costs one pass.
    private func collectMatches(in text: String, baseOffset: Int, into pending: inout [Int],
                                lengths pendingLengths: inout [Int], totalFound: inout Int) {
        guard let expression else { return }
        var scalars = text.unicodeScalars.makeIterator()
        var utf16Cursor = 0
        var byteCursor = 0
        func advance(to target: Int) {
            while utf16Cursor < target, let scalar = scalars.next() {
                utf16Cursor += scalar.utf16.count
                byteCursor += encoding.byteLength(of: scalar)
            }
        }

        let whole = NSRange(location: 0, length: text.utf16.count)
        expression.enumerateMatches(in: text, options: [], range: whole) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            advance(to: match.range.location)
            let start = byteCursor
            advance(to: match.range.location + match.range.length)
            pending.append(baseOffset + start)
            pendingLengths.append(byteCursor - start)
            totalFound += 1
            if totalFound >= SearchScan.matchLimit {
                stop.pointee = true
            }
        }
    }

    private func publish(pending: inout [Int], lengths pendingLengths: inout [Int],
                         bytesScanned: Int) {
        lock.lock()
        if !pending.isEmpty {
            offsets.append(contentsOf: pending)
            lengths.append(contentsOf: pendingLengths)
            longestLength = max(longestLength, pendingLengths.max() ?? 0)
        }
        self.bytesScanned = bytesScanned
        lock.unlock()
        pending.removeAll(keepingCapacity: true)
        pendingLengths.removeAll(keepingCapacity: true)
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
