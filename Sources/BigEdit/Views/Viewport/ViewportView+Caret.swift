import AppKit
import CoreText

/// Moving the keyboard caret and keeping it in view.
extension ViewportView {

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

    func moveCaretHorizontally(forward: Bool, extend: Bool) {
        guard let document else { return }
        ensureCaret()
        let target: Int
        if !extend, let range = selectionByteRange {
            target = forward ? range.upperBound : range.lowerBound   // collapse to edge
        } else {
            let caret = selection?.activeOffset ?? 0
            target = forward ? document.nextGraphemeOffset(after: caret)
                             : document.previousGraphemeOffset(before: caret)
        }
        desiredCaretX = nil
        setCaret(to: target, extend: extend)
        scrollByteIntoView(target)
        needsDisplay = true
    }

    func moveCaretVertically(by rowDelta: Int, extend: Bool) {
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

    func moveCaretByWord(forward: Bool, extend: Bool) {
        ensureCaret()
        let origin = wordMoveOrigin(forward: forward, extend: extend)
        let target = forward ? nextWordOffset(after: origin) : previousWordOffset(before: origin)
        desiredCaretX = nil
        setCaret(to: target, extend: extend)
        scrollByteIntoView(target)
        needsDisplay = true
    }

    /// Where a word move starts: the caret, or the edge of the selection it
    /// collapses towards.
    private func wordMoveOrigin(forward: Bool, extend: Bool) -> Int {
        var result = selection?.activeOffset ?? 0
        if !extend, let range = selectionByteRange {
            result = forward ? range.upperBound : range.lowerBound
        }
        return result
    }

    /// The logical line containing `offset`, excluding its line ending. A
    /// wrapped line counts as one line, as in other Mac text views.
    func lineContentRange(containing offset: Int) -> Range<Int> {
        var result = offset..<offset
        if let layout, let document {
            let line = layout.logicalLineRange(containing: offset)
            let start = line.lowerBound
            var end = line.upperBound
            if end > start, document.byte(at: end - 1) == 0x0A { end -= 1 }
            if end > start, document.byte(at: end - 1) == 0x0D { end -= 1 }
            result = start..<end
        }
        return result
    }

    /// Moves the caret to the start or end of its logical line.
    func moveCaretToLineBoundary(end: Bool, extend: Bool) {
        ensureCaret()
        let line = lineContentRange(containing: selection?.activeOffset ?? 0)
        let target = end ? line.upperBound : line.lowerBound
        desiredCaretX = nil
        setCaret(to: target, extend: extend)
        scrollByteIntoView(target)
        needsDisplay = true
    }

    // An input method sends these for an arrow key that ends a composition.
    override func moveLeft(_ sender: Any?) {
        moveCaretHorizontally(forward: false, extend: false)
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        moveCaretHorizontally(forward: false, extend: true)
    }

    override func moveRight(_ sender: Any?) {
        moveCaretHorizontally(forward: true, extend: false)
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        moveCaretHorizontally(forward: true, extend: true)
    }

    // Control-F and Control-B are bound to these in the standard key bindings,
    // and Option-Up and Option-Down send them before a paragraph move.
    override func moveForward(_ sender: Any?) {
        moveCaretHorizontally(forward: true, extend: false)
    }

    override func moveForwardAndModifySelection(_ sender: Any?) {
        moveCaretHorizontally(forward: true, extend: true)
    }

    override func moveBackward(_ sender: Any?) {
        moveCaretHorizontally(forward: false, extend: false)
    }

    override func moveBackwardAndModifySelection(_ sender: Any?) {
        moveCaretHorizontally(forward: false, extend: true)
    }

    // Option-Left and Option-Right are bound to these in the standard key
    // bindings, and Option-Control-F and Option-Control-B to the next four.
    override func moveWordLeft(_ sender: Any?) {
        moveCaretByWord(forward: false, extend: false)
    }

    override func moveWordLeftAndModifySelection(_ sender: Any?) {
        moveCaretByWord(forward: false, extend: true)
    }

    override func moveWordRight(_ sender: Any?) {
        moveCaretByWord(forward: true, extend: false)
    }

    override func moveWordRightAndModifySelection(_ sender: Any?) {
        moveCaretByWord(forward: true, extend: true)
    }

    override func moveWordForward(_ sender: Any?) {
        moveCaretByWord(forward: true, extend: false)
    }

    override func moveWordForwardAndModifySelection(_ sender: Any?) {
        moveCaretByWord(forward: true, extend: true)
    }

    override func moveWordBackward(_ sender: Any?) {
        moveCaretByWord(forward: false, extend: false)
    }

    override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        moveCaretByWord(forward: false, extend: true)
    }

