import AppKit

/// Moving between cells under aligned CSV columns.
///
/// A row's cells are the text between its delimiters, so a row can have
/// fewer cells than the table has columns — an empty line has one. Moving
/// into a column the row lacks parks the caret at the line's end, drawn in
/// that column (`csvCaretColumn`); the first character typed there adds the
/// delimiters that create the cell.
extension ViewportView {

    /// Tab / Shift-Tab: selects the next or previous cell's value. Shift-Tab
    /// before the first column moves to the previous row's last; Tab past the
    /// last column adds a new one to the row.
    func moveToAdjacentCSVCell(forward: Bool) {
        guard let csvColumnLayout, let position = csvCaretPosition() else {
            NSSound.beep()
            return
        }
        let target = forward ? position.column + 1 : position.column - 1
        if target < 0 {
            moveToCell(inRow: position.row - 1, column: .last)
        } else if target >= csvColumnLayout.columnWidths.count {
            appendCSVColumn(target, rowStart: position.rowStart, map: position.map)
        } else {
            moveToCell(inRow: position.row, column: .index(target))
        }
    }

    /// Return: selects the cell in the same column of the next row, as in
    /// Numbers. Past the last row it adds a row and parks the caret in that
    /// column of it.
    func moveToCSVCellBelow() {
        if let layout, let position = csvCaretPosition() {
            if position.row + 1 < layout.visualRowCount {
                moveToCell(inRow: position.row + 1, column: .index(position.column))
            } else {
                appendCSVRow(after: position.rowStart + position.map.lineLength, column: position.column)
            }
        } else {
            NSSound.beep()
        }
    }

    /// Ends the document's last row with a line ending, as one undoable
    /// edit, and parks the caret in `column` of the new row.
    private func appendCSVRow(after lineEnd: Int, column: Int) {
        selection = TextSelection(anchorOffset: lineEnd, activeOffset: lineEnd)
        document?.undoStack.breakCoalescing()
        performEdit(replacing: lineEnd..<lineEnd, with: document?.newlineBytes ?? [0x0A])
        csvCaretColumn = column > 0 ? column : nil
        needsDisplay = true
    }

    /// The caret's visual row, that row's start and cell map, and the column
    /// the caret is in — a parked column included.
    func csvCaretPosition() -> (row: Int, rowStart: Int, map: CSVRowMap, column: Int)? {
        var result: (row: Int, rowStart: Int, map: CSVRowMap, column: Int)?
        if let layout, let caret = selection?.activeOffset {
            let row = layout.visualRow(forLogicalByteOffset: caret)
            if let line = layout.visualLines(forRows: row..<(row + 1)).first, let map = csvRowMap(for: line) {
                let rowStart = line.byteRange.lowerBound
                let column = csvCaretColumn ?? map.cellIndex(forByte: caret - rowStart) ?? 0
                result = (row, rowStart, map, column)
            }
        }
        return result
    }

    /// Ends the row with the delimiters that give it an empty cell in
    /// `column`, as one undoable edit, and leaves the caret in that cell.
    private func appendCSVColumn(_ column: Int, rowStart: Int, map: CSVRowMap) {
        let lineEnd = rowStart + map.lineLength
        selection = TextSelection(anchorOffset: lineEnd, activeOffset: lineEnd)
        csvCaretColumn = column
        document?.undoStack.breakCoalescing()
        performEdit(replacing: lineEnd..<lineEnd, with: [])
    }

    enum CellChoice {
        case last
        case index(Int)
    }

    /// Selects the chosen cell of `row`, or parks the caret in a column the
    /// row has no cell for. Off either end of the document it beeps.
    func moveToCell(inRow row: Int, column: CellChoice) {
        guard let layout, row >= 0, row < layout.visualRowCount,
              let line = layout.visualLines(forRows: row..<(row + 1)).first,
              let map = csvRowMap(for: line) else {
            NSSound.beep()
            return
        }
        let index: Int
        switch column {
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
