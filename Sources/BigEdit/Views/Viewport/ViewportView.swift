import AppKit
import CoreText

/// The view that draws text. It only ever lays out and renders the visual rows
/// currently visible in the viewport, so its cost is independent of file size.
///
/// Scroll position is held as a fractional *visual-row* number (`scrollRow`),
/// which allows smooth, pixel-precise scrolling without ever building a view as
/// tall as the whole document — the trick that keeps many-GB files workable.
/// A visual row is either a whole short line or one chunk of a long line; see
/// `LineIndex.bytesPerChunk`.
final class ViewportView: NSView {

    private(set) var document: EditedDocument?

    /// The mapped file behind the document — for components that speak
    /// original byte offsets (search, statistics, format detection).
    var file: MappedFile? { document?.file }

    /// The line/row layout of the logical document.
    var layout: EditedLayout? { document?.layout }

    /// The first visible visual row, as a fractional value (e.g. 1234.5).
    private(set) var scrollRow: Double = 0

    /// Horizontal scroll offset in points, for rows wider than the viewport.
    var horizontalOffset: CGFloat = 0

    /// The widest row drawn so far, which is what bounds horizontal scrolling.
    ///
    /// Measured from rows as they are drawn — the same bargain the rest of the
    /// viewport makes, so no width is ever computed for a part of the file we
    /// are not looking at — and kept as a high-water mark rather than the
    /// current screen's widest. If it shrank as you scrolled, moving down into
    /// shorter lines would drag the view sideways; growing only means a narrow
    /// document never scrolls sideways at all, while a file with one long line
    /// stays scrollable after you leave it. Reset whenever the drawn width of
    /// the whole document changes: a new file, a new font size, a new wrap
    /// width, or entering and leaving CSV columns.
    var widestDrawnRowWidth: CGFloat = 0

    /// Invoked whenever the scroll position changes, so the scroller can sync.
    var onScrollChange: (() -> Void)?

    /// The active search, whose matches are highlighted as they are found.
    var searchScan: SearchScan?

    /// The byte offset of the currently selected match, drawn emphasised.
    var currentMatchOffset: Int?

    /// The syntax-highlighting mode applied when drawing each row.
    var syntaxMode: SyntaxMode = .plain

    /// Maps the highlighters' tokens to colours and fonts.
    let theme = HighlightTheme.standard

    /// How the document's bytes are decoded for drawing, measuring, copying
    /// and mapping a click back to a byte. Set from the detected file format.
    var textEncoding: TextEncoding = .utf8

    /// Asks the container to sort the table by a column: `descending` is nil
    /// for a header click, which toggles the direction on the sorted column.
    var onCSVSortRequest: ((_ column: Int, _ descending: Bool?) -> Void)?

    /// The column the table was last sorted by, drawn as an arrow in its
    /// header until the mode or document changes.
    private(set) var csvSortIndicator: (column: Int, descending: Bool)?

    /// Set while the document is drawn as aligned CSV columns. The padding this
    /// inserts means the drawn text no longer matches the file's bytes, so the
    /// mode is display-only: editing is off and hit-testing falls back to a
    /// column estimate, exactly as under a deferred replacement rule.
    var csvDialect: CSVDialect?
    var csvColumnLayout: CSVColumnLayout?

    /// The widths as measured from the file, kept beside the working layout so
    /// a column dragged to some other width can be sent back to the width its
    /// own content asks for.
    private var csvMeasuredColumnLayout: CSVColumnLayout?

    /// The column being resized by a drag on its divider, with where the drag
    /// started so the new width is measured from the original rather than
    /// accumulating rounding error tick by tick.
    var columnDrag: (column: Int, startX: CGFloat, startWidth: Int)?

    /// The user's current selection, as byte offsets into the original file.
    /// Its `activeOffset` doubles as the keyboard caret (the end being moved).
    var selection: TextSelection? {
        didSet {
            onSelectionChange?()
            caretVisible = true       // show solid right after a move
            updateCaretBlink()
        }
    }

    /// Invoked whenever the selection or caret changes, so the status bar syncs.
    var onSelectionChange: (() -> Void)?

    /// The caret (selection's active end) as a byte offset, if any.
    var caretByteOffset: Int? { selection?.activeOffset }

    /// The selected byte range, or nil when the selection is empty.
    var selectionByteRange: Range<Int>? {
        guard let selection, !selection.isEmpty else { return nil }
        return selection.range
    }

    /// Target x for vertical caret moves, so up/down keep a column. Reset on a
    /// horizontal move or a click.
    var desiredCaretX: CGFloat?

    /// The logical byte range of in-progress IME composition (marked text).
    /// The bytes are committed to the document as they change — this range
    /// only tracks where the composition underline is drawn and what the next
    /// `setMarkedText` replaces.
    var markedByteRange: Range<Int>?

