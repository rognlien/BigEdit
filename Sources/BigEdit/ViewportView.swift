import AppKit

/// How much the mouse selects per click — driven by `NSEvent.clickCount`.
private enum SelectionGranularity {
    case character
    case word
    case line
}

/// Byte categories used by word-level selection to find a run of same-kind
/// bytes around a click point.
private enum ByteClass {
    case word
    case whitespace
    case other
}

/// The view that draws text. It only ever lays out and renders the visual rows
/// currently visible in the viewport, so its cost is independent of file size.
///
/// Scroll position is held as a fractional *visual-row* number (`scrollRow`),
/// which allows smooth, pixel-precise scrolling without ever building a view as
/// tall as the whole document — the trick that keeps many-GB files workable.
/// A visual row is either a whole short line or one chunk of a long line; see
/// `LineIndex.bytesPerChunk`.
final class ViewportView: NSView {

    private(set) var file: MappedFile?
    private(set) var index: LineIndex?

    /// The first visible visual row, as a fractional value (e.g. 1234.5).
    private(set) var scrollRow: Double = 0

    /// Horizontal scroll offset in points, for rows wider than the viewport.
    private var horizontalOffset: CGFloat = 0

    /// Invoked whenever the scroll position changes, so the scroller can sync.
    var onScrollChange: (() -> Void)?

    /// The active search, whose matches are highlighted as they are found.
    private var searchScan: SearchScan?

    /// The byte offset of the currently selected match, drawn emphasised.
    private var currentMatchOffset: Int?

    /// The deferred-edit model; when it holds a rule, rows render transformed.
    private var editModel: EditModel?

    /// The syntax-highlighting mode applied when drawing each row.
    private var syntaxMode: SyntaxMode = .plain

    /// The user's current selection, as byte offsets into the original file.
    private var selection: TextSelection?

    /// What kind of unit the active mouse interaction is selecting in.
    private var selectionGranularity: SelectionGranularity = .character

    /// The byte range that the *initial click* claimed (a single byte for a
    /// single click, a word for a double-click, a line for a triple-click).
    /// Drag operations extend from this anchor to the unit under the cursor.
    private var selectionAnchorUnit: Range<Int> = 0..<0

    /// Drives auto-scrolling while the user drags past the viewport edge.
    private var autoscrollTimer: Timer?

    /// Last drag event location, used by the auto-scroll tick.
    private var lastDragLocationInWindow: NSPoint?

    private var font: NSFont
    private var lineHeight: CGFloat
    private var characterWidth: CGFloat
    private var fontSize: CGFloat
    private let gutterPadding: CGFloat = 10

    static let defaultFontSize: CGFloat = 12
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 28

    /// Cap on highlight rectangles per row, so a saturated query stays cheap.
    private let maxHighlightsPerRow = 512

    override init(frame frameRect: NSRect) {
        let size = ViewportView.defaultFontSize
        let editorFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        self.fontSize = size
        self.font = editorFont
        self.lineHeight = ViewportView.lineHeight(for: editorFont)
        self.characterWidth = ViewportView.characterWidth(for: editorFont)
        super.init(frame: frameRect)
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 3
    }

