import Foundation

/// A sparse index of line boundaries within a `MappedFile`, with soft-wrap
/// support for long lines.
///
/// **Short lines** (under `longLineThreshold` bytes) are never wrapped — they
/// each occupy one visual row, period. **Long lines** wrap to the viewport's
/// current width, set via `setWrapBytes(_:)`. The list of long lines is
/// collected once during indexing; recomputing visual-row counts on a window
/// resize then iterates only that small list, not the whole file. Normal
/// files (no long lines at all) cost nothing on resize.
///
/// Scanning runs on a background queue and publishes progress incrementally so
/// the window can open instantly while the counts grow.
final class LineIndex {

    /// One checkpoint is recorded for every this many lines.
    static let checkpointStride = 4096

    /// Lines below this byte length are never wrapped. Above it, they soft-wrap
    /// to the current `wrapBytes` setting.
    static let longLineThreshold = 1024

    /// The default `wrapBytes` before the viewport tells us its width.
    static let defaultWrapBytes = 1024

    /// Lower bound on `wrapBytes`. Window widths narrower than this still get
    /// at least this many bytes per visual row.
    static let minimumWrapBytes = 40

    /// A periodic record of where a line begins, both as a byte offset into the
    /// file and as a visual-row offset into the scrollable content. The
    /// `visualRowOffset` field is rebuilt when `wrapBytes` changes.
    struct Checkpoint {
        let byteOffset: Int
        var visualRowOffset: Int
    }

    /// One drawable row: a (possibly partial) slice of a single document line.
    struct VisualLine {
        let documentLine: Int       // 0-based line number within the file
        let chunkIndex: Int         // 0-based chunk within that line
        let chunkCount: Int         // total chunks the line is split into
        let byteRange: Range<Int>   // bytes to render for this row
    }

    /// Bookkeeping for a line whose byte length is at or above
    /// `longLineThreshold`. Persisted across `wrapBytes` changes.
    private struct LongLine {
        let lineNumber: Int
        let byteOffset: Int
        let byteLength: Int
    }

    /// Wrap-dependent layout for a long line; rebuilt when `wrapBytes` changes.
    private struct LongLineLayout {
        let lineNumber: Int
        let byteOffset: Int
        let byteLength: Int
        let chunks: Int
        let firstVisualRow: Int   // = lineNumber + cumulative extras before
    }

    private let lock = NSLock()

    // Persistent (set during scan)
    private var checkpoints: [Checkpoint] = [Checkpoint(byteOffset: 0, visualRowOffset: 0)]
    private var lineCount = 0
    private var indexingComplete = false
    private var stopped = false
    private var longLines: [LongLine] = []

    // Wrap-dependent (rebuilt by `rebuildLayoutsLocked`)
    private var currentWrapBytes = LineIndex.defaultWrapBytes
    private var totalVisualRowsCache = 0
    private var longLineLayouts: [LongLineLayout] = []
    private var layoutsValid = false

    // MARK: - Cancellation

    /// Stops the background scan; further results are not published. Used when
    /// the open document changes mid-index so we don't keep churning on the
    /// previous file.
    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: - State

