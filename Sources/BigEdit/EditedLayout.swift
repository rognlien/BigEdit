import Foundation

/// The line / visual-row layout of the logical (edited) document.
///
/// The original file's `LineIndex` is immutable — it is never rebuilt after an
/// edit. Instead the logical document is modelled as an alternating sequence
/// of *gaps* and *spans*:
///
/// - A **gap** is a maximal run of untouched original bytes that begins and
///   ends on original line boundaries. Every line/row question inside a gap
///   is answered by the original `LineIndex`, then shifted by the cumulative
///   byte/line/row deltas of the segments before it.
/// - A **span** covers one edited region *plus the partial original lines
///   flanking it* (spans always extend outward to line boundaries, so gaps
///   stay line-aligned). A span caches its own local line layout, rebuilt by
///   scanning just its content whenever it changes — O(edit), never O(file).
///
/// Cumulative totals over the segment sequence are kept in prefix-sum arrays,
/// recomputed in O(#spans) after an edit. Queries are O(log #spans) plus one
/// bounded `LineIndex` walk. All methods must be called on the main thread.
final class EditedLayout {

    private let file: MappedFile
    private let index: LineIndex

    /// The logical document length in bytes, kept in step with every edit.
    private(set) var length: Int

    private var spans: [Span] = []
    private var gaps: [Gap] = []
    private var wrapBytes = LineIndex.defaultWrapBytes

    // Prefix sums over the alternating segment sequence — segment 2i is
    // gaps[i], segment 2i+1 is spans[i]. Rebuilt lazily after invalidation.
    private var segmentStartOffsets: [Int] = []
    private var segmentStartLines: [Int] = []
    private var segmentStartRows: [Int] = []
    private var totalLines = 0
    private var totalRows = 0
    private var tableValid = false

    init(file: MappedFile, index: LineIndex) {
        self.file = file
        self.index = index
        self.length = file.size
    }

    /// True once any edit has been applied; without edits every query is a
    /// direct passthrough to the original `LineIndex`.
    var hasSpans: Bool {
        !spans.isEmpty
    }

    /// The number of edit spans — exposed for tests and diagnostics.
    var spanCount: Int {
        spans.count
    }

    // MARK: - Segments

    /// One run of untouched original bytes between spans, line-aligned.
    /// Cached coordinates locate its first line in the original index.
    private struct Gap {
        var originalRange: Range<Int>
        var startLineNumber = 0
        var startVisualRow = 0
        var lineCount = 0
        var visualRowCount = 0
        var cacheValid = false
    }

    /// One edited region, line-aligned, with its own local line layout.
    private struct Span {
        var contentLength: Int
        var originalRange: Range<Int>
        var localLineStartOffsets: [Int]
        var localRowOffsets: [Int]
        var endsWithNewline: Bool
        var visualRowCount: Int

        var lineCount: Int {
            localLineStartOffsets.count
        }

        /// The content range of a local line, excluding its newline.
        func lineContentRange(_ line: Int) -> Range<Int> {
            let start = localLineStartOffsets[line]
            let end: Int
            if line + 1 < localLineStartOffsets.count {
                end = localLineStartOffsets[line + 1] - 1
            } else {
                end = contentLength - (endsWithNewline ? 1 : 0)
            }
            return start..<end
        }