    private static func characterWidth(for font: NSFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - Font size

    /// The current editor font size in points.
    var editorFontSize: CGFloat { fontSize }

    /// Sets the editor font size (clamped), re-wrapping long lines and keeping
    /// the scroll position valid for the new row height.
    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, ViewportView.minFontSize), ViewportView.maxFontSize)
        if clamped != fontSize {
            fontSize = clamped
            font = NSFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
            lineHeight = ViewportView.lineHeight(for: font)
            characterWidth = ViewportView.characterWidth(for: font)
            updateWrapBytes()
            setScrollRow(scrollRow)            // re-clamp: rowsPerPage changed
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            onScrollChange?()                  // knob proportion changed
        }
    }

    required init?(coder: NSCoder) {
        fatalError("ViewportView is created programmatically")
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Document

    /// Attaches a file and its (possibly still-building) line index.
    func load(file: MappedFile, index: LineIndex) {
        self.file = file
        self.index = index
        scrollRow = 0
        horizontalOffset = 0
        searchScan = nil
        currentMatchOffset = nil
        selection = nil
        updateWrapBytes()
        needsDisplay = true
    }

    /// Returns the wrap width (in bytes) implied by the current viewport size
    /// and the current line count's gutter requirement.
    private func currentWrapBytes() -> Int {
        guard let index, characterWidth > 0 else {
            return LineIndex.defaultWrapBytes
        }
        let gutterW = gutterWidth(for: index.count)
        let textAreaWidth = max(0, bounds.width - gutterW - gutterPadding)
        let columns = Int(textAreaWidth / characterWidth)
        return max(LineIndex.minimumWrapBytes, columns)
    }

    /// Pushes the current wrap width down into `LineIndex` so long lines
    /// re-wrap on resize. Cheap when there are no long lines.
    private func updateWrapBytes() {
        index?.setWrapBytes(currentWrapBytes())
    }

    deinit {
        autoscrollTimer?.invalidate()
    }

    // MARK: - Geometry

    /// The number of whole visual rows that fit in the viewport.
    var rowsPerPage: Int {
        max(1, Int(bounds.height / lineHeight))
    }

    /// The largest valid `scrollRow`, leaving the last page in view.
    var maxScrollRow: Double {
        var result = 0.0
        if let index {
            result = max(0, Double(index.visualRowCount) - Double(rowsPerPage))
        }
        return result
    }

    // MARK: - Scrolling

    /// Sets the scroll position, clamped to the valid range.
    func setScrollRow(_ value: Double) {
        let clamped = min(max(0, value), maxScrollRow)
        if clamped != scrollRow {
            scrollRow = clamped
            needsDisplay = true
            onScrollChange?()
        }
    }

    func scrollByRows(_ delta: Double) {
        setScrollRow(scrollRow + delta)
    }

    func scrollByPages(_ delta: Int) {
        let step = Double(delta) * Double(max(1, rowsPerPage - 1))
        setScrollRow(scrollRow + step)
    }

    /// Scrolls `row` into view if it is not already visible, leaving it about a
    /// third of the way down the viewport.
    func scrollToRow(_ row: Int) {
        let target = Double(row)
        let firstVisible = scrollRow
        let lastVisible = scrollRow + Double(rowsPerPage) - 1
        if target < firstVisible || target > lastVisible {
            setScrollRow(target - Double(rowsPerPage) / 3)
        }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let multiplier: Double = event.hasPreciseScrollingDeltas ? 1 : 3
        let rowDelta = Double(event.scrollingDeltaY) / Double(lineHeight)
        setScrollRow(scrollRow - rowDelta * multiplier)

        horizontalOffset = max(0, horizontalOffset - event.scrollingDeltaX)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 126: command ? setScrollRow(0) : scrollByRows(-1)             // (⌘)up
        case 125: command ? setScrollRow(maxScrollRow) : scrollByRows(1)   // (⌘)down
        case 116: scrollByPages(-1)                        // page up
        case 121: scrollByPages(1)                         // page down
        case 115: setScrollRow(0)                          // home
        case 119: setScrollRow(maxScrollRow)               // end
        case 123: shiftHorizontally(by: -characterWidth * 8)  // left arrow
        case 124: shiftHorizontally(by: characterWidth * 8)   // right arrow
        default: super.keyDown(with: event)
        }
    }

    private func shiftHorizontally(by delta: CGFloat) {
        horizontalOffset = max(0, horizontalOffset + delta)
        needsDisplay = true
    }

    // MARK: - Selection

    override func resetCursorRects() {
        // I-beam over the text area only; the gutter keeps the default arrow.
        let gutterW = index.map { gutterWidth(for: $0.count) } ?? 0
        let textRect = NSRect(x: gutterW, y: 0,
                              width: max(0, bounds.width - gutterW), height: bounds.height)
        addCursorRect(textRect, cursor: .iBeam)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click context menu — just Copy. Select All is deliberately
        // omitted because selecting and copying many GB would try to build a
        // huge string on the pasteboard.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: ""
        ))
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let offset = byteOffset(at: point)
        selectionGranularity = granularity(forClickCount: event.clickCount)
        selectionAnchorUnit = unit(at: offset, granularity: selectionGranularity)
        selection = TextSelection(
            anchorOffset: selectionAnchorUnit.lowerBound,
            activeOffset: selectionAnchorUnit.upperBound
        )
        lastDragLocationInWindow = event.locationInWindow
        startAutoscrollTimer()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        lastDragLocationInWindow = event.locationInWindow
        updateSelectionForDrag()
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscrollTimer()
        lastDragLocationInWindow = nil
    }

    /// Extends the selection to span from the anchor unit (set on mouseDown)
    /// to the unit currently under the cursor. The unit type — character,
    /// word, or line — is fixed for the duration of the drag, so a
    /// double-click + drag widens word-by-word.
    private func updateSelectionForDrag() {
        guard let location = lastDragLocationInWindow else { return }
        let raw = convert(location, from: nil)
        let clamped = NSPoint(
            x: raw.x,
            y: min(max(0, raw.y), max(0, bounds.height - 1))
        )
        let offset = byteOffset(at: clamped)
        let currentUnit = unit(at: offset, granularity: selectionGranularity)
        let lower = min(selectionAnchorUnit.lowerBound, currentUnit.lowerBound)
        let upper = max(selectionAnchorUnit.upperBound, currentUnit.upperBound)
        selection = TextSelection(anchorOffset: lower, activeOffset: upper)
        needsDisplay = true
    }

    /// The selection unit a click of `clickCount` clicks selects.
    private func granularity(forClickCount clickCount: Int) -> SelectionGranularity {
        switch clickCount {
        case 2: return .word
        case 3: return .line
        default: return .character
        }
    }

    /// The byte range a `granularity` unit covers at `byteOffset`.
    private func unit(at byteOffset: Int, granularity: SelectionGranularity) -> Range<Int> {
        switch granularity {
        case .character:
            return byteOffset..<byteOffset
        case .word:
            if let file {
                return wordRange(at: byteOffset, in: file)
            }
            return byteOffset..<byteOffset
        case .line:
            return lineRange(at: byteOffset)
        }
    }

    /// The byte range of the word-like token at `byteOffset`. Three classes —
    /// word, whitespace, other — and the run of the same class is selected.
    /// Newlines always break a run, so the selection never crosses lines.
    private func wordRange(at byteOffset: Int, in file: MappedFile) -> Range<Int> {
        let buffer = file.buffer
        let total = buffer.count
        if byteOffset < 0 || byteOffset >= total {
            return byteOffset..<byteOffset
        }
        let cap = 10_000
        let clickedClass = byteClass(of: buffer[byteOffset])
        var start = byteOffset
        var end = byteOffset + 1
        while start > 0 && byteOffset - start < cap {
            let candidate = buffer[start - 1]
            if candidate == 0x0A || byteClass(of: candidate) != clickedClass {
                break
            }
            start -= 1
        }
        while end < total && end - byteOffset < cap {
            let candidate = buffer[end]
            if candidate == 0x0A || byteClass(of: candidate) != clickedClass {
                break
            }
            end += 1
        }
        return start..<end
    }

    /// The byte range of the visual line containing `byteOffset`, including
    /// its trailing newline if this row is the last chunk of its line.
    private func lineRange(at byteOffset: Int) -> Range<Int> {
        guard let file, let index else {
            return byteOffset..<byteOffset
        }
        let buffer = file.buffer
        let row = index.visualRow(forByteOffset: byteOffset, file: file)
        let rows = index.visualLines(forRows: row..<(row + 1), file: file)
        guard let visualLine = rows.first else {
            return byteOffset..<byteOffset
        }
        var upper = visualLine.byteRange.upperBound
        let isLastChunk = visualLine.chunkIndex == visualLine.chunkCount - 1
        if isLastChunk && upper < buffer.count && buffer[upper] == 0x0A {
            upper += 1
        }
        return visualLine.byteRange.lowerBound..<upper
    }

    /// Categorises a byte for word-break purposes: ASCII alphanumerics +
    /// underscore are "word", common ASCII whitespace is "whitespace", and
    /// anything else (punctuation, non-ASCII) is "other". `\n` is handled
    /// explicitly at the call site so a run never crosses a newline.
    private func byteClass(of byte: UInt8) -> ByteClass {
        if (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F {
            return .word
        }
        if byte == 0x20 || byte == 0x09 || byte == 0x0D {
            return .whitespace
        }
        return .other
    }

    private func startAutoscrollTimer() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.autoscrollTick()
        }
    }

    private func stopAutoscrollTimer() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    /// One auto-scroll step: if the held drag point is above or below the
    /// viewport, scroll in that direction and extend the selection.
    private func autoscrollTick() {
        guard let location = lastDragLocationInWindow else { return }
        let point = convert(location, from: nil)

        var rowDelta = 0.0
        if point.y < 0 {
            rowDelta = -min(5, -Double(point.y) / 8)
        } else if point.y > bounds.height {
            rowDelta = min(5, Double(point.y - bounds.height) / 8)
        }
        if rowDelta != 0 {
            setScrollRow(scrollRow + rowDelta)
            updateSelectionForDrag()
        }
    }

    /// Translates a point in viewport coordinates to a byte offset in the file.
    /// Hit testing assumes a monospaced font and ASCII content; non-ASCII text
    /// may select a few bytes off, and with an active replacement rule the
    /// mapping near a replacement is approximate.
    private func byteOffset(at point: NSPoint) -> Int {
        var result = 0
        if let file, let index, index.visualRowCount > 0 {
            let firstRow = Int(scrollRow)
            let fraction = scrollRow - Double(firstRow)
            let rowsFromTop = (Double(point.y) + fraction * Double(lineHeight)) / Double(lineHeight)
            var rowIndex = firstRow + Int(rowsFromTop.rounded(.down))
            rowIndex = max(0, min(rowIndex, index.visualRowCount - 1))

            let rows = index.visualLines(forRows: rowIndex..<(rowIndex + 1), file: file)
            if let visualLine = rows.first {
                let gutterW = gutterWidth(for: index.count)
                let textOriginX = gutterW + gutterPadding
                let relativeX = point.x - textOriginX + horizontalOffset
                let approxChars = Int((max(0, relativeX) / characterWidth).rounded())
                let rs = visualLine.byteRange.lowerBound
                let re = visualLine.byteRange.upperBound
                result = max(rs, min(rs + approxChars, re))
            } else {
                result = file.size
            }
        }
        return result
    }

    // MARK: - Copy / Select All

    @objc func copy(_ sender: Any?) {
        let cap = 64 * 1024 * 1024
        if let selection, !selection.isEmpty, let file, let editModel {
            let range = selection.range
            if range.count > cap {
                presentSelectionTooLarge()
            } else {
                let bytes = editModel.transformedBytes(forOriginalRange: range, in: file.buffer)
                let text = ViewportView.pasteboardText(fromUTF8: bytes)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        } else {
            NSSound.beep()
        }
    }

    /// Decodes copied bytes to a string and drops the control characters the
    /// viewport doesn't render — keeping only tab and newline. The viewport
    /// shows printable text (it hides the CR of CRLF lines and control bytes
    /// like Record Separator, U+001E), so copying the raw bytes would otherwise
    /// paste stray characters that look inserted. Dropping CR everywhere also
    /// turns CRLF into LF, matching the displayed lines.
    static func pasteboardText(fromUTF8 bytes: [UInt8]) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if text.unicodeScalars.contains(where: ViewportView.isHiddenControl) {
            text.unicodeScalars.removeAll(where: ViewportView.isHiddenControl)
        }
        return text
    }

    /// A C0 control character (or DEL) that the viewport doesn't render, other
    /// than tab and newline which it lays out normally.
    private static func isHiddenControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:           // tab, newline — keep
            return false
        case 0x00...0x1F, 0x7F:    // other C0 controls and DEL — drop
            return true
        default:
            return false
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        if let file {
            selection = TextSelection(anchorOffset: 0, activeOffset: file.size)
            needsDisplay = true
        }
    }

    private func presentSelectionTooLarge() {
        let alert = NSAlert()
        alert.messageText = "Selection Too Large"
        alert.informativeText = "BigEdit caps a single copy at 64 MB. Make a smaller selection."
        alert.alertStyle = .warning
        alert.runModal()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateWrapBytes()        // Long lines re-wrap to the new width.
        setScrollRow(scrollRow)  // Re-clamp: the visible page changed.
        needsDisplay = true
    }

    // MARK: - Search

    /// Attaches (or clears) the search whose matches should be highlighted.
    func setSearch(scan: SearchScan?, currentMatchOffset: Int?) {
        self.searchScan = scan
        self.currentMatchOffset = currentMatchOffset
        needsDisplay = true
    }

    /// Attaches the deferred-edit model whose rule the viewport renders.
    func setEditModel(_ model: EditModel?) {
        self.editModel = model
        needsDisplay = true
    }

    /// Sets the syntax-highlighting mode for the current document.
    func setSyntaxMode(_ mode: SyntaxMode) {
        self.syntaxMode = mode
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        if let file, let index, index.visualRowCount > 0 {
            drawContent(file: file, index: index)
        } else {
            drawPlaceholder()
        }
    }

    private func drawContent(file: MappedFile, index: LineIndex) {
        let totalRows = index.visualRowCount
        let firstRow = Int(scrollRow)
        let fraction = CGFloat(scrollRow - Double(firstRow))
        let lastRow = min(totalRows, firstRow + rowsPerPage + 2)
        let rows = index.visualLines(forRows: firstRow..<lastRow, file: file)

        let gutterWidth = self.gutterWidth(for: index.count)
        drawText(rows: rows, file: file, gutterWidth: gutterWidth, fraction: fraction)
        drawGutter(rows: rows, width: gutterWidth, fraction: fraction)
    }

    private func drawText(
        rows: [LineIndex.VisualLine],
        file: MappedFile,
        gutterWidth: CGFloat,
        fraction: CGFloat
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

        let buffer = file.buffer
        for (row, visualLine) in rows.enumerated() {
            let y = CGFloat(row) * lineHeight - fraction * lineHeight
            // Search highlights, then selection, then text — each layer above
            // the previous so the rendered text is always on top.
            drawMatchHighlights(for: visualLine, rowY: y, textOriginX: textOriginX, buffer: buffer)
            drawSelectionForRow(visualLine: visualLine, rowY: y, textOriginX: textOriginX, buffer: buffer)
            let text = decodeChunk(visualLine, buffer: buffer)
            attributedRow(text).draw(at: NSPoint(x: textOriginX - horizontalOffset, y: y))
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func drawMatchHighlights(
        for visualLine: LineIndex.VisualLine,
        rowY: CGFloat,
        textOriginX: CGFloat,
        buffer: UnsafeRawBufferPointer
    ) {
        let rowStart = visualLine.byteRange.lowerBound
        let rowEnd = visualLine.byteRange.upperBound

        if let searchScan, rowEnd > rowStart {
            let needleLength = searchScan.queryByteLength
            // A match may begin just before this row yet extend into it.
            let searchFrom = max(0, rowStart - needleLength + 1)
            let offsets = searchScan.matchOffsets(beginningIn: searchFrom..<rowEnd)
            drawHighlightRects(
                offsets,
                needleLength: needleLength,
                rowStart: rowStart,
                rowEnd: rowEnd,
                rowY: rowY,
                textOriginX: textOriginX,
                buffer: buffer
            )
        }
    }

    private func drawHighlightRects(
        _ offsets: [Int],
        needleLength: Int,
        rowStart: Int,
        rowEnd: Int,
        rowY: CGFloat,
        textOriginX: CGFloat,
        buffer: UnsafeRawBufferPointer
    ) {
        let matchColor = NSColor.systemYellow.withAlphaComponent(0.5)
        let currentColor = NSColor.systemOrange.withAlphaComponent(0.85)
        var drawn = 0

        for matchOffset in offsets {
            if drawn >= maxHighlightsPerRow {
                break
            }
            let visibleStart = max(matchOffset, rowStart)
            let visibleEnd = min(matchOffset + needleLength, rowEnd)
            if visibleStart < visibleEnd {
                let prefixWidth = textWidth(ofBytes: rowStart..<visibleStart, in: buffer)
                let matchWidth = textWidth(ofBytes: visibleStart..<visibleEnd, in: buffer)
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
        textOriginX: CGFloat,
        buffer: UnsafeRawBufferPointer
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
            leftX = textWidth(ofBytes: rowStart..<selectedRange.lowerBound, in: buffer)
        }

        let rightX: CGFloat
        if selectedRange.upperBound >= rowEnd {
            // Selection continues onto the next row — fill to the viewport edge.
            rightX = max(0, bounds.width - textOriginX + horizontalOffset)
        } else {
            rightX = textWidth(ofBytes: rowStart..<selectedRange.upperBound, in: buffer)
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

    // MARK: - Helpers

    /// Builds the drawable, coloured form of a row's text for the current
    /// syntax mode.
    private func attributedRow(_ text: String) -> NSAttributedString {
        switch syntaxMode {
        case .xml:
            return XMLHighlighter.attributedRow(text, font: font)
        case .json:
            return JSONHighlighter.attributedRow(text, font: font)
        case .markdown:
            return MarkdownHighlighter.attributedRow(text, font: font)
        case .yaml:
            return YAMLHighlighter.attributedRow(text, font: font)
        case .plain:
            return NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: NSColor.textColor]
            )
        }
    }

    /// Decodes one chunk's bytes to a `String`. A chunk is at most
    /// `LineIndex.bytesPerChunk` bytes, so this is always cheap — even when the
    /// chunk belongs to a multi-gigabyte minified line.
    private func decodeChunk(
        _ visualLine: LineIndex.VisualLine,
        buffer: UnsafeRawBufferPointer
    ) -> String {
        var range = visualLine.byteRange

        // A continuation chunk may begin in the middle of a UTF-8 sequence;
        // drop any leading continuation bytes so decoding starts cleanly.
        if visualLine.chunkIndex > 0 {
            var start = range.lowerBound
            var skipped = 0
            while start < range.upperBound && skipped < 3 && (buffer[start] & 0xC0) == 0x80 {
                start += 1
                skipped += 1
            }
            range = start..<range.upperBound
        }

        var text = ""
        if !range.isEmpty {
            if let editModel, editModel.rule != nil {
                // Show the edited result of the active replacement rule.
                let edited = editModel.transformedBytes(forOriginalRange: range, in: buffer)
                text = String(decoding: edited, as: UTF8.self)
            } else {
                let bytes = UnsafeRawBufferPointer(rebasing: buffer[range])
                text = String(decoding: bytes, as: UTF8.self)
            }
        }

        // Strip the CR of a CRLF ending, but only on the line's final chunk.
        let isLastChunk = visualLine.chunkIndex == visualLine.chunkCount - 1
        if isLastChunk && text.hasSuffix("\r") {
            text.removeLast()
        }
        return text
    }

    /// The drawn width of a byte range, measured with the editor font so it
    /// lines up with the rendered text (handles tabs and non-ASCII correctly).
    private func textWidth(ofBytes range: Range<Int>, in buffer: UnsafeRawBufferPointer) -> CGFloat {
        var width: CGFloat = 0
        if !range.isEmpty {
            let bytes = UnsafeRawBufferPointer(rebasing: buffer[range])
            let text = String(decoding: bytes, as: UTF8.self) as NSString
            width = text.size(withAttributes: [.font: font]).width
        }
        return width
    }

    /// The gutter width needed to show line numbers for `totalLines`.
    private func gutterWidth(for totalLines: Int) -> CGFloat {
        let digits = String(max(1, totalLines)).count
        return CGFloat(digits) * characterWidth + gutterPadding * 2
    }
}

extension ViewportView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        var enabled = true
        switch menuItem.action {
        case #selector(copy(_:)):
            enabled = !(selection?.isEmpty ?? true)
        case #selector(selectAll(_:)):
            enabled = file != nil
        default:
            enabled = true
        }
        return enabled
    }
}