    /// The number of document lines discovered so far.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return lineCount
    }

    /// The number of visual rows the document occupies at the current
    /// `wrapBytes`. Recomputed lazily after a wrap change or a publish.
    var visualRowCount: Int {
        lock.lock()
        defer { lock.unlock() }
        ensureLayoutsValidLocked()
        return totalVisualRowsCache
    }

    /// Whether the whole file has been scanned.
    var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexingComplete
    }

    /// Sets the byte width used to wrap long lines. The viewport should call
    /// this whenever its text-area width changes.
    func setWrapBytes(_ wrap: Int) {
        let clamped = max(LineIndex.minimumWrapBytes, wrap)
        lock.lock()
        if currentWrapBytes != clamped {
            currentWrapBytes = clamped
            layoutsValid = false
        }
        lock.unlock()
    }

    /// The visual-row count of a line of `byteLength` bytes at `wrap`.
    static func chunkCount(forByteLength byteLength: Int, wrap: Int) -> Int {
        if byteLength < longLineThreshold {
            return 1
        }
        return max(1, (byteLength + wrap - 1) / wrap)
    }

    // MARK: - Layout

    /// Walks `longLines` to compute extras per line and refresh checkpoints'
    /// `visualRowOffset`. Cheap when there are no long lines (the common case).
    /// Caller must hold the lock.
    private func rebuildLayoutsLocked() {
        let wrap = currentWrapBytes
        var newLayouts: [LongLineLayout] = []
        newLayouts.reserveCapacity(longLines.count)
        var cumulativeExtra = 0
        for entry in longLines {
            let chunks = LineIndex.chunkCount(forByteLength: entry.byteLength, wrap: wrap)
            newLayouts.append(LongLineLayout(
                lineNumber: entry.lineNumber,
                byteOffset: entry.byteOffset,
                byteLength: entry.byteLength,
                chunks: chunks,
                firstVisualRow: entry.lineNumber + cumulativeExtra
            ))
            cumulativeExtra += chunks - 1
        }
        longLineLayouts = newLayouts
        totalVisualRowsCache = lineCount + cumulativeExtra

        // Refresh each checkpoint's visual-row offset by walking long lines in
        // order alongside the checkpoints.
        let stride = LineIndex.checkpointStride
        var longLineIdx = 0
        var rowExtra = 0
        for checkpointIndex in 0..<checkpoints.count {
            let checkpointLineNumber = checkpointIndex * stride
            while longLineIdx < newLayouts.count
                && newLayouts[longLineIdx].lineNumber < checkpointLineNumber {
                rowExtra += newLayouts[longLineIdx].chunks - 1
                longLineIdx += 1
            }
            checkpoints[checkpointIndex].visualRowOffset = checkpointLineNumber + rowExtra
        }
        layoutsValid = true
    }

    private func ensureLayoutsValidLocked() {
        if !layoutsValid {
            rebuildLayoutsLocked()
        }
    }

    /// A consistent point-in-time copy of the index state, with layouts rebuilt
    /// if needed.
    private func snapshot() -> (
        checkpoints: [Checkpoint],
        lineCount: Int,
        rowCount: Int,
        wrap: Int,
        longLineLayouts: [LongLineLayout]
    ) {
        lock.lock()
        defer { lock.unlock() }
        ensureLayoutsValidLocked()
        return (checkpoints, lineCount, totalVisualRowsCache, currentWrapBytes, longLineLayouts)
    }

    // MARK: - Building

    /// Scans `file` on a background queue. `onProgress` is invoked on the main
    /// queue each time more of the file has been indexed.
    func build(from file: MappedFile, onProgress: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scanChoosingStrategy(file: file) {
                DispatchQueue.main.async(execute: onProgress)
            }
        }
    }

    /// Scans `file` on the current thread and returns once indexing is done.
    /// Used by the headless `--index` mode.
    func buildSynchronously(from file: MappedFile) {
        scanChoosingStrategy(file: file, onProgress: {})
    }

    /// Scans on the current thread using the parallel strategy with the given
    /// chunk size regardless of file size. Tests use tiny chunks so that chunk
    /// boundaries fall inside lines, between them, and on newlines.
    func buildSynchronously(from file: MappedFile, forcingParallelChunkSize chunkSize: Int) {
        scanParallel(file: file, chunkSize: chunkSize, onProgress: {})
    }

    /// Files at least this large are scanned in parallel. Below it the serial
    /// scan wins: it finishes in milliseconds anyway, and it stays the simpler
    /// reference the parallel scan is tested against.
    static let parallelScanThreshold = 64 * 1024 * 1024

    /// How much of the file one core takes at a time.
    static let parallelChunkSize = 32 * 1024 * 1024

    private func scanChoosingStrategy(file: MappedFile, onProgress: () -> Void) {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if file.buffer.count >= LineIndex.parallelScanThreshold && cores > 1 {
            scanParallel(file: file, chunkSize: LineIndex.parallelChunkSize, onProgress: onProgress)
        } else {
            scan(file: file, onProgress: onProgress)
        }
    }

    /// Walks the mapped bytes looking for newlines, recording a checkpoint
    /// every `checkpointStride` lines, and a `LongLine` entry whenever a line
    /// is at least `longLineThreshold` bytes long.
    private func scan(file: MappedFile, onProgress: () -> Void) {
        let buffer = file.buffer
        let total = buffer.count

        guard total > 0, let base = buffer.baseAddress else {
            finish(pendingCheckpoints: [], pendingLongLines: [], lineCount: 0)
            onProgress()
            return
        }

        let stride = LineIndex.checkpointStride
        let publishEvery = 1 << 18
        let checkEvery = 1 << 14

        var pendingCheckpoints: [Checkpoint] = []
        var pendingLongLines: [LongLine] = []
        var lines = 0
        var offset = 0
        var sinceLastPublish = 0
        var sinceLastCancelCheck = 0

        while offset < total {
            let lineStart = offset
            guard let newline = memchr(base + offset, 0x0A, total - offset) else {
                break
            }
            let newlineOffset = base.distance(to: UnsafeRawPointer(newline))
            let byteLength = newlineOffset - lineStart
            if byteLength >= LineIndex.longLineThreshold {
                pendingLongLines.append(LongLine(
                    lineNumber: lines,
                    byteOffset: lineStart,
                    byteLength: byteLength
                ))
            }
            lines += 1
            let nextLineStart = newlineOffset + 1

            if lines % stride == 0 {
                // visualRowOffset is a placeholder; rebuildLayoutsLocked fills it.
                pendingCheckpoints.append(Checkpoint(
                    byteOffset: nextLineStart,
                    visualRowOffset: 0
                ))
            }

            offset = nextLineStart
            sinceLastPublish += 1
            sinceLastCancelCheck += 1

            if sinceLastCancelCheck >= checkEvery {
                sinceLastCancelCheck = 0
                if isStopped() {
                    break
                }
            }
            if sinceLastPublish >= publishEvery {
                publish(pendingCheckpoints: &pendingCheckpoints,
                        pendingLongLines: &pendingLongLines,
                        lineCount: lines)
                sinceLastPublish = 0
                onProgress()
            }
        }

        // Trailing bytes after the final newline form one last line.
        if offset < total {
            let byteLength = total - offset
            if byteLength >= LineIndex.longLineThreshold {
                pendingLongLines.append(LongLine(
                    lineNumber: lines,
                    byteOffset: offset,
                    byteLength: byteLength
                ))
            }
            lines += 1
        }

        finish(pendingCheckpoints: pendingCheckpoints,
               pendingLongLines: pendingLongLines,
               lineCount: lines)
        onProgress()
    }

    // MARK: - Parallel scan

    /// One sampled newline offset per this many newlines. Enough to reach any
    /// exact newline with a walk of at most this many lines, at a memory cost
    /// of eight bytes per sixty-four lines.
    private static let sampleStride = 64

    /// What one chunk learns about its own bytes, independently of every other
    /// chunk. Everything that needs to know how many lines came *before* the
    /// chunk — line numbers, checkpoint alignment, a line straddling the chunk's
    /// start — is deferred to the stitching step.
    private struct ChunkScan {
        let start: Int
        let end: Int
        var newlineCount = 0
        /// Absolute offset of every `sampleStride`-th newline, the first included.
        var sampledNewlines: [Int] = []
        var firstNewline: Int?
        var lastNewline: Int?
        /// Long lines that both begin and end inside the chunk, keyed by the
        /// chunk-local index of the newline that ends them. The line ending at
        /// the chunk's *first* newline is not here: it may have begun in an
        /// earlier chunk, so only the stitcher can measure it.
        var internalLongLines: [(endsAtLocalNewline: Int, byteOffset: Int, byteLength: Int)] = []
    }

    /// Finds every newline in `start..<end`, with no reference to anything
    /// outside the chunk, so any number of these can run at once.
    private static func scanChunk(base: UnsafeRawPointer, start: Int, end: Int,
                                  isStopped: () -> Bool) -> ChunkScan {
        var result = ChunkScan(start: start, end: end)
        var cursor = start
        var previousNewline: Int?
        var untilCancelCheck = 1 << 14

        while cursor < end, let found = memchr(base + cursor, 0x0A, end - cursor) {
            let newline = base.distance(to: UnsafeRawPointer(found))
            let index = result.newlineCount
            if index % sampleStride == 0 {
                result.sampledNewlines.append(newline)
            }
            if result.firstNewline == nil {
                result.firstNewline = newline
            }
            if let previous = previousNewline {
                let lineStart = previous + 1
                let length = newline - lineStart
                if length >= longLineThreshold {
                    result.internalLongLines.append((index, lineStart, length))
                }
            }
            previousNewline = newline
            result.newlineCount += 1
            cursor = newline + 1

            untilCancelCheck -= 1
            if untilCancelCheck == 0 {
                untilCancelCheck = 1 << 14
                if isStopped() {
                    break
                }
            }
        }
        result.lastNewline = previousNewline
        return result
    }

    /// The absolute offset of the chunk's `localIndex`-th newline: jump to the
    /// nearest sample at or before it, then walk forward at most
    /// `sampleStride - 1` lines.
    private static func newlineOffset(inChunk chunk: ChunkScan, localIndex: Int,
                                      base: UnsafeRawPointer) -> Int {
        var cursor = chunk.sampledNewlines[localIndex / sampleStride]
        var remaining = localIndex % sampleStride
        while remaining > 0 {
            guard let found = memchr(base + cursor + 1, 0x0A, chunk.end - cursor - 1) else {
                break
            }
            cursor = base.distance(to: UnsafeRawPointer(found))
            remaining -= 1
        }
        return cursor
    }

    /// Scans the file one group of chunks at a time — one chunk per core, run
    /// concurrently — then stitches each group in file order and publishes it.
    ///
    /// Newline scanning is embarrassingly parallel; only three things depend on
    /// what came before a chunk, and the stitch handles all of them: the line
    /// number of each long line, which newlines fall on a checkpoint (every
    /// `checkpointStride`-th line, counted from the start of the file), and a
    /// line that straddles a chunk boundary. Publishing per group keeps the
    /// line count and scroller growing while a large file is still indexing,
    /// as the serial scan does.
    private func scanParallel(file: MappedFile, chunkSize: Int, onProgress: () -> Void) {
        let buffer = file.buffer
        let total = buffer.count

        guard total > 0, let base = buffer.baseAddress, chunkSize > 0 else {
            finish(pendingCheckpoints: [], pendingLongLines: [], lineCount: 0)
            onProgress()
            return
        }

        let stride = LineIndex.checkpointStride
        let chunkCount = (total + chunkSize - 1) / chunkSize
        let groupSize = max(1, ProcessInfo.processInfo.activeProcessorCount)

        var pendingCheckpoints: [Checkpoint] = []
        var pendingLongLines: [LongLine] = []
        var linesSoFar = 0            // newlines before the chunk being stitched
        var openLineStart = 0         // where the not-yet-terminated line began
        var firstChunk = 0

        while firstChunk < chunkCount && !isStopped() {
            let lastChunk = min(chunkCount, firstChunk + groupSize)
            var scans = [ChunkScan?](repeating: nil, count: lastChunk - firstChunk)
            scans.withUnsafeMutableBufferPointer { slots in
                DispatchQueue.concurrentPerform(iterations: slots.count) { position in
                    let start = (firstChunk + position) * chunkSize
                    let end = min(total, start + chunkSize)
                    slots[position] = LineIndex.scanChunk(base: base, start: start, end: end,
                                                          isStopped: { self.isStopped() })
                }
            }
            if isStopped() {
                break            // a chunk may have stopped early; do not stitch it
            }

            for case let chunk? in scans {
                guard let first = chunk.firstNewline, let last = chunk.lastNewline else {
                    continue     // no newline here: the open line runs on
                }

                // The line ending at this chunk's first newline began at
                // openLineStart — possibly chunks ago.
                let firstLength = first - openLineStart
                if firstLength >= LineIndex.longLineThreshold {
                    pendingLongLines.append(LongLine(
                        lineNumber: linesSoFar, byteOffset: openLineStart, byteLength: firstLength))
                }
                for longLine in chunk.internalLongLines {
                    pendingLongLines.append(LongLine(
                        lineNumber: linesSoFar + longLine.endsAtLocalNewline,
                        byteOffset: longLine.byteOffset,
                        byteLength: longLine.byteLength))
                }

                // Checkpoint k marks the start of line k·stride, i.e. the byte
                // after newline number k·stride − 1 (counting from 0).
                var checkpoint = linesSoFar / stride + 1
                while checkpoint * stride - 1 < linesSoFar + chunk.newlineCount {
                    let local = checkpoint * stride - 1 - linesSoFar
                    let newline = LineIndex.newlineOffset(inChunk: chunk, localIndex: local, base: base)
                    pendingCheckpoints.append(Checkpoint(byteOffset: newline + 1, visualRowOffset: 0))
                    checkpoint += 1
                }

                linesSoFar += chunk.newlineCount
                openLineStart = last + 1
            }

            publish(pendingCheckpoints: &pendingCheckpoints,
                    pendingLongLines: &pendingLongLines,
                    lineCount: linesSoFar)
            onProgress()
            firstChunk = lastChunk
        }

        // Trailing bytes after the final newline form one last line.
        var lines = linesSoFar
        if !isStopped() && openLineStart < total {
            let byteLength = total - openLineStart
            if byteLength >= LineIndex.longLineThreshold {
                pendingLongLines.append(LongLine(
                    lineNumber: lines, byteOffset: openLineStart, byteLength: byteLength))
            }
            lines += 1
        }

        finish(pendingCheckpoints: pendingCheckpoints,
               pendingLongLines: pendingLongLines,
               lineCount: lines)
        onProgress()
    }

    /// Appends newly found checkpoints + long lines and invalidates layouts.
    private func publish(
        pendingCheckpoints: inout [Checkpoint],
        pendingLongLines: inout [LongLine],
        lineCount lines: Int
    ) {
        lock.lock()
        checkpoints.append(contentsOf: pendingCheckpoints)
        longLines.append(contentsOf: pendingLongLines)
        lineCount = lines
        layoutsValid = false
        lock.unlock()
        pendingCheckpoints.removeAll(keepingCapacity: true)
        pendingLongLines.removeAll(keepingCapacity: true)
    }

    private func finish(
        pendingCheckpoints: [Checkpoint],
        pendingLongLines: [LongLine],
        lineCount lines: Int
    ) {
        lock.lock()
        checkpoints.append(contentsOf: pendingCheckpoints)
        longLines.append(contentsOf: pendingLongLines)
        lineCount = lines
        indexingComplete = true
        layoutsValid = false
        lock.unlock()
    }

    // MARK: - Visual-row lookup

    /// Returns one `VisualLine` for every visual row in `range`, computed by
    /// walking lines from the nearest checkpoint with the current wrap width.
    func visualLines(forRows range: Range<Int>, file: MappedFile) -> [VisualLine] {
        var result: [VisualLine] = []
        let snap = snapshot()
        let buffer = file.buffer

        let isRequestValid = !range.isEmpty
            && range.lowerBound >= 0
            && range.upperBound <= snap.rowCount

        if isRequestValid, let base = buffer.baseAddress {
            result = collectVisualLines(
                for: range,
                snapshot: snap,
                base: base,
                total: buffer.count
            )
        }
        return result
    }

    private func collectVisualLines(
        for range: Range<Int>,
        snapshot: (checkpoints: [Checkpoint], lineCount: Int, rowCount: Int, wrap: Int, longLineLayouts: [LongLineLayout]),
        base: UnsafeRawPointer,
        total: Int
    ) -> [VisualLine] {
        var result: [VisualLine] = []
        result.reserveCapacity(range.count)

        let stride = LineIndex.checkpointStride
        let startCheckpoint = checkpointIndex(forRow: range.lowerBound, in: snapshot.checkpoints)
        let wrap = snapshot.wrap

        var offset = snapshot.checkpoints[startCheckpoint].byteOffset
        var currentRow = snapshot.checkpoints[startCheckpoint].visualRowOffset
        var currentLine = startCheckpoint * stride

        while currentLine < snapshot.lineCount && currentRow < range.upperBound {
            let lineStart = offset
            let lineEnd: Int
            if let newline = memchr(base + offset, 0x0A, total - offset) {
                lineEnd = base.distance(to: UnsafeRawPointer(newline))
                offset = lineEnd + 1
            } else {
                lineEnd = total
                offset = total
            }

            let byteLength = lineEnd - lineStart
            let chunks = LineIndex.chunkCount(forByteLength: byteLength, wrap: wrap)
            appendVisibleChunks(
                of: currentLine,
                lineStart: lineStart,
                lineEnd: lineEnd,
                byteLength: byteLength,
                chunkCount: chunks,
                lineFirstRow: currentRow,
                requestedRows: range,
                wrap: wrap,
                into: &result
            )

            currentRow += chunks
            currentLine += 1
        }
        return result
    }

    /// Binary-searches `checkpoints` for the last one at or before `row`.
    private func checkpointIndex(forRow row: Int, in checkpoints: [Checkpoint]) -> Int {
        var result = 0
        var low = 0
        var high = checkpoints.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if checkpoints[mid].visualRowOffset <= row {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Emits a `VisualLine` for each visible chunk of one document line. Short
    /// lines emit exactly one chunk covering the whole line; long lines split
    /// at `wrap`-byte intervals.
    private func appendVisibleChunks(
        of documentLine: Int,
        lineStart: Int,
        lineEnd: Int,
        byteLength: Int,
        chunkCount: Int,
        lineFirstRow: Int,
        requestedRows: Range<Int>,
        wrap: Int,
        into result: inout [VisualLine]
    ) {
        let lineLastRow = lineFirstRow + chunkCount
        let isLineVisible = lineLastRow > requestedRows.lowerBound
            && lineFirstRow < requestedRows.upperBound

        if isLineVisible {
            let firstChunk = max(0, requestedRows.lowerBound - lineFirstRow)
            let lastChunk = min(chunkCount, requestedRows.upperBound - lineFirstRow)
            let isShortLine = byteLength < LineIndex.longLineThreshold
            var chunk = firstChunk
            while chunk < lastChunk {
                let chunkStart: Int
                let chunkEnd: Int
                if isShortLine {
                    chunkStart = lineStart
                    chunkEnd = lineEnd
                } else {
                    chunkStart = lineStart + chunk * wrap
                    chunkEnd = min(lineEnd, chunkStart + wrap)
                }
                result.append(VisualLine(
                    documentLine: documentLine,
                    chunkIndex: chunk,
                    chunkCount: chunkCount,
                    byteRange: chunkStart..<chunkEnd
                ))
                chunk += 1
            }
        }
    }

    // MARK: - Byte-offset / document-line lookup

    /// Returns the visual row at the start of document line `target` (clamped
    /// to a valid line). Used by Go to Line.
    func visualRow(forDocumentLine target: Int, file: MappedFile) -> Int {
        var result = 0
        let snap = snapshot()

        if snap.lineCount > 0, let base = file.buffer.baseAddress {
            let clampedTarget = max(0, min(target, snap.lineCount - 1))
            let stride = LineIndex.checkpointStride
            let cpIndex = min(clampedTarget / stride, snap.checkpoints.count - 1)
            let checkpoint = snap.checkpoints[cpIndex]
            let wrap = snap.wrap

            var offset = checkpoint.byteOffset
            var currentRow = checkpoint.visualRowOffset
            var currentLine = cpIndex * stride
            let total = file.buffer.count

            while currentLine < clampedTarget {
                let lineStart = offset
                guard let newline = memchr(base + offset, 0x0A, total - offset) else {
                    break
                }
                let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                currentRow += LineIndex.chunkCount(forByteLength: lineEnd - lineStart, wrap: wrap)
                offset = lineEnd + 1
                currentLine += 1
            }
            result = currentRow
        }
        return result
    }

    /// Returns the visual row that contains byte `target`. Used to scroll a
    /// search match into view.
    func visualRow(forByteOffset target: Int, file: MappedFile) -> Int {
        var result = 0
        let snap = snapshot()
        let buffer = file.buffer

        if let base = buffer.baseAddress, snap.lineCount > 0 {
            let clampedTarget = min(max(0, target), max(0, buffer.count - 1))
            result = rowContaining(
                byteOffset: clampedTarget,
                snapshot: snap,
                base: base,
                total: buffer.count
            )
        }
        return result
    }

    private func rowContaining(
        byteOffset target: Int,
        snapshot: (checkpoints: [Checkpoint], lineCount: Int, rowCount: Int, wrap: Int, longLineLayouts: [LongLineLayout]),
        base: UnsafeRawPointer,
        total: Int
    ) -> Int {
        let stride = LineIndex.checkpointStride
        let startCheckpoint = checkpointIndex(forByteOffset: target, in: snapshot.checkpoints)
        let wrap = snapshot.wrap

        var offset = snapshot.checkpoints[startCheckpoint].byteOffset
        var currentRow = snapshot.checkpoints[startCheckpoint].visualRowOffset
        var currentLine = startCheckpoint * stride
        var result = max(0, snapshot.rowCount - 1)
        var found = false

        while currentLine < snapshot.lineCount && !found {
            let lineStart = offset
            let lineEnd: Int
            if let newline = memchr(base + offset, 0x0A, total - offset) {
                lineEnd = base.distance(to: UnsafeRawPointer(newline))
                offset = lineEnd + 1
            } else {
                lineEnd = total
                offset = total
            }

            let byteLength = lineEnd - lineStart
            let chunks = LineIndex.chunkCount(forByteLength: byteLength, wrap: wrap)
            if target < offset || currentLine == snapshot.lineCount - 1 {
                let withinLine = max(0, target - lineStart)
                let chunkIndex: Int
                if byteLength < LineIndex.longLineThreshold {
                    chunkIndex = 0
                } else {
                    chunkIndex = min(chunks - 1, withinLine / wrap)
                }
                result = currentRow + chunkIndex
                found = true
            } else {
                currentRow += chunks
                currentLine += 1
            }
        }
        return result
    }

    private func checkpointIndex(forByteOffset target: Int, in checkpoints: [Checkpoint]) -> Int {
        var result = 0
        var low = 0
        var high = checkpoints.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if checkpoints[mid].byteOffset <= target {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    // MARK: - Line lookup for the edited layout

    /// The line containing byte `target` (clamped to the file): its start
    /// offset, 0-based line number, and first visual row. One checkpoint walk
    /// answers all three — the edited layout uses this to align edit spans to
    /// line boundaries and translate gap coordinates.
    func lineLocation(containingByteOffset target: Int, file: MappedFile)
        -> (lineStart: Int, lineNumber: Int, visualRow: Int) {
        var result = (lineStart: 0, lineNumber: 0, visualRow: 0)
        let snap = snapshot()
        let buffer = file.buffer

        if let base = buffer.baseAddress, snap.lineCount > 0 {
            let clamped = min(max(0, target), max(0, buffer.count - 1))
            let startCheckpoint = checkpointIndex(forByteOffset: clamped, in: snap.checkpoints)
            var offset = snap.checkpoints[startCheckpoint].byteOffset
            var currentRow = snap.checkpoints[startCheckpoint].visualRowOffset
            var currentLine = startCheckpoint * LineIndex.checkpointStride
            var found = false

            while currentLine < snap.lineCount && !found {
                let lineStart = offset
                let lineEnd: Int
                if let newline = memchr(base + offset, 0x0A, buffer.count - offset) {
                    lineEnd = base.distance(to: UnsafeRawPointer(newline))
                    offset = lineEnd + 1
                } else {
                    lineEnd = buffer.count
                    offset = buffer.count
                }

                if clamped < offset || currentLine == snap.lineCount - 1 {
                    result = (lineStart, currentLine, currentRow)
                    found = true
                } else {
                    currentRow += LineIndex.chunkCount(forByteLength: lineEnd - lineStart,
                                                       wrap: snap.wrap)
                    currentLine += 1
                }
            }
        }
        return result
    }

    /// The byte offset just past the newline that ends the line containing
    /// `target`, or the file size when the file ends without one.
    func nextLineStart(afterByteOffset target: Int, file: MappedFile) -> Int {
        let buffer = file.buffer
        var result = buffer.count
        if target < buffer.count, target >= 0, let base = buffer.baseAddress {
            if let newline = memchr(base + target, 0x0A, buffer.count - target) {
                result = base.distance(to: UnsafeRawPointer(newline)) + 1
            }
        }
        return result
    }
}
