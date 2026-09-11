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
            target = forward ? document.nextCharacterOffset(after: caret)
                             : document.previousCharacterOffset(before: caret)
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