    /// Insertion-caret blink state (only shown when focused with an empty
    /// selection).
    var isViewportFocused = false
    var caretVisible = true
    private var caretBlinkTimer: Timer?

    /// What kind of unit the active mouse interaction is selecting in.
    var selectionGranularity: SelectionGranularity = .character

    /// The byte range that the *initial click* claimed (a single byte for a
    /// single click, a word for a double-click, a line for a triple-click).
    /// Drag operations extend from this anchor to the unit under the cursor.
    var selectionAnchorUnit: Range<Int> = 0..<0

    /// Drives auto-scrolling while the user drags past the viewport edge.
    var autoscrollTimer: Timer?

    /// Last drag event location, used by the auto-scroll tick.
    var lastDragLocationInWindow: NSPoint?

    var font: NSFont
    var lineHeight: CGFloat
    var characterWidth: CGFloat
    var fontSize: CGFloat
    let gutterPadding: CGFloat = 10

    static let defaultFontSize: CGFloat = 12
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 28

    /// Cap on highlight rectangles per row, so a saturated query stays cheap.
    let maxHighlightsPerRow = 512

    override init(frame frameRect: NSRect) {
        let size = ViewportView.defaultFontSize
        let editorFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        self.fontSize = size
        self.font = editorFont
        self.lineHeight = ViewportView.lineHeight(for: editorFont)
        self.characterWidth = ViewportView.characterWidth(for: editorFont)
        super.init(frame: frameRect)
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 3
    }

    static func characterWidth(for font: NSFont) -> CGFloat {
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
            widestDrawnRowWidth = 0
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

    override func becomeFirstResponder() -> Bool {
        isViewportFocused = true
        updateCaretBlink()
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        isViewportFocused = false
        updateCaretBlink()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            isViewportFocused = false
            updateCaretBlink()
        }
    }