        /// The local line containing `localOffset` — the last line starting
        /// at or before it.
        func lineIndex(containingLocalOffset localOffset: Int) -> Int {
            var result = 0
            var low = 0
            var high = localLineStartOffsets.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if localLineStartOffsets[mid] <= localOffset {
                    result = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return result
        }

        /// The local line containing visual row `localRow`.
        func lineIndex(containingLocalRow localRow: Int) -> Int {
            var result = 0
            var low = 0
            var high = localRowOffsets.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if localRowOffsets[mid] <= localRow {
                    result = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return result
        }
    }

    private var segmentCount: Int {
        spans.count + gaps.count
    }

    private func segmentByteLength(_ segment: Int) -> Int {
        segment % 2 == 0 ? gaps[segment / 2].originalRange.count : spans[segment / 2].contentLength
    }

    private func segmentLineCount(_ segment: Int) -> Int {
        segment % 2 == 0 ? gaps[segment / 2].lineCount : spans[segment / 2].lineCount
    }

    private func segmentRowCount(_ segment: Int) -> Int {
        segment % 2 == 0 ? gaps[segment / 2].visualRowCount : spans[segment / 2].visualRowCount
    }

    // MARK: - Invalidation

    /// Sets the wrap width for long lines, mirroring it into the original
    /// index and re-deriving every span's row layout.
    func setWrapBytes(_ wrap: Int) {
        let clamped = max(LineIndex.minimumWrapBytes, wrap)
        index.setWrapBytes(clamped)
        if clamped != wrapBytes {
            wrapBytes = clamped
            for spanIndex in spans.indices {
                rebuildSpanRows(&spans[spanIndex])
            }
            for gapIndex in gaps.indices {
                gaps[gapIndex].cacheValid = false
            }
            tableValid = false
        }
    }

    /// Call when the background indexer publishes progress: the trailing
    /// gap's totals grow with the index.
    func indexDidProgress() {
        tableValid = false
    }

    // MARK: - Queries

    var visualRowCount: Int {
        var result: Int
        if spans.isEmpty {
            result = index.visualRowCount
        } else {
            ensureTableValid()
            result = totalRows
        }
        return result
    }

    var documentLineCount: Int {
        var result: Int
        if spans.isEmpty {
            result = index.count
        } else {
            ensureTableValid()
            result = totalLines
        }
        return result
    }

    /// One `VisualLine` per row in `range`, with `byteRange` in logical
    /// offsets and `documentLine` numbered in the logical document.
    func visualLines(forRows range: Range<Int>) -> [LineIndex.VisualLine] {
        var result: [LineIndex.VisualLine] = []
        if spans.isEmpty {
            result = index.visualLines(forRows: range, file: file)
        } else {
            ensureTableValid()
            let clamped = range.clamped(to: 0..<totalRows)
            if !clamped.isEmpty {
                collectRows(clamped, into: &result)
            }
        }
        return result
    }

    /// The visual row containing logical byte `offset` (clamped).
    func visualRow(forLogicalByteOffset offset: Int) -> Int {
        var result = 0
        if spans.isEmpty {
            result = index.visualRow(forByteOffset: offset, file: file)
        } else if length > 0 {
            ensureTableValid()
            let clamped = min(max(0, offset), length - 1)
            let segment = segmentIndex(containingOffset: clamped)
            let local = clamped - segmentStartOffsets[segment]
            if segment % 2 == 0 {
                let gap = gaps[segment / 2]
                let original = gap.originalRange.lowerBound + local
                let originalRow = index.visualRow(forByteOffset: original, file: file)
                result = segmentStartRows[segment] + max(0, originalRow - gap.startVisualRow)
            } else {
                let span = spans[segment / 2]
                let line = span.lineIndex(containingLocalOffset: local)
                let content = span.lineContentRange(line)
                let chunk = chunkIndex(forLocalOffset: local, lineContent: content)
                result = segmentStartRows[segment] + span.localRowOffsets[line] + chunk
            }
            result = min(result, max(0, totalRows - 1))
        }
        return result
    }

    /// The first visual row of document line `target` (clamped).
    func visualRow(forDocumentLine target: Int) -> Int {
        var result = 0
        if spans.isEmpty {
            result = index.visualRow(forDocumentLine: target, file: file)
        } else {
            ensureTableValid()
            if totalLines > 0 {
                let clamped = max(0, min(target, totalLines - 1))
                let segment = segmentIndex(containingLine: clamped)
                let local = clamped - segmentStartLines[segment]
                if segment % 2 == 0 {
                    let gap = gaps[segment / 2]
                    let originalLine = gap.startLineNumber + local
                    let originalRow = index.visualRow(forDocumentLine: originalLine, file: file)
                    result = segmentStartRows[segment] + max(0, originalRow - gap.startVisualRow)
                } else {
                    result = segmentStartRows[segment] + spans[segment / 2].localRowOffsets[local]
                }
                result = min(result, max(0, totalRows - 1))
            }
        }
        return result
    }

    // MARK: - Row assembly

    private func collectRows(_ range: Range<Int>, into result: inout [LineIndex.VisualLine]) {
        result.reserveCapacity(range.count)
        var row = range.lowerBound
        var segment = segmentIndex(containingRow: row)
        while row < range.upperBound && segment < segmentCount {
            let segmentEnd = segmentStartRows[segment] + segmentRowCount(segment)
            if row < segmentEnd {
                let localRows = (row - segmentStartRows[segment])
                    ..< (min(range.upperBound, segmentEnd) - segmentStartRows[segment])
                if segment % 2 == 0 {
                    appendGapRows(segment: segment, localRows: localRows, into: &result)
                } else {
                    appendSpanRows(segment: segment, localRows: localRows, into: &result)
                }
                row = segmentStartRows[segment] + localRows.upperBound
            }
            segment += 1
        }
    }

    private func appendGapRows(
        segment: Int,
        localRows: Range<Int>,
        into result: inout [LineIndex.VisualLine]
    ) {
        let gap = gaps[segment / 2]
        let originalRows = (gap.startVisualRow + localRows.lowerBound)
            ..< (gap.startVisualRow + localRows.upperBound)
        let clamped = originalRows.clamped(to: 0..<index.visualRowCount)
        let byteShift = segmentStartOffsets[segment] - gap.originalRange.lowerBound
        let lineShift = segmentStartLines[segment] - gap.startLineNumber
        for line in index.visualLines(forRows: clamped, file: file) {
            result.append(LineIndex.VisualLine(
                documentLine: line.documentLine + lineShift,
                chunkIndex: line.chunkIndex,
                chunkCount: line.chunkCount,
                byteRange: (line.byteRange.lowerBound + byteShift)
                    ..< (line.byteRange.upperBound + byteShift)
            ))
        }
    }

    private func appendSpanRows(
        segment: Int,
        localRows: Range<Int>,
        into result: inout [LineIndex.VisualLine]
    ) {
        let span = spans[segment / 2]
        let byteShift = segmentStartOffsets[segment]
        let lineShift = segmentStartLines[segment]
        for localRow in localRows {
            let line = span.lineIndex(containingLocalRow: localRow)
            let content = span.lineContentRange(line)
            let chunkCount = LineIndex.chunkCount(forByteLength: content.count, wrap: wrapBytes)
            let chunk = localRow - span.localRowOffsets[line]
            let chunkStart: Int
            let chunkEnd: Int
            if content.count < LineIndex.longLineThreshold {
                chunkStart = content.lowerBound
                chunkEnd = content.upperBound
            } else {
                chunkStart = content.lowerBound + chunk * wrapBytes
                chunkEnd = min(content.upperBound, chunkStart + wrapBytes)
            }
            result.append(LineIndex.VisualLine(
                documentLine: lineShift + line,
                chunkIndex: chunk,
                chunkCount: chunkCount,
                byteRange: (byteShift + chunkStart)..<(byteShift + chunkEnd)
            ))
        }
    }

    private func chunkIndex(forLocalOffset localOffset: Int, lineContent: Range<Int>) -> Int {
        var result = 0
        if lineContent.count >= LineIndex.longLineThreshold {
            let chunkCount = LineIndex.chunkCount(forByteLength: lineContent.count, wrap: wrapBytes)
            let within = max(0, localOffset - lineContent.lowerBound)
            result = min(chunkCount - 1, within / wrapBytes)
        }
        return result
    }

    // MARK: - Applying edits

    /// Updates the layout after the piece table replaced `replacedRange`
    /// (pre-edit logical offsets) with `insertedLength` bytes. `contentReader`
    /// reads post-edit logical bytes — the affected span's content is
    /// re-derived by scanning only those bytes.
    func applyReplacement(
        _ replacedRange: Range<Int>,
        insertedLength: Int,
        contentReader: (Range<Int>) -> [UInt8]
    ) {
        if gaps.isEmpty {
            gaps = [Gap(originalRange: 0..<file.size)]
            tableValid = false
        }
        ensureTableValid()

        let delta = insertedLength - replacedRange.count

        // Align outward to logical line boundaries in the pre-edit space.
        var alignedLower = logicalLineStart(containingPosition: replacedRange.lowerBound)
        var alignedUpper = logicalLineEnd(afterPosition: replacedRange.upperBound)

        // Absorb every span the aligned region strictly overlaps. Touching
        // spans deliberately stay separate — merging on mere adjacency would
        // snowball per-line edits (Replace All) into one ever-growing span
        // that is rescanned on every splice.
        var firstSpan = spans.count
        var lastSpan = -1
        for spanIndex in spans.indices {
            let start = segmentStartOffsets[2 * spanIndex + 1]
            let end = start + spans[spanIndex].contentLength
            if start < alignedUpper && end > alignedLower {
                firstSpan = min(firstSpan, spanIndex)
                lastSpan = max(lastSpan, spanIndex)
            }
        }
        if firstSpan <= lastSpan {
            let firstStart = segmentStartOffsets[2 * firstSpan + 1]
            let lastEnd = segmentStartOffsets[2 * lastSpan + 1] + spans[lastSpan].contentLength
            alignedLower = min(alignedLower, firstStart)
            alignedUpper = max(alignedUpper, lastEnd)
        }

        // Translate the aligned boundaries to original offsets while the
        // pre-edit table is still valid. A boundary landing on a merged span
        // takes that span's original boundary — the positional lookup cannot
        // see spans whose content is empty.
        var originalLower = originalPosition(ofAligned: alignedLower)
        var originalUpper = originalPosition(ofAligned: alignedUpper)
        if firstSpan <= lastSpan {
            if alignedLower == segmentStartOffsets[2 * firstSpan + 1] {
                originalLower = spans[firstSpan].originalRange.lowerBound
            }
            if alignedUpper == segmentStartOffsets[2 * lastSpan + 1] + spans[lastSpan].contentLength {
                originalUpper = spans[lastSpan].originalRange.upperBound
            }
        }

        // Build the replacement span from the post-edit content.
        let content = contentReader(alignedLower..<(alignedUpper + delta))
        let newSpan = makeSpan(content: content, originalRange: originalLower..<originalUpper)

        // Splice the span list — dropping a span that covers nothing at all —
        // and re-derive the gaps between spans. Insertion order follows the
        // original ranges, which stay monotone along the logical document.
        let coversNothing = newSpan.contentLength == 0 && newSpan.originalRange.isEmpty
        if firstSpan <= lastSpan {
            spans.replaceSubrange(firstSpan...lastSpan, with: coversNothing ? [] : [newSpan])
        } else if !coversNothing {
            // Spans stay ordered by original range, which is what rebuildGaps
            // walks. That alone is not enough: a span covering inserted text
            // has an empty original range, so two of them compare equal and
            // neither can be placed relative to the other. Typing a second
            // newline straight after the first produced exactly that pair, and
            // the new span landed before the old one — laying the document out
            // in the wrong order. Logical position breaks the tie; the pre-edit
            // segment offsets are still valid here.
            var insertAt = 0
            while insertAt < spans.count {
                let existing = spans[insertAt].originalRange
                let incoming = newSpan.originalRange
                let existingComesFirst: Bool
                if existing.lowerBound != incoming.lowerBound {
                    existingComesFirst = existing.lowerBound < incoming.lowerBound
                } else if existing.upperBound != incoming.upperBound {
                    existingComesFirst = existing.upperBound < incoming.upperBound
                } else {
                    existingComesFirst = segmentStartOffsets[2 * insertAt + 1] < alignedLower
                }
                if !existingComesFirst {
                    break
                }
                insertAt += 1
            }
            spans.insert(newSpan, at: insertAt)
        }
        rebuildGaps()

        length += delta
        tableValid = false
    }

    // MARK: - Alignment helpers (pre-edit logical space)

    /// The start of the logical line containing position `position` — the
    /// largest line start at or before it. Position `length` counts as a line
    /// start when the document ends with a newline (or is empty).
    private func logicalLineStart(containingPosition position: Int) -> Int {
        var result = 0
        if length > 0 {
            if position >= length {
                result = lastByteIsNewline() ? length
                    : logicalLineStart(containingPosition: length - 1)
            } else {
                let segment = segmentIndex(containingOffset: position)
                let local = position - segmentStartOffsets[segment]
                if segment % 2 == 0 {
                    let gap = gaps[segment / 2]
                    let original = gap.originalRange.lowerBound + local
                    let location = index.lineLocation(containingByteOffset: original, file: file)
                    let lineStart = max(location.lineStart, gap.originalRange.lowerBound)
                    result = segmentStartOffsets[segment]
                        + (lineStart - gap.originalRange.lowerBound)
                } else {
                    let span = spans[segment / 2]
                    let line = span.lineIndex(containingLocalOffset: local)
                    result = segmentStartOffsets[segment] + span.localLineStartOffsets[line]
                }
            }
        }
        return result
    }

    /// The exclusive end of the logical line containing position `position`
    /// (the next line start, or the document end).
    private func logicalLineEnd(afterPosition position: Int) -> Int {
        var result = length
        if position < length {
            let segment = segmentIndex(containingOffset: position)
            let local = position - segmentStartOffsets[segment]
            if segment % 2 == 0 {
                let gap = gaps[segment / 2]
                let original = gap.originalRange.lowerBound + local
                let nextStart = min(index.nextLineStart(afterByteOffset: original, file: file),
                                    gap.originalRange.upperBound)
                result = segmentStartOffsets[segment]
                    + (nextStart - gap.originalRange.lowerBound)
            } else {
                let span = spans[segment / 2]
                let line = span.lineIndex(containingLocalOffset: local)
                let next = line + 1 < span.lineCount
                    ? span.localLineStartOffsets[line + 1]
                    : span.contentLength
                result = segmentStartOffsets[segment] + next
            }
        }
        return result
    }

    /// Whether the logical document's final byte is a newline.
    private func lastByteIsNewline() -> Bool {
        var result = false
        var segment = segmentCount - 1
        while segment >= 0 && segmentByteLength(segment) == 0 {
            segment -= 1
        }
        if segment >= 0 {
            if segment % 2 == 0 {
                let gap = gaps[segment / 2]
                result = file.buffer[gap.originalRange.upperBound - 1] == 0x0A
            } else {
                result = spans[segment / 2].endsWithNewline
            }
        }
        return result
    }

    /// Translates a line-aligned pre-edit logical position — one that is
    /// never strictly inside a span — to its original-file offset.
    private func originalPosition(ofAligned position: Int) -> Int {
        var result = file.size
        if position < length {
            let segment = segmentIndex(containingOffset: position)
            let local = position - segmentStartOffsets[segment]
            if segment % 2 == 0 {
                result = gaps[segment / 2].originalRange.lowerBound + local
            } else {
                result = spans[segment / 2].originalRange.lowerBound
            }
        }
        return result
    }

    // MARK: - Span construction

    private func makeSpan(content: [UInt8], originalRange: Range<Int>) -> Span {
        var lineStarts: [Int] = []
        if !content.isEmpty {
            lineStarts.append(0)
        }
        for (position, byte) in content.enumerated() where byte == 0x0A {
            if position + 1 < content.count {
                lineStarts.append(position + 1)
            }
        }
        var span = Span(contentLength: content.count,
                        originalRange: originalRange,
                        localLineStartOffsets: lineStarts,
                        localRowOffsets: [],
                        endsWithNewline: content.last == 0x0A,
                        visualRowCount: 0)
        rebuildSpanRows(&span)
        return span
    }

    private func rebuildSpanRows(_ span: inout Span) {
        var rows: [Int] = []
        rows.reserveCapacity(span.lineCount)
        var cumulative = 0
        for line in 0..<span.lineCount {
            rows.append(cumulative)
            cumulative += LineIndex.chunkCount(forByteLength: span.lineContentRange(line).count,
                                               wrap: wrapBytes)
        }
        span.localRowOffsets = rows
        span.visualRowCount = cumulative
    }

    /// Re-derives the gap list from the span list, reusing cached gap
    /// coordinates wherever a gap's original range is unchanged.
    private func rebuildGaps() {
        var previousGaps: [Range<Int>: Gap] = [:]
        for gap in gaps {
            previousGaps[gap.originalRange] = gap
        }
        var newGaps: [Gap] = []
        var previousEnd = 0
        for span in spans {
            newGaps.append(previousGaps[previousEnd..<span.originalRange.lowerBound]
                ?? Gap(originalRange: previousEnd..<span.originalRange.lowerBound))
            previousEnd = span.originalRange.upperBound
        }
        newGaps.append(previousGaps[previousEnd..<file.size]
            ?? Gap(originalRange: previousEnd..<file.size))
        gaps = newGaps
    }

    // MARK: - Prefix sums

    private func ensureTableValid() {
        if !tableValid {
            for gapIndex in gaps.indices where !gaps[gapIndex].cacheValid {
                refreshGapCache(gapIndex)
            }
            rebuildPrefixSums()
            tableValid = true
        }
    }

    private func refreshGapCache(_ gapIndex: Int) {
        var gap = gaps[gapIndex]
        let range = gap.originalRange
        if range.isEmpty {
            gap.startLineNumber = 0
            gap.startVisualRow = 0
            gap.lineCount = 0
            gap.visualRowCount = 0
            gap.cacheValid = true
        } else {
            let start = index.lineLocation(containingByteOffset: range.lowerBound, file: file)
            gap.startLineNumber = start.lineNumber
            gap.startVisualRow = start.visualRow
            if range.upperBound >= file.size {
                // The trailing gap ends at the file's end: its totals grow
                // while indexing is still running, so only cache them once
                // the index is complete.
                gap.lineCount = max(0, index.count - start.lineNumber)
                gap.visualRowCount = max(0, index.visualRowCount - start.visualRow)
                gap.cacheValid = index.isComplete
            } else {
                let end = index.lineLocation(containingByteOffset: range.upperBound, file: file)
                gap.lineCount = max(0, end.lineNumber - start.lineNumber)
                gap.visualRowCount = max(0, end.visualRow - start.visualRow)
                gap.cacheValid = true
            }
        }
        gaps[gapIndex] = gap
    }

    private func rebuildPrefixSums() {
        let count = segmentCount
        segmentStartOffsets = Array(repeating: 0, count: count)
        segmentStartLines = Array(repeating: 0, count: count)
        segmentStartRows = Array(repeating: 0, count: count)
        var offset = 0
        var line = 0
        var row = 0
        for segment in 0..<count {
            segmentStartOffsets[segment] = offset
            segmentStartLines[segment] = line
            segmentStartRows[segment] = row
            offset += segmentByteLength(segment)
            line += segmentLineCount(segment)
            row += segmentRowCount(segment)
        }
        totalLines = line
        totalRows = row
    }

    // MARK: - Segment lookup

    private func segmentIndex(containingOffset offset: Int) -> Int {
        segmentIndex(for: offset, starts: segmentStartOffsets, count: segmentByteLength)
    }

    private func segmentIndex(containingRow row: Int) -> Int {
        segmentIndex(for: row, starts: segmentStartRows, count: segmentRowCount)
    }

    private func segmentIndex(containingLine line: Int) -> Int {
        segmentIndex(for: line, starts: segmentStartLines, count: segmentLineCount)
    }

    /// The segment containing `value`: the last segment starting at or before
    /// it, advanced past any empty segments sharing that boundary.
    private func segmentIndex(for value: Int, starts: [Int], count: (Int) -> Int) -> Int {
        var result = 0
        var low = 0
        var high = starts.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= value {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        while result + 1 < starts.count && value >= starts[result] + count(result) {
            result += 1
        }
        return result
    }
}
