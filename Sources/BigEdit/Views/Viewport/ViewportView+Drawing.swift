import AppKit
import CoreText

/// Drawing the visible rows: text, gutter, highlights, selection and caret.
extension ViewportView {

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        if let layout, layout.visualRowCount > 0 {
            drawContent(layout: layout)
        } else {
            drawPlaceholder()
        }
    }

    private func drawContent(layout: EditedLayout) {
        setHorizontalOffset(horizontalOffset)
        let totalRows = layout.visualRowCount
        let firstRow = Int(scrollRow)
        let fraction = CGFloat(scrollRow - Double(firstRow))
        let lastRow = min(totalRows, firstRow + rowsPerPage + 2)
        let rows = layout.visualLines(forRows: firstRow..<lastRow)

        let gutterWidth = self.gutterWidth(for: layout.gutterLineCount)
        let startState = seedState(forFirstRow: firstRow, layout: layout)
        drawCSVGrid(rowCount: rows.count, gutterWidth: gutterWidth, fraction: fraction)
        drawText(rows: rows, gutterWidth: gutterWidth, fraction: fraction,
                 startState: startState)
        drawGutter(rows: rows, width: gutterWidth, fraction: fraction)
        drawInsertionCaret(layout: layout, firstRow: firstRow, fraction: fraction,
                           gutterWidth: gutterWidth)
        drawPinnedCSVHeader(layout: layout, gutterWidth: gutterWidth)
        drawCSVColumnDividers(gutterWidth: gutterWidth)
    }

    /// Draws a tick at each column's trailing edge along the top band, so the
    /// draggable boundaries can be seen rather than only found by feel.
    /// A faint grid under the CSV table — one line below each row and one
    /// along each column divider — so the columns read as cells. Drawn before
    /// the text so highlights, selection and glyphs all sit on top of it.
    private func drawCSVGrid(rowCount: Int, gutterWidth: CGFloat, fraction: CGFloat) {
        guard isCSVRenderingActive else {
            return
        }
        let textOriginX = gutterWidth + gutterPadding
        let textArea = NSRect(x: textOriginX, y: pinnedHeaderHeight,
                              width: bounds.width - textOriginX, height: bounds.height - pinnedHeaderHeight)
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: textArea).addClip()
        NSColor.gridColor.setStroke()
        let grid = NSBezierPath()
        for row in 0..<rowCount {
            let y = pinnedHeaderHeight + CGFloat(row + 1) * lineHeight - fraction * lineHeight - 0.5
            grid.move(to: NSPoint(x: textArea.minX, y: y))
            grid.line(to: NSPoint(x: textArea.maxX, y: y))
        }
        for x in csvDividerPositions() where x >= textArea.minX && x <= textArea.maxX {
            grid.move(to: NSPoint(x: x + 0.5, y: textArea.minY))
            grid.line(to: NSPoint(x: x + 0.5, y: textArea.maxY))
        }
        grid.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawCSVColumnDividers(gutterWidth: CGFloat) {
        guard isCSVRenderingActive else {
            return
        }
        let band = csvDividerBand
        NSColor.separatorColor.setStroke()
        for x in csvDividerPositions() where x >= gutterWidth && x <= bounds.width {
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x + 0.5, y: band.minY + 2))
            tick.line(to: NSPoint(x: x + 0.5, y: band.maxY - 2))
            tick.stroke()
        }
    }

    /// Draws the CSV header row in the strip reserved at the top, so the column
    /// names stay readable however far down the file you scroll.
    private func drawPinnedCSVHeader(layout: EditedLayout, gutterWidth: CGFloat) {
        guard isPinnedHeaderVisible,
              let headerLine = layout.visualLines(forRows: 0..<1).first,
              let headerText = alignedCSVText(decodeChunk(headerLine), visualLine: headerLine)
        else {
            return
        }
        let strip = NSRect(x: 0, y: 0, width: bounds.width, height: lineHeight)
        NSColor.windowBackgroundColor.setFill()
        strip.fill()

        let textOriginX = gutterWidth + gutterPadding
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: textOriginX, y: 0,
                                  width: bounds.width - textOriginX,
                                  height: lineHeight)).addClip()
        csvAttributedRow(headerText, documentLine: 0)
            .draw(at: NSPoint(x: textOriginX - horizontalOffset, y: 0))
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        let underline = NSBezierPath()
        underline.move(to: NSPoint(x: 0, y: lineHeight - 0.5))
        underline.line(to: NSPoint(x: bounds.width, y: lineHeight - 0.5))
        underline.stroke()
    }

    /// Draws the blinking insertion caret at the empty selection's active end.
    private func drawInsertionCaret(layout: EditedLayout, firstRow: Int,
                                    fraction: CGFloat, gutterWidth: CGFloat) {
        guard isViewportFocused, caretVisible, selectionByteRange == nil,
              let caret = selection?.activeOffset else {
            return
        }
        let caretRow = layout.visualRow(forLogicalByteOffset: caret)
        let lastRow = min(layout.visualRowCount, firstRow + rowsPerPage + 2)
        guard caretRow >= firstRow, caretRow < lastRow,
              let visualLine = layout.visualLines(forRows: caretRow..<(caretRow + 1)).first else {
            return
        }
        let start = chunkStartByte(visualLine)
        let clamped = max(start, min(caret, visualLine.byteRange.upperBound))
        let widthToCaret = clamped > start ? textWidth(ofBytes: start..<clamped) : 0
        let textOriginX = gutterWidth + gutterPadding
        let x = textOriginX - horizontalOffset + widthToCaret
        let y = pinnedHeaderHeight + CGFloat(caretRow - firstRow) * lineHeight
            - fraction * lineHeight

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: textOriginX, y: 0,
                                  width: bounds.width - textOriginX, height: bounds.height)).addClip()
        NSColor.labelColor.setFill()
        NSRect(x: x, y: y + 1, width: 1, height: lineHeight - 2).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawText(
        rows: [LineIndex.VisualLine],
        gutterWidth: CGFloat,
        fraction: CGFloat,
        startState: HighlightState
    ) {
        let textOriginX = gutterWidth + gutterPadding

        NSGraphicsContext.current?.saveGraphicsState()
        let textArea = NSRect(
            x: textOriginX,
            y: 0,
            width: bounds.width - textOriginX,
            height: bounds.height
        )
        NSBezierPath(rect: textArea).addClip()

        var state = startState
        var widest: CGFloat = 0
        for (row, visualLine) in rows.enumerated() {
            let y = pinnedHeaderHeight + CGFloat(row) * lineHeight - fraction * lineHeight
            // Search highlights, then selection, then text — each layer above
            // the previous so the rendered text is always on top.
            drawMatchHighlights(for: visualLine, rowY: y, textOriginX: textOriginX)
            drawSelectionForRow(visualLine: visualLine, rowY: y, textOriginX: textOriginX)
            let (attributed, nextState) = displayRow(for: visualLine, startState: state)
            widest = max(widest, attributed.size().width)
            attributed.draw(at: NSPoint(x: textOriginX - horizontalOffset, y: y))
            drawMarkedUnderline(for: visualLine, rowY: y, textOriginX: textOriginX)
            state = nextState
        }
        widestDrawnRowWidth = max(widestDrawnRowWidth, widest)

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// The starting highlight state for the first visible row, found by replaying
    /// a bounded window of preceding rows. Constructs that open further above
    /// than the window won't be detected until scrolled nearer — a deliberate
    /// bound so cost stays tied to the viewport, not the file.
    private func seedState(forFirstRow firstRow: Int, layout: EditedLayout) -> HighlightState {
        guard syntaxMode != .plain, firstRow > 0 else { return .normal }
        let lookback = 400
        let start = max(0, firstRow - lookback)
        let rows = layout.visualLines(forRows: start..<firstRow)
        var state = HighlightState.normal
        for visualLine in rows {
            state = rowEndState(decodeChunk(visualLine), startState: state)
        }
        return state
    }

    /// The drawn form of a row: either the file's own text handed to the active
    /// highlighter, or — in CSV mode — the row's fields padded into the measured
    /// columns.
    private func displayRow(for visualLine: LineIndex.VisualLine, startState: HighlightState)
        -> (NSAttributedString, HighlightState) {
        var result: (NSAttributedString, HighlightState)
        let text = decodeChunk(visualLine)
        if let aligned = alignedCSVText(text, visualLine: visualLine) {
            result = (csvAttributedRow(aligned, documentLine: visualLine.documentLine), .normal)
        } else {
            result = highlightedRow(text, startState: startState)
        }
        return result
    }

    /// `text` split into fields and padded into columns, or `nil` when CSV mode
    /// is off or the row cannot be aligned.
    ///
    /// A long line split across several chunks is left as it is: only a row
    /// holding a whole logical line can be split into fields meaningfully.
    private func alignedCSVText(_ text: String, visualLine: LineIndex.VisualLine) -> String? {
        var result: String?
        if let csvDialect, let csvColumnLayout, visualLine.chunkCount == 1 {
            result = csvColumnLayout.alignedRow(CSVParser.fields(in: text, dialect: csvDialect))
        }
        return result
    }

    /// An aligned CSV row, with the header set in bold so the columns read as a
    /// table rather than as padded text.
    private func csvAttributedRow(_ text: String, documentLine: Int) -> NSAttributedString {
        let isHeader = csvDialect?.hasHeaderRow == true && documentLine == 0
        let rowFont = isHeader
            ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            : font
        return NSAttributedString(
            string: text, attributes: [.font: rowFont, .foregroundColor: NSColor.textColor])
    }

    /// Tokenizes a row with the active highlighter and styles it with the
    /// theme, returning its colouring and the carried state at the row's end.
    func highlightedRow(_ text: String, startState: HighlightState)
        -> (NSAttributedString, HighlightState) {
        let (tokens, endState) = rowTokens(text, startState: startState)
        return (theme.attributedRow(text, tokens: tokens, font: font), endState)
    }

    /// Dispatches a row to the active highlighter for its tokens and the
    /// carried state at the row's end.
    private func rowTokens(_ text: String, startState: HighlightState) -> ([Token], HighlightState) {
        switch syntaxMode {
        case .xml: return XMLHighlighter.tokens(text, startState: startState)
        case .json: return JSONHighlighter.tokens(text, startState: startState)
        case .markdown: return MarkdownHighlighter.tokens(text, startState: startState)
        case .yaml: return YAMLHighlighter.tokens(text, startState: startState)
        case .plain: return ([], .normal)
        }
    }

    /// The carried state at the end of a row, without building its colouring
    /// (used to seed the visible region cheaply).
    private func rowEndState(_ text: String, startState: HighlightState) -> HighlightState {
        switch syntaxMode {
        case .xml: return XMLHighlighter.endState(text, start: startState)
        case .json: return JSONHighlighter.endState(text, start: startState)
        case .markdown: return MarkdownHighlighter.endState(text, start: startState)
        case .yaml: return YAMLHighlighter.endState(text, start: startState)
        case .plain: return .normal
        }
    }

    private func drawMatchHighlights(
        for visualLine: LineIndex.VisualLine,
        rowY: CGFloat,
        textOriginX: CGFloat
    ) {
        let rowStart = visualLine.byteRange.lowerBound
        let rowEnd = visualLine.byteRange.upperBound

        if let searchScan, rowEnd > rowStart {
            // A match may begin before this row yet extend into it — by at
            // most the longest match found, which for a literal query is the
            // query's own length.
            let lookback = max(1, searchScan.longestMatchLength)
            let searchFrom = max(0, rowStart - lookback + 1)
            let matches = searchScan.matches(beginningIn: searchFrom..<rowEnd)
            drawHighlightRects(
                matches,
                rowStart: rowStart,
                rowEnd: rowEnd,
                rowY: rowY,
                textOriginX: textOriginX
            )
        }
    }

    private func drawHighlightRects(
        _ matches: [Range<Int>],
        rowStart: Int,
        rowEnd: Int,
        rowY: CGFloat,
        textOriginX: CGFloat
    ) {
        let matchColor = NSColor.systemYellow.withAlphaComponent(0.5)
        let currentColor = NSColor.systemOrange.withAlphaComponent(0.85)
        var drawn = 0

        for match in matches {
            if drawn >= maxHighlightsPerRow {
                break
            }
            let matchOffset = match.lowerBound
            let visibleStart = max(match.lowerBound, rowStart)
            let visibleEnd = min(match.upperBound, rowEnd)
            if visibleStart < visibleEnd {
                let prefixWidth = textWidth(ofBytes: rowStart..<visibleStart)
                let matchWidth = textWidth(ofBytes: visibleStart..<visibleEnd)
                let rect = NSRect(
                    x: textOriginX - horizontalOffset + prefixWidth,
                    y: rowY,
                    width: matchWidth,
                    height: lineHeight
                )
                let isCurrent = matchOffset == currentMatchOffset
                (isCurrent ? currentColor : matchColor).setFill()
                rect.fill()
                drawn += 1
            }
        }
    }

    /// Draws the selection rectangle for the portion of `visualLine` covered
    /// by the current selection. Lines fully inside a multi-row selection fill
    /// to the viewport edge, matching standard macOS text-view behaviour.
    private func drawSelectionForRow(
        visualLine: LineIndex.VisualLine,
        rowY: CGFloat,
        textOriginX: CGFloat
    ) {
        guard let selection, !selection.isEmpty else {
            return
        }
        let selectedRange = selection.range
        let rowStart = visualLine.byteRange.lowerBound
        let rowEnd = visualLine.byteRange.upperBound
        guard selectedRange.upperBound > rowStart, selectedRange.lowerBound < rowEnd else {
            return
        }

        let leftX: CGFloat
        if selectedRange.lowerBound <= rowStart {
            leftX = 0
        } else {
            leftX = textWidth(ofBytes: rowStart..<selectedRange.lowerBound)
        }

        let rightX: CGFloat
        if selectedRange.upperBound >= rowEnd {
            // Selection continues onto the next row — fill to the viewport edge.
            rightX = max(0, bounds.width - textOriginX + horizontalOffset)
        } else {
            rightX = textWidth(ofBytes: rowStart..<selectedRange.upperBound)
        }

        let rect = NSRect(
            x: textOriginX - horizontalOffset + leftX,
            y: rowY,
            width: max(0, rightX - leftX),
            height: lineHeight
        )
        NSColor.selectedTextBackgroundColor.setFill()
        rect.fill()
    }

    /// Underlines the portion of `visualLine` covered by in-progress IME
    /// composition, matching the standard marked-text appearance.
    private func drawMarkedUnderline(
        for visualLine: LineIndex.VisualLine,
        rowY: CGFloat,
        textOriginX: CGFloat
    ) {
        guard let marked = markedByteRange else {
            return
        }
        let rowStart = visualLine.byteRange.lowerBound
        let rowEnd = visualLine.byteRange.upperBound
        let visibleStart = max(marked.lowerBound, rowStart)
        let visibleEnd = min(marked.upperBound, rowEnd)
        guard visibleStart < visibleEnd else {
            return
        }
        let leftX = textWidth(ofBytes: rowStart..<visibleStart)
        let width = textWidth(ofBytes: visibleStart..<visibleEnd)
        NSColor.textColor.setFill()
        NSRect(x: textOriginX - horizontalOffset + leftX,
               y: rowY + lineHeight - 2.5,
               width: width,
               height: 1.5).fill()
    }

    private func drawGutter(rows: [LineIndex.VisualLine], width: CGFloat, fraction: CGFloat) {
        let gutterRect = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        NSColor.windowBackgroundColor.setFill()
        gutterRect.fill()

        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: width - 0.5, y: 0))
        separator.line(to: NSPoint(x: width - 0.5, y: bounds.height))
        separator.stroke()

        let rightAligned = NSMutableParagraphStyle()
        rightAligned.alignment = .right
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: rightAligned
        ]
        let continuationAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: rightAligned
        ]

        for (row, visualLine) in rows.enumerated() {
            let y = CGFloat(row) * lineHeight - fraction * lineHeight
            let numberRect = NSRect(x: 0, y: y, width: width - gutterPadding, height: lineHeight)
            // Continuation chunks of a wrapped line show a marker, not a number.
            if visualLine.chunkIndex == 0 {
                let label = String(visualLine.documentLine + 1) as NSString
                label.draw(in: numberRect, withAttributes: numberAttributes)
            } else {
                ("⋯" as NSString).draw(in: numberRect, withAttributes: continuationAttributes)
            }
        }
    }

    private func drawPlaceholder() {
        let message = "Open a file with ⌘O" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let size = message.size(withAttributes: attributes)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        message.draw(at: origin, withAttributes: attributes)
    }
}