    /// Runs the caret blink only while focused with an empty selection.
    private func updateCaretBlink() {
        let shouldBlink = isViewportFocused && selection != nil && selectionByteRange == nil
        if shouldBlink {
            if caretBlinkTimer == nil {
                caretVisible = true
                caretBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.caretVisible.toggle()
                    self?.needsDisplay = true
                }
            }
        } else {
            caretBlinkTimer?.invalidate()
            caretBlinkTimer = nil
            caretVisible = true
        }
    }

    // MARK: - Document

    /// Attaches a document (whose line index may still be building).
    /// Swaps in a document over a grown mapping of the same file, keeping the
    /// scroll position and selection: every offset that was valid still is.
    func replaceDocumentKeepingPosition(_ document: EditedDocument) {
        self.document = document
        updateWrapBytes()
        setScrollRow(scrollRow)          // re-clamp against the new row count
        needsDisplay = true
    }

    /// Whether the last row is in view — what following a growing file uses
    /// to decide whether to stay pinned to the end.
    var isScrolledToEnd: Bool {
        scrollRow >= maxScrollRow - 0.5
    }

    func load(document: EditedDocument) {
        self.document = document
        scrollRow = 0
        horizontalOffset = 0
        widestDrawnRowWidth = 0
        searchScan = nil
        currentMatchOffset = nil
        selection = nil
        updateWrapBytes()
        needsDisplay = true
    }

    /// Returns the wrap width (in bytes) implied by the current viewport size
    /// and the current line count's gutter requirement.
    private func currentWrapBytes() -> Int {
        guard let layout, characterWidth > 0 else {
            return LineIndex.defaultWrapBytes
        }
        let gutterW = gutterWidth(for: layout.gutterLineCount)
        let textAreaWidth = max(0, bounds.width - gutterW - gutterPadding)
        let columns = Int(textAreaWidth / characterWidth)
        return max(LineIndex.minimumWrapBytes, columns)
    }

    /// Pushes the current wrap width down into the layout so long lines
    /// re-wrap on resize. Cheap when there are no long lines.
    private func updateWrapBytes() {
        layout?.setWrapBytes(currentWrapBytes())
        widestDrawnRowWidth = 0      // rows re-wrap, so their widths change
    }

    deinit {
        autoscrollTimer?.invalidate()
    }

    // MARK: - Geometry

    /// The number of whole visual rows that fit in the viewport, excluding any
    /// strip held by the pinned CSV header.
    var rowsPerPage: Int {
        max(1, Int((bounds.height - pinnedHeaderHeight) / lineHeight))
    }

    /// Column dividers move with the horizontal scroll, so their cursor rects
    /// have to be rebuilt whenever it changes.
    func refreshCSVDividerCursors() {
        if isCSVRenderingActive {
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Returns `column` to the width measured from the file — what a
    /// double-click on its divider means.
    func sizeCSVColumnToContent(_ column: Int) {
        if let measured = csvMeasuredColumnLayout,
           column < measured.columnWidths.count {
            csvColumnLayout = csvColumnLayout?.settingWidth(measured.columnWidths[column],
                                                            forColumn: column)
            widestDrawnRowWidth = 0      // the table's width just changed
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    /// The band along the top of the viewport where column dividers are drawn
    /// and grabbed — the pinned header when there is one, and otherwise the
    /// topmost row, so the ruler is always in the same place.
    var csvDividerBand: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: lineHeight)
    }

    /// The on-screen x of each column's trailing divider.
    func csvDividerPositions() -> [CGFloat] {
        var positions: [CGFloat] = []
        if let csvColumnLayout, let layout {
            let textOriginX = gutterWidth(for: layout.gutterLineCount) + gutterPadding
            positions = csvColumnLayout.dividerCharacterOffsets.map {
                textOriginX - horizontalOffset + CGFloat($0) * characterWidth
            }
        }
        return positions
    }

    /// The column whose divider sits under `point`, or `nil` if none does.
    func csvDividerColumn(at point: NSPoint) -> Int? {
        var result: Int?
        if isCSVRenderingActive && csvDividerBand.contains(point) {
            let tolerance: CGFloat = 3
            for (column, x) in csvDividerPositions().enumerated()
            where abs(point.x - x) <= tolerance {
                result = column
                break
            }
        }
        return result
    }

    /// The column under `x`, by the dividers that end each column.
    func csvColumn(atX x: CGFloat) -> Int? {
        csvDividerPositions().firstIndex { x < $0 }
    }

    /// The header column under `point` — on the pinned header, or on the
    /// header row itself while it is scrolled into view — or nil.
    func csvHeaderColumn(at point: NSPoint) -> Int? {
        var column: Int?
        if isCSVRenderingActive, csvDialect?.hasHeaderRow == true, let layout {
            let isOnHeader: Bool
            if isPinnedHeaderVisible {
                isOnHeader = point.y < lineHeight
            } else {
                isOnHeader = layout.visualLines(forRows: rowAt(y: point.y)..<(rowAt(y: point.y) + 1))
                    .first?.documentLine == 0
            }
            if isOnHeader, point.x >= gutterWidth(for: layout.gutterLineCount) {
                column = csvColumn(atX: point.x)
            }
        }
        return column
    }

    /// The visual row drawn at `y`: row `r` sits at
    /// `pinnedHeaderHeight + (r - scrollRow) * lineHeight`.
    private func rowAt(y: CGFloat) -> Int {
        let fraction = CGFloat(scrollRow - Double(Int(scrollRow)))
        return Int(scrollRow) + Int(((y - pinnedHeaderHeight) / lineHeight + fraction).rounded(.down))
    }

    /// The header row's text for `column`, or a positional name without one.
    func csvColumnTitle(_ column: Int) -> String {
        var title = "Column \(column + 1)"
        if csvDialect?.hasHeaderRow == true, let csvDialect, let layout,
           let headerLine = layout.visualLines(forRows: 0..<1).first {
            let fields = CSVParser.fields(in: decodeChunk(headerLine), dialect: csvDialect)
            if column < fields.count, !fields[column].isEmpty {
                title = fields[column]
            }
        }
        return title
    }

    /// True when a CSV header row is being held at the top of the viewport.
    ///
    /// Only once scrolled past it: at the very top the header is simply the
    /// first row, and pinning it there would draw it twice.
    var isPinnedHeaderVisible: Bool {
        isCSVRenderingActive && csvDialect?.hasHeaderRow == true
            && csvDialect?.pinsHeaderRow == true && scrollRow >= 1
    }

    /// Space reserved at the top for the pinned header, so it covers no data.
    var pinnedHeaderHeight: CGFloat {
        isPinnedHeaderVisible ? lineHeight : 0
    }

    /// The largest valid `scrollRow`, leaving the last page in view.
    var maxScrollRow: Double {
        var result = 0.0
        if let layout {
            result = max(0, Double(layout.visualRowCount) - Double(rowsPerPage))
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

        setHorizontalOffset(horizontalOffset - event.scrollingDeltaX)
        refreshCSVDividerCursors()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // Mid-composition every key belongs to the input method.
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        // Once a caret/selection exists, the arrows navigate text (extending
        // with Shift); before that they scroll, so plain browsing still works.
        let hasCaret = selection != nil
        switch event.keyCode {
        case 126:                                          // up
            if command { setScrollRow(0) }
            else if shift || hasCaret { moveCaretVertically(by: -1, extend: shift) }
            else { scrollByRows(-1) }
        case 125:                                          // down
            if command { setScrollRow(maxScrollRow) }
            else if shift || hasCaret { moveCaretVertically(by: 1, extend: shift) }
            else { scrollByRows(1) }
        case 123:                                          // left
            if shift || hasCaret { moveCaretHorizontally(forward: false, extend: shift) }
            else { shiftHorizontally(by: -characterWidth * 8) }
        case 124:                                          // right
            if shift || hasCaret { moveCaretHorizontally(forward: true, extend: shift) }
            else { shiftHorizontally(by: characterWidth * 8) }
        case 116: scrollByPages(-1)                        // page up
        case 121: scrollByPages(1)                         // page down
        case 115: setScrollRow(0)                          // home
        case 119: setScrollRow(maxScrollRow)               // end
        default:
            if isEditingAllowed {
                // Routes through the input context: typing arrives via
                // insertText, editing keys via the NSResponder actions below.
                interpretKeyEvents([event])
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: - Editing hooks

    /// Invoked after every successful edit so the container can update dirty
    /// state, the scroller, and content-dependent scans.
    var onEdit: (() -> Void)?

    // MARK: - Configuration

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateWrapBytes()        // Long lines re-wrap to the new width.
        setScrollRow(scrollRow)  // Re-clamp: the visible page changed.
        needsDisplay = true
    }

    /// Attaches (or clears) the search whose matches should be highlighted.
    func setSearch(scan: SearchScan?, currentMatchOffset: Int?) {
        self.searchScan = scan
        self.currentMatchOffset = currentMatchOffset
        needsDisplay = true
    }

    /// Sets the encoding rows are decoded with.
    func setTextEncoding(_ encoding: TextEncoding) {
        if encoding != textEncoding {
            textEncoding = encoding
            needsDisplay = true
        }
    }

    /// Sets the syntax-highlighting mode for the current document.
    func setSyntaxMode(_ mode: SyntaxMode) {
        self.syntaxMode = mode
        needsDisplay = true
    }

    /// True while rows are drawn as aligned CSV columns.
    var isCSVRenderingActive: Bool {
        csvDialect != nil && csvColumnLayout != nil
    }

    /// Turns aligned-column rendering on with a measured layout, or off when
    /// either argument is `nil`.
    func setCSVRendering(dialect: CSVDialect?, columnLayout: CSVColumnLayout?) {
        csvDialect = dialect
        csvColumnLayout = columnLayout
        csvMeasuredColumnLayout = columnLayout
        csvSortIndicator = nil
        widestDrawnRowWidth = 0
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Marks `column` as the one the table is sorted by.
    func setCSVSortIndicator(column: Int, descending: Bool) {
        csvSortIndicator = (column, descending)
        needsDisplay = true
    }

    // MARK: - Helpers

    /// Builds the drawable, coloured form of a single row's text from a normal
    /// start state — used for hit-testing where carried state doesn't matter.
    func attributedRow(_ text: String) -> NSAttributedString {
        return highlightedRow(text, startState: .normal).0
    }

    /// Decodes one chunk's bytes to a `String`. A chunk is at most
    /// `LineIndex.bytesPerChunk` bytes, so this is always cheap — even when the
    /// chunk belongs to a multi-gigabyte minified line.
    func decodeChunk(_ visualLine: LineIndex.VisualLine) -> String {
        var text = ""
        if let document {
            // A continuation chunk may begin in the middle of a UTF-8 sequence;
            // drop any leading continuation bytes so decoding starts cleanly.
            let range = chunkStartByte(visualLine)..<visualLine.byteRange.upperBound
            if !range.isEmpty {
                text = textEncoding.decode(document.displayBytes(in: range))
            }

            // Strip the CR of a CRLF ending, but only on the line's final chunk.
            let isLastChunk = visualLine.chunkIndex == visualLine.chunkCount - 1
            if isLastChunk && text.hasSuffix("\r") {
                text.removeLast()
            }
        }
        return text
    }

    /// The drawn width of a byte range, measured with the editor font so it
    /// lines up with the rendered text (handles tabs and non-ASCII correctly).
    func textWidth(ofBytes range: Range<Int>) -> CGFloat {
        var width: CGFloat = 0
        if let document, !range.isEmpty {
            let text = textEncoding.decode(document.bytes(in: range)) as NSString
            width = text.size(withAttributes: [.font: font]).width
        }
        return width
    }

    /// The gutter width needed to show line numbers for `totalLines`.
    func gutterWidth(for totalLines: Int) -> CGFloat {
        let digits = String(max(1, totalLines)).count
        return CGFloat(digits) * characterWidth + gutterPadding * 2
    }
}

