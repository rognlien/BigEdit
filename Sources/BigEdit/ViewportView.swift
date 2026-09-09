import AppKit
import CoreText

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

    private(set) var document: EditedDocument?

    /// The mapped file behind the document — for components that speak
    /// original byte offsets (search, statistics, format detection).
    var file: MappedFile? { document?.file }

    /// The line/row layout of the logical document.
    var layout: EditedLayout? { document?.layout }

    /// The first visible visual row, as a fractional value (e.g. 1234.5).
    private(set) var scrollRow: Double = 0

    /// Horizontal scroll offset in points, for rows wider than the viewport.
    private var horizontalOffset: CGFloat = 0

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
    private var widestDrawnRowWidth: CGFloat = 0

    /// Invoked whenever the scroll position changes, so the scroller can sync.
    var onScrollChange: (() -> Void)?

    /// The active search, whose matches are highlighted as they are found.
    private var searchScan: SearchScan?

    /// The byte offset of the currently selected match, drawn emphasised.
    private var currentMatchOffset: Int?

    /// The syntax-highlighting mode applied when drawing each row.
    private var syntaxMode: SyntaxMode = .plain

    /// Set while the document is drawn as aligned CSV columns. The padding this
    /// inserts means the drawn text no longer matches the file's bytes, so the
    /// mode is display-only: editing is off and hit-testing falls back to a
    /// column estimate, exactly as under a deferred replacement rule.
    private var csvDialect: CSVDialect?
    private var csvColumnLayout: CSVColumnLayout?

    /// The column being resized by a drag on its divider, with where the drag
    /// started so the new width is measured from the original rather than
    /// accumulating rounding error tick by tick.
    private var columnDrag: (column: Int, startX: CGFloat, startWidth: Int)?

    /// The user's current selection, as byte offsets into the original file.
    /// Its `activeOffset` doubles as the keyboard caret (the end being moved).
    private var selection: TextSelection? {
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
    private var desiredCaretX: CGFloat?

    /// The logical byte range of in-progress IME composition (marked text).
    /// The bytes are committed to the document as they change — this range
    /// only tracks where the composition underline is drawn and what the next
    /// `setMarkedText` replaces.
    private var markedByteRange: Range<Int>?

    /// Insertion-caret blink state (only shown when focused with an empty
    /// selection).
    private var isViewportFocused = false
    private var caretVisible = true
    private var caretBlinkTimer: Timer?

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
        let gutterW = gutterWidth(for: layout.documentLineCount)
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
    private func refreshCSVDividerCursors() {
        if isCSVRenderingActive {
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The band along the top of the viewport where column dividers are drawn
    /// and grabbed — the pinned header when there is one, and otherwise the
    /// topmost row, so the ruler is always in the same place.
    private var csvDividerBand: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: lineHeight)
    }

    /// The on-screen x of each column's trailing divider.
    private func csvDividerPositions() -> [CGFloat] {
        var positions: [CGFloat] = []
        if let csvColumnLayout, let layout {
            let textOriginX = gutterWidth(for: layout.documentLineCount) + gutterPadding
            positions = csvColumnLayout.dividerCharacterOffsets.map {
                textOriginX - horizontalOffset + CGFloat($0) * characterWidth
            }
        }
        return positions
    }

    /// The column whose divider sits under `point`, or `nil` if none does.
    private func csvDividerColumn(at point: NSPoint) -> Int? {
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

    /// True when a CSV header row is being held at the top of the viewport.
    ///
    /// Only once scrolled past it: at the very top the header is simply the
    /// first row, and pinning it there would draw it twice.
    private var isPinnedHeaderVisible: Bool {
        isCSVRenderingActive && csvDialect?.hasHeaderRow == true
            && csvDialect?.pinsHeaderRow == true && scrollRow >= 1
    }

    /// Space reserved at the top for the pinned header, so it covers no data.
    private var pinnedHeaderHeight: CGFloat {
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

    // MARK: - Editing

    /// Invoked after every successful edit so the container can update dirty
    /// state, the scroller, and content-dependent scans.
    var onEdit: (() -> Void)?

    /// Positional edits are possible when the format allows it and nothing is
    /// transforming the drawn text — neither a deferred replacement rule nor
    /// aligned CSV columns, since under either the caret's screen position no
    /// longer identifies a byte.
    var isEditingAllowed: Bool {
        document?.isEditable == true && document?.hasDisplayTransform != true
            && !isCSVRenderingActive
    }

    /// Replaces `range` with `bytes`, collapses the caret to the end of the
    /// insertion, and refreshes everything that depends on the content.
    private func performEdit(replacing range: Range<Int>, with bytes: [UInt8]) {
        guard let document, isEditingAllowed else {
            NSSound.beep()
            return
        }
        document.replace(range, with: bytes, selectionBefore: selection)
        let caret = range.lowerBound + bytes.count
        selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        desiredCaretX = nil
        onEdit?()
        scrollByteIntoView(caret)
        needsDisplay = true
    }

    /// Call after the document was edited outside the keyboard path (Replace
    /// All): clamps the selection to the new length and re-clamps the scroll.
    func documentDidChangeProgrammatically() {
        if let selection, let document {
            let length = document.length
            self.selection = TextSelection(
                anchorOffset: min(selection.anchorOffset, length),
                activeOffset: min(selection.activeOffset, length)
            )
        }
        setScrollRow(scrollRow)
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) {
        replayHistory { document in document.undoStack.undo(in: document) }
    }

    @objc func redo(_ sender: Any?) {
        replayHistory { document in document.undoStack.redo(in: document) }
    }

    private func replayHistory(_ action: (EditedDocument) -> TextSelection?) {
        guard let document, isEditingAllowed else {
            NSSound.beep()
            return
        }
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        if let restored = action(document) {
            selection = restored
            desiredCaretX = nil
            onEdit?()
            scrollByteIntoView(restored.activeOffset)
            needsDisplay = true
        } else {
            NSSound.beep()
        }
    }

    /// Inserts `bytes` at the selection. Typing without a caret does nothing
    /// (click to place one first) — arrows keep their browse-first behaviour.
    private func insertBytesAtSelection(_ bytes: [UInt8]) {
        if let selection {
            performEdit(replacing: selection.range, with: bytes)
        } else {
            NSSound.beep()
        }
    }

    override func deleteBackward(_ sender: Any?) {
        guard let document, let selection else {
            NSSound.beep()
            return
        }
        if !selection.isEmpty {
            performEdit(replacing: selection.range, with: [])
        } else if selection.activeOffset > 0 {
            let caret = selection.activeOffset
            var start = document.previousCharacterOffset(before: caret)
            // A CRLF pair deletes as one unit.
            if document.byte(at: start) == 0x0A, start > 0,
               document.byte(at: start - 1) == 0x0D {
                start -= 1
            }
            performEdit(replacing: start..<caret, with: [])
        }
    }

    override func deleteForward(_ sender: Any?) {
        guard let document, let selection else {
            NSSound.beep()
            return
        }
        if !selection.isEmpty {
            performEdit(replacing: selection.range, with: [])
        } else if selection.activeOffset < document.length {
            let caret = selection.activeOffset
            var end = document.nextCharacterOffset(after: caret)
            // A CRLF pair deletes as one unit.
            if document.byte(at: caret) == 0x0D, document.byte(at: end) == 0x0A {
                end += 1
            }
            performEdit(replacing: caret..<end, with: [])
        }
    }

    override func insertNewline(_ sender: Any?) {
        insertBytesAtSelection(document?.newlineBytes ?? [0x0A])
    }

    override func insertTab(_ sender: Any?) {
        insertBytesAtSelection([0x09])
    }

    @objc func cut(_ sender: Any?) {
        let cap = 64 * 1024 * 1024
        if let selection, !selection.isEmpty, isEditingAllowed {
            if selection.range.count > cap {
                presentSelectionTooLarge()
            } else {
                copy(sender)
                performEdit(replacing: selection.range, with: [])
            }
        } else {
            NSSound.beep()
        }
    }

    @objc func paste(_ sender: Any?) {
        if isEditingAllowed, selection != nil,
           let text = NSPasteboard.general.string(forType: .string) {
            insertBytesAtSelection(pasteBytes(from: text))
        } else {
            NSSound.beep()
        }
    }

    /// Pasted text normalised to the document's detected line ending, as
    /// UTF-8 bytes.
    private func pasteBytes(from text: String) -> [UInt8] {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        if document?.newlineBytes == [0x0D, 0x0A] {
            normalized = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        }
        return Array(normalized.utf8)
    }

    // MARK: - Keyboard caret / selection

    /// Ensures there is a caret to move from — anchored at the start of the
    /// first visible row when nothing is selected yet.
    private func ensureCaret() {
        if selection == nil {
            let origin = firstVisibleRowStartByte()
            selection = TextSelection(anchorOffset: origin, activeOffset: origin)
        }
    }

    /// Moves the caret to `target`, collapsing the selection unless `extend`.
    /// A deliberate caret move ends the current undo coalescing run.
    private func setCaret(to target: Int, extend: Bool) {
        document?.undoStack.breakCoalescing()
        if extend {
            selection?.activeOffset = target
        } else {
            selection = TextSelection(anchorOffset: target, activeOffset: target)
        }
    }

    private func moveCaretHorizontally(forward: Bool, extend: Bool) {
        guard let document else { return }
        ensureCaret()
        let target: Int
        if !extend, let range = selectionByteRange {
            target = forward ? range.upperBound : range.lowerBound   // collapse to edge
        } else {
            let caret = selection?.activeOffset ?? 0
            target = forward ? document.nextCharacterOffset(after: caret)
                             : document.previousCharacterOffset(before: caret)
        }
        desiredCaretX = nil
        setCaret(to: target, extend: extend)
        scrollByteIntoView(target)
        needsDisplay = true
    }

    private func moveCaretVertically(by rowDelta: Int, extend: Bool) {
        guard let layout else { return }
        ensureCaret()
        let caret = selection?.activeOffset ?? 0
        let currentRow = layout.visualRow(forLogicalByteOffset: caret)
        let x = desiredCaretX ?? caretX(forOffset: caret, row: currentRow)
        let targetRow = max(0, min(currentRow + rowDelta, layout.visualRowCount - 1))
        var target = caret
        if let line = layout.visualLines(forRows: targetRow..<(targetRow + 1)).first {
            target = byteOffset(inRow: line, atX: x)
        }
        desiredCaretX = x
        setCaret(to: target, extend: extend)
        scrollToRow(targetRow)
        needsDisplay = true
    }

    /// The drawn x of the caret at `offset` within the row at `row`.
    private func caretX(forOffset offset: Int, row: Int) -> CGFloat {
        var result: CGFloat = 0
        if let layout,
           let line = layout.visualLines(forRows: row..<(row + 1)).first {
            let start = chunkStartByte(line)
            let clamped = max(start, min(offset, line.byteRange.upperBound))
            if clamped > start {
                result = textWidth(ofBytes: start..<clamped)
            }
        }
        return result
    }

    private func firstVisibleRowStartByte() -> Int {
        guard let layout else { return 0 }
        let rowIndex = max(0, min(Int(scrollRow.rounded(.down)), layout.visualRowCount - 1))
        if let line = layout.visualLines(forRows: rowIndex..<(rowIndex + 1)).first {
            return chunkStartByte(line)
        }
        return 0
    }

    private func scrollByteIntoView(_ offset: Int) {
        if let layout {
            scrollToRow(layout.visualRow(forLogicalByteOffset: offset))
        }
    }

    private func shiftHorizontally(by delta: CGFloat) {
        setHorizontalOffset(horizontalOffset + delta)
        refreshCSVDividerCursors()
        needsDisplay = true
    }

    /// The furthest right the viewport can be scrolled: enough to bring the
    /// widest drawn row's right-hand edge into view, and no further.
    private var maximumHorizontalOffset: CGFloat {
        var result: CGFloat = 0
        if let layout {
            let gutter = gutterWidth(for: layout.documentLineCount)
            let textAreaWidth = max(0, bounds.width - gutter - gutterPadding)
            result = max(0, widestDrawnRowWidth - textAreaWidth)
        }
        return result
    }

    /// Sets the horizontal scroll offset, clamped to the content. Every change
    /// goes through here, so scrolling can never run off into empty space.
    private func setHorizontalOffset(_ offset: CGFloat) {
        horizontalOffset = min(max(0, offset), maximumHorizontalOffset)
    }

    // MARK: - Selection

    override func resetCursorRects() {
        // I-beam over the text area only; the gutter keeps the default arrow.
        let gutterW = layout.map { gutterWidth(for: $0.documentLineCount) } ?? 0
        let textRect = NSRect(x: gutterW, y: 0,
                              width: max(0, bounds.width - gutterW), height: bounds.height)
        addCursorRect(textRect, cursor: .iBeam)

        // Column dividers take precedence in the band along the top.
        if isCSVRenderingActive {
            let band = csvDividerBand
            for x in csvDividerPositions() where x >= gutterW && x <= bounds.width {
                addCursorRect(NSRect(x: x - 3, y: band.minY, width: 6, height: band.height),
                              cursor: .resizeLeftRight)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-click context menu. Select All is deliberately omitted
        // because selecting and copying many GB would try to build a huge
        // string on the pasteboard.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: ""
        ))
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let downPoint = convert(event.locationInWindow, from: nil)
        if let column = csvDividerColumn(at: downPoint), let csvColumnLayout {
            columnDrag = (column, downPoint.x, csvColumnLayout.columnWidths[column])
            return
        }
        if hasMarkedText() {
            // A click commits the composition (its bytes are already in the
            // document) and lets the input method start fresh.
            inputContext?.discardMarkedText()
            unmarkText()
        }
        document?.undoStack.breakCoalescing()
        desiredCaretX = nil
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
        if let columnDrag {
            let point = convert(event.locationInWindow, from: nil)
            let movedColumns = Int(((point.x - columnDrag.startX) / characterWidth).rounded())
            csvColumnLayout = csvColumnLayout?.settingWidth(
                columnDrag.startWidth + movedColumns, forColumn: columnDrag.column)
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        lastDragLocationInWindow = event.locationInWindow
        updateSelectionForDrag()
    }

    override func mouseUp(with event: NSEvent) {
        if columnDrag != nil {
            columnDrag = nil
            return
        }
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
            return wordRange(at: byteOffset)
        case .line:
            return lineRange(at: byteOffset)
        }
    }

    /// The byte range of the word-like token at `byteOffset`. Three classes —
    /// word, whitespace, other — and the run of the same class is selected.
    /// Newlines always break a run, so the selection never crosses lines.
    private func wordRange(at byteOffset: Int) -> Range<Int> {
        var result = byteOffset..<byteOffset
        if let document, let clickedByte = document.byte(at: byteOffset) {
            let total = document.length
            let cap = 10_000
            let clickedClass = byteClass(of: clickedByte)
            var start = byteOffset
            var end = byteOffset + 1
            while start > 0 && byteOffset - start < cap,
                  let candidate = document.byte(at: start - 1),
                  candidate != 0x0A, byteClass(of: candidate) == clickedClass {
                start -= 1
            }
            while end < total && end - byteOffset < cap,
                  let candidate = document.byte(at: end),
                  candidate != 0x0A, byteClass(of: candidate) == clickedClass {
                end += 1
            }
            result = start..<end
        }
        return result
    }

    /// The byte range of the visual line containing `byteOffset`, including
    /// its trailing newline if this row is the last chunk of its line.
    private func lineRange(at byteOffset: Int) -> Range<Int> {
        var result = byteOffset..<byteOffset
        if let document, let layout {
            let row = layout.visualRow(forLogicalByteOffset: byteOffset)
            let rows = layout.visualLines(forRows: row..<(row + 1))
            if let visualLine = rows.first {
                var upper = visualLine.byteRange.upperBound
                let isLastChunk = visualLine.chunkIndex == visualLine.chunkCount - 1
                if isLastChunk && upper < document.length && document.byte(at: upper) == 0x0A {
                    upper += 1
                }
                result = visualLine.byteRange.lowerBound..<upper
            }
        }
        return result
    }

    /// Categorises a byte for word-break purposes: ASCII alphanumerics +
    /// underscore are "word", common ASCII whitespace is "whitespace", and
    /// anything else (punctuation, non-ASCII) is "other". `\n` is handled
    /// explicitly at the call site so a run never crosses a newline.
    private func byteClass(of byte: UInt8) -> ByteClass {
        if (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F
            || byte >= 0x80 {              // any UTF-8 multibyte sequence is "word"
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
        if let document, let layout, layout.visualRowCount > 0 {
            let firstRow = Int(scrollRow)
            let fraction = scrollRow - Double(firstRow)
            let contentY = max(0, Double(point.y) - Double(pinnedHeaderHeight))
            let rowsFromTop = (contentY + fraction * Double(lineHeight)) / Double(lineHeight)
            var rowIndex = firstRow + Int(rowsFromTop.rounded(.down))
            rowIndex = max(0, min(rowIndex, layout.visualRowCount - 1))

            let rows = layout.visualLines(forRows: rowIndex..<(rowIndex + 1))
            if let visualLine = rows.first {
                let gutterW = gutterWidth(for: layout.documentLineCount)
                let textOriginX = gutterW + gutterPadding
                let relativeX = point.x - textOriginX + horizontalOffset
                result = byteOffset(inRow: visualLine, atX: relativeX)
            } else {
                result = document.length
            }
        }
        return result
    }

    /// Maps an x position within a visual row to a byte offset. Uses CoreText so
    /// the result lands on a character boundary even with non-ASCII or otherwise
    /// variable-width glyphs, instead of assuming one column equals one byte.
    /// While a replacement rule is active, or CSV columns are being padded into
    /// alignment, the drawn text differs from the underlying bytes, so it falls
    /// back to a monospaced column estimate.
    private func byteOffset(inRow visualLine: LineIndex.VisualLine,
                            atX relativeX: CGFloat) -> Int {
        let rs = visualLine.byteRange.lowerBound
        let re = visualLine.byteRange.upperBound

        if document?.hasDisplayTransform == true || isCSVRenderingActive {
            let approxChars = Int((max(0, relativeX) / characterWidth).rounded())
            return max(rs, min(rs + approxChars, re))
        }

        let startByte = chunkStartByte(visualLine)
        let text = decodeChunk(visualLine)
        if text.isEmpty {
            return startByte
        }

        let line = CTLineCreateWithAttributedString(attributedRow(text) as CFAttributedString)
        let position = CGPoint(x: max(0, relativeX), y: 0)
        let utf16Index = CTLineGetStringIndexForPosition(line, position)
        let target = max(0, min(Int(utf16Index), text.utf16.count))

        // Convert the UTF-16 string index back to a byte offset in the file.
        var consumedUTF16 = 0
        var consumedBytes = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if consumedUTF16 + width > target {
                break
            }
            consumedUTF16 += width
            let value = scalar.value
            consumedBytes += value < 0x80 ? 1 : (value < 0x800 ? 2 : (value < 0x10000 ? 3 : 4))
        }
        return min(startByte + consumedBytes, re)
    }

    /// The first fully-decodable byte of a chunk. A continuation chunk can begin
    /// mid-UTF-8 sequence, so skip leading continuation bytes — mirroring how
    /// `decodeChunk` builds the displayed text.
    private func chunkStartByte(_ visualLine: LineIndex.VisualLine) -> Int {
        var start = visualLine.byteRange.lowerBound
        if visualLine.chunkIndex > 0, let document {
            var skipped = 0
            while start < visualLine.byteRange.upperBound && skipped < 3,
                  let byte = document.byte(at: start), (byte & 0xC0) == 0x80 {
                start += 1
                skipped += 1
            }
        }
        return start
    }

    // MARK: - Copy / Select All

    @objc func copy(_ sender: Any?) {
        let cap = 64 * 1024 * 1024
        if let selection, !selection.isEmpty, let document {
            let range = selection.range
            if range.count > cap {
                presentSelectionTooLarge()
            } else {
                let bytes = document.displayBytes(in: range)
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
        if let document {
            selection = TextSelection(anchorOffset: 0, activeOffset: document.length)
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
        widestDrawnRowWidth = 0
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Drawing

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

        let gutterWidth = self.gutterWidth(for: layout.documentLineCount)
        let startState = seedState(forFirstRow: firstRow, layout: layout)
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

    /// Dispatches a row to the active highlighter, returning its colouring and
    /// the carried state at the row's end.
    private func highlightedRow(_ text: String, startState: HighlightState)
        -> (NSAttributedString, HighlightState) {
        switch syntaxMode {
        case .xml: return XMLHighlighter.attributedRow(text, font: font, startState: startState)
        case .json: return JSONHighlighter.attributedRow(text, font: font, startState: startState)
        case .markdown: return MarkdownHighlighter.attributedRow(text, font: font, startState: startState)
        case .yaml: return YAMLHighlighter.attributedRow(text, font: font, startState: startState)
        case .plain:
            let attributed = NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
            return (attributed, .normal)
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
                textOriginX: textOriginX
            )
        }
    }

    private func drawHighlightRects(
        _ offsets: [Int],
        needleLength: Int,
        rowStart: Int,
        rowEnd: Int,
        rowY: CGFloat,
        textOriginX: CGFloat
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

    // MARK: - Helpers

    /// Builds the drawable, coloured form of a single row's text from a normal
    /// start state — used for hit-testing where carried state doesn't matter.
    private func attributedRow(_ text: String) -> NSAttributedString {
        return highlightedRow(text, startState: .normal).0
    }

    /// Decodes one chunk's bytes to a `String`. A chunk is at most
    /// `LineIndex.bytesPerChunk` bytes, so this is always cheap — even when the
    /// chunk belongs to a multi-gigabyte minified line.
    private func decodeChunk(_ visualLine: LineIndex.VisualLine) -> String {
        var text = ""
        if let document {
            // A continuation chunk may begin in the middle of a UTF-8 sequence;
            // drop any leading continuation bytes so decoding starts cleanly.
            let range = chunkStartByte(visualLine)..<visualLine.byteRange.upperBound
            if !range.isEmpty {
                text = String(decoding: document.displayBytes(in: range), as: UTF8.self)
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
    private func textWidth(ofBytes range: Range<Int>) -> CGFloat {
        var width: CGFloat = 0
        if let document, !range.isEmpty {
            let text = String(decoding: document.bytes(in: range), as: UTF8.self) as NSString
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
        case #selector(cut(_:)):
            enabled = !(selection?.isEmpty ?? true) && isEditingAllowed
        case #selector(paste(_:)):
            enabled = isEditingAllowed && selection != nil
                && NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            enabled = document != nil
        case #selector(undo(_:)):
            enabled = isEditingAllowed && document?.undoStack.canUndo == true
        case #selector(redo(_:)):
            enabled = isEditingAllowed && document?.undoStack.canRedo == true
        default:
            enabled = true
        }
        return enabled
    }
}

// MARK: - NSTextInputClient

/// The input-client conformance needed for IME composition, dead keys, and
/// press-and-hold accents. The document is far too large for global UTF-16
/// ranges, so ranges are reported in a synthetic space anchored at the start
/// of the marked text; composition bytes live in the document itself.
extension ViewportView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = ViewportView.plainString(from: string)
        let target = editTargetRange(for: replacementRange)
        markedByteRange = nil
        if let target {
            performEdit(replacing: target, with: Array(text.utf8))
        } else {
            NSSound.beep()
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = ViewportView.plainString(from: string)
        if isEditingAllowed, let target = editTargetRange(for: replacementRange) {
            let bytes = Array(text.utf8)
            performEdit(replacing: target, with: bytes)
            markedByteRange = bytes.isEmpty
                ? nil
                : target.lowerBound..<(target.lowerBound + bytes.count)
        }
    }

    func unmarkText() {
        markedByteRange = nil
        needsDisplay = true
    }

    func hasMarkedText() -> Bool {
        markedByteRange != nil
    }

    func markedRange() -> NSRange {
        var result = NSRange(location: NSNotFound, length: 0)
        if let marked = markedByteRange, let document {
            let text = String(decoding: document.bytes(in: marked), as: UTF8.self)
            result = NSRange(location: 0, length: text.utf16.count)
        }
        return result
    }

    func selectedRange() -> NSRange {
        // During composition the caret sits at the marked text's end; there
        // is no meaningful global range to report otherwise.
        var result = NSRange(location: NSNotFound, length: 0)
        if hasMarkedText() {
            result = NSRange(location: markedRange().length, length: 0)
        }
        return result
    }

    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// The caret rectangle in screen coordinates — anchors the input method's
    /// candidate window.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var result = NSRect.zero
        if let layout, let window, let caret = caretByteOffset {
            let caretRow = layout.visualRow(forLogicalByteOffset: caret)
            let x = caretX(forOffset: caret, row: caretRow)
            let gutterW = gutterWidth(for: layout.documentLineCount)
            let viewRect = NSRect(
                x: gutterW + gutterPadding - horizontalOffset + x,
                y: (CGFloat(caretRow) - CGFloat(scrollRow)) * lineHeight,
                width: 1,
                height: lineHeight
            )
            result = window.convertToScreen(convert(viewRect, to: nil))
        }
        return result
    }

    /// The logical byte range an input-method `replacementRange` addresses.
    /// Its offsets are UTF-16 positions in the synthetic space anchored at the
    /// marked text; without an explicit range, the marked range or selection.
    private func editTargetRange(for replacementRange: NSRange) -> Range<Int>? {
        var result: Range<Int>?
        if let marked = markedByteRange, let document {
            result = marked
            if replacementRange.location != NSNotFound {
                let text = String(decoding: document.bytes(in: marked), as: UTF8.self)
                let start = ViewportView.byteOffset(forUTF16Index: replacementRange.location, in: text)
                let end = ViewportView.byteOffset(
                    forUTF16Index: replacementRange.location + replacementRange.length, in: text)
                result = (marked.lowerBound + start)..<(marked.lowerBound + end)
            }
        } else if let selection {
            result = selection.range
        }
        return result
    }

    /// Converts a UTF-16 index within `text` to a UTF-8 byte offset, clamped.
    private static func byteOffset(forUTF16Index target: Int, in text: String) -> Int {
        var consumedUTF16 = 0
        var consumedBytes = 0
        for scalar in text.unicodeScalars {
            if consumedUTF16 >= target {
                break
            }
            consumedUTF16 += scalar.value > 0xFFFF ? 2 : 1
            consumedBytes += UTF8.width(scalar)
        }
        return consumedBytes
    }

    private static func plainString(from string: Any) -> String {
        var result = ""
        if let text = string as? String {
            result = text
        } else if let attributed = string as? NSAttributedString {
            result = attributed.string
        }
        return result
    }
}
