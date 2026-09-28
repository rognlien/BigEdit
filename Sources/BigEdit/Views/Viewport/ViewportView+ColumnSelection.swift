import AppKit

/// Rectangular selection: Option-drag, or ⌃⇧↑/↓ from the caret. While one is
/// active, ⇧ + arrows resize it. It selects and copies; any edit or other
/// caret move turns it back into a plain caret.
extension ViewportView {

    func beginColumnSelection(at point: NSPoint) {
        let row = visualRowIndex(at: point)
        let x = max(0, textX(at: point))
        setColumnSelection(ColumnSelection(anchorRow: row, activeRow: row, anchorX: x, activeX: x))
    }

    func dragColumnSelection(to point: NSPoint) {
        if var column = columnSelection {
            column.activeRow = visualRowIndex(at: point)
            column.activeX = max(0, textX(at: point))
            setColumnSelection(column)
        }
    }

    /// Handles ⌃⇧↑/↓, and ⇧ + arrows while a column selection is active.
    /// Returns false for every other key.
    func handleColumnSelectionKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let startsColumn = flags == [.shift, .control]
        let resizesColumn = flags == .shift && columnSelection != nil
        var handled = false
        if startsColumn || resizesColumn {
            handled = true
            switch event.keyCode {
            case 126: extendColumnSelection(byRows: -1)
            case 125: extendColumnSelection(byRows: 1)
            case 123 where resizesColumn: widenColumnSelection(byCharacters: -1)
            case 124 where resizesColumn: widenColumnSelection(byCharacters: 1)
            default: handled = false
            }
        }
        return handled
    }

    func extendColumnSelection(byRows delta: Int) {
        if let layout, var column = columnSelection ?? columnSelectionAtCaret() {
            column.activeRow = max(0, min(column.activeRow + delta, layout.visualRowCount - 1))
            setColumnSelection(column)
            scrollToRow(column.activeRow)
        } else {
            NSSound.beep()
        }
    }

    func widenColumnSelection(byCharacters delta: Int) {
        if var column = columnSelection {
            column.activeX = max(0, column.activeX + CGFloat(delta) * characterWidth)
            setColumnSelection(column)
        }
    }

    private func columnSelectionAtCaret() -> ColumnSelection? {
        var result: ColumnSelection?
        if let layout, let caret = selection?.activeOffset {
            let row = layout.visualRow(forLogicalByteOffset: caret)
            let x = caretX(forOffset: caret, row: row)
            result = ColumnSelection(anchorRow: row, activeRow: row, anchorX: x, activeX: x)
        }
        return result
    }

    /// Makes `column` the selection, with the caret at its active corner.
    private func setColumnSelection(_ column: ColumnSelection) {
        document?.undoStack.breakCoalescing()
        var caret = 0
        if let line = layout?.visualLines(forRows: column.activeRow..<(column.activeRow + 1)).first {
            caret = byteOffset(inRow: line, atX: column.activeX)
        }
        selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        columnSelection = column
        desiredCaretX = nil
    }

    /// The bytes `column` covers on `visualLine`, snapped to characters.
    func columnSlice(of column: ColumnSelection, in visualLine: LineIndex.VisualLine) -> Range<Int> {
        let lower = byteOffset(inRow: visualLine, atX: column.xRange.lowerBound)
        let upper = byteOffset(inRow: visualLine, atX: column.xRange.upperBound)
        return lower..<max(lower, upper)
    }

    /// Each row's slice of the column selection, top to bottom.
    func columnSelectionSlices() -> [Range<Int>] {
        var result: [Range<Int>] = []
        if let column = columnSelection, let layout {
            let rows = column.rows.lowerBound..<(column.rows.upperBound + 1)
            result = layout.visualLines(forRows: rows).map { columnSlice(of: column, in: $0) }
        }
        return result
    }

    /// The column selection as text for the pasteboard, one row per line, or
    /// nil when it is larger than `cap` bytes.
    func columnSelectionText(cap: Int) -> String? {
        var result: String?
        let slices = columnSelectionSlices()
        if let document, slices.reduce(0, { $0 + $1.count }) <= cap {
            result = slices
                .map { ViewportView.pasteboardText(from: document.displayBytes(in: $0), encoding: textEncoding) }
                .joined(separator: "\n")
        }
        return result
    }
}
