import AppKit

/// Moving between cells under aligned CSV columns.
///
/// A row's cells are the text between its delimiters, so a row can have
/// fewer cells than the table has columns — an empty line has one. Moving
/// into a column the row lacks parks the caret at the line's end, drawn in
/// that column (`csvCaretColumn`); the first character typed there adds the
/// delimiters that create the cell.
extension ViewportView {

    /// Tab / Shift-Tab: selects the next or previous cell's value, moving to
    /// the next or previous row past the ends of the table's columns.
    func moveToAdjacentCSVCell(forward: Bool) {
        guard let layout, let csvColumnLayout, let caret = selection?.activeOffset else {
            NSSound.beep()
            return
        }
        let row = layout.visualRow(forLogicalByteOffset: caret)
        guard let line = layout.visualLines(forRows: row..<(row + 1)).first,
              let map = csvRowMap(for: line) else {
            NSSound.beep()
            return
        }
        let current = csvCaretColumn ?? map.cellIndex(forByte: caret - line.byteRange.lowerBound) ?? 0
        let target = forward ? current + 1 : current - 1
        if target < 0 {
            moveToCell(inRow: row - 1, column: .last)
        } else if target >= csvColumnLayout.columnWidths.count {
            moveToCell(inRow: row + 1, column: .first)
        } else {
            moveToCell(inRow: row, column: .index(target))
        }
    }

    private enum CellChoice {
        case first
        case last
        case index(Int)
    }

    /// Selects the chosen cell of `row`, or parks the caret in a column the
    /// row has no cell for. Off either end of the document it beeps.
    private func moveToCell(inRow row: Int, column: CellChoice) {
        guard let layout, row >= 0, row < layout.visualRowCount,
              let line = layout.visualLines(forRows: row..<(row + 1)).first,
              let map = csvRowMap(for: line) else {
            NSSound.beep()
            return
        }
        let index: Int
        switch column {
        case .first: index = 0
        case .last: index = max(0, (csvColumnLayout?.columnWidths.count ?? 1) - 1)
        case .index(let wanted): index = wanted
        }
        let rowStart = line.byteRange.lowerBound
        document?.undoStack.breakCoalescing()
        desiredCaretX = nil
        if index < map.cells.count {
            let cell = map.cells[index]
            selection = TextSelection(anchorOffset: rowStart + cell.valueStart,
                                      activeOffset: rowStart + cell.valueEnd)
            scrollByteIntoView(rowStart + cell.valueStart)
        } else {
            let lineEnd = rowStart + map.lineLength
            selection = TextSelection(anchorOffset: lineEnd, activeOffset: lineEnd)
            csvCaretColumn = index
            scrollByteIntoView(lineEnd)
        }
        needsDisplay = true
    }

    /// The delimiters that turn the caret's parked column into a real cell,
    /// prepended to an insertion at the line's end — nothing otherwise.
    func csvDelimitersCreatingCaretCell(before bytes: [UInt8], at range: Range<Int>) -> [UInt8] {
        var result = bytes
        if let column = csvCaretColumn, let csvDialect, let layout, range.isEmpty,
           let delimiter = textEncoding.encode(String(csvDialect.delimiter)) {
            let row = layout.visualRow(forLogicalByteOffset: range.lowerBound)
            if let line = layout.visualLines(forRows: row..<(row + 1)).first,
               let map = csvRowMap(for: line) {
                let missing = column - (map.cells.count - 1)
                if missing > 0 {
                    result = Array(repeating: delimiter, count: missing).flatMap { $0 } + bytes
                }
            }
        }
        return result
    }
}