    override func moveUp(_ sender: Any?) {
        moveCaretVertically(by: -1, extend: false)
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        moveCaretVertically(by: -1, extend: true)
    }

    override func moveDown(_ sender: Any?) {
        moveCaretVertically(by: 1, extend: false)
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        moveCaretVertically(by: 1, extend: true)
    }

    // Control-A and Control-E are bound to these in the standard key bindings.
    override func moveToBeginningOfParagraph(_ sender: Any?) {
        moveCaretToLineBoundary(end: false, extend: false)
    }

    override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) {
        moveCaretToLineBoundary(end: false, extend: true)
    }

    override func moveToEndOfParagraph(_ sender: Any?) {
        moveCaretToLineBoundary(end: true, extend: false)
    }

    override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) {
        moveCaretToLineBoundary(end: true, extend: true)
    }

    // Option-Shift-Up and Option-Shift-Down are bound to these in the
    // standard key bindings: to the start or end of the line, or on to the
    // previous or next one from there.
    override func moveParagraphBackwardAndModifySelection(_ sender: Any?) {
        moveCaretHorizontally(forward: false, extend: true)
        moveCaretToLineBoundary(end: false, extend: true)
    }

    override func moveParagraphForwardAndModifySelection(_ sender: Any?) {
        moveCaretHorizontally(forward: true, extend: true)
        moveCaretToLineBoundary(end: true, extend: true)
    }

    func moveCaretToDocumentBoundary(end: Bool, extend: Bool) {
        ensureCaret()
        let target = end ? (document?.length ?? 0) : 0
        desiredCaretX = nil
        setCaret(to: target, extend: extend)
        scrollByteIntoView(target)
        needsDisplay = true
    }

    // Command-Left and Command-Right are bound to these in the standard key bindings.
    override func moveToLeftEndOfLine(_ sender: Any?) {
        moveCaretToLineBoundary(end: false, extend: false)
    }

    override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
        moveCaretToLineBoundary(end: false, extend: true)
    }

    override func moveToRightEndOfLine(_ sender: Any?) {
        moveCaretToLineBoundary(end: true, extend: false)
    }

    override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) {
        moveCaretToLineBoundary(end: true, extend: true)
    }

    // Command-Up and Command-Down are bound to these in the standard key bindings.
    override func moveToBeginningOfDocument(_ sender: Any?) {
        moveCaretToDocumentBoundary(end: false, extend: false)
    }

    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        moveCaretToDocumentBoundary(end: false, extend: true)
    }

    override func moveToEndOfDocument(_ sender: Any?) {
        moveCaretToDocumentBoundary(end: true, extend: false)
    }

    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        moveCaretToDocumentBoundary(end: true, extend: true)
    }

    /// The drawn x of the caret at `offset` within the row at `row`.
    func caretX(forOffset offset: Int, row: Int) -> CGFloat {
        var result: CGFloat = 0
        if let layout,
           let line = layout.visualLines(forRows: row..<(row + 1)).first {
            result = xOffset(inRow: line, forByte: offset)
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

    func scrollByteIntoView(_ offset: Int) {
        if let layout {
            scrollToRow(layout.visualRow(forLogicalByteOffset: offset))
        }
    }

    func shiftHorizontally(by delta: CGFloat) {
        setHorizontalOffset(horizontalOffset + delta)
        refreshCSVDividerCursors()
        needsDisplay = true
    }

    /// The furthest right the viewport can be scrolled: enough to bring the
    /// widest drawn row's right-hand edge into view, and no further.
    private var maximumHorizontalOffset: CGFloat {
        var result: CGFloat = 0
        if let layout {
            let gutter = gutterWidth(for: layout.gutterLineCount)
            let textAreaWidth = max(0, bounds.width - gutter - gutterPadding)
            result = max(0, widestDrawnRowWidth - textAreaWidth)
        }
        return result
    }

    /// Sets the horizontal scroll offset, clamped to the content. Every change
    /// goes through here, so scrolling can never run off into empty space.
    func setHorizontalOffset(_ offset: CGFloat) {
        horizontalOffset = min(max(0, offset), maximumHorizontalOffset)
    }
}
