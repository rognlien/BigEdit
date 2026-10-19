import AppKit

/// Editing that respects the cells under aligned CSV columns, as in a
/// spreadsheet: what is typed into a cell stays in it.
extension ViewportView {

    /// A raw field being edited: its bytes, where it starts in the
    /// document, and the edited range relative to it.
    private struct EditedField {
        let bytes: [UInt8]
        let start: Int
        let range: Range<Int>
    }

    /// The start and cell map of the row holding `offset`, under CSV columns.
    func csvRow(containing offset: Int) -> (start: Int, map: CSVRowMap)? {
        var result: (start: Int, map: CSVRowMap)?
        if let layout {
            let row = layout.visualRow(forLogicalByteOffset: offset)
            if let line = layout.visualLines(forRows: row..<(row + 1)).first, let map = csvRowMap(for: line) {
                result = (line.byteRange.lowerBound, map)
            }
        }
        return result
    }

    /// Puts typed or pasted `bytes` in place of `range`. Under CSV columns
    /// they stay inside their cell, which is quoted when they would split
    /// it; when the dialect has no quote to do that with, it beeps.
    /// Typed over a selection of several cells, the text replaces it in the
    /// first of them and clears the rest.
    func insertKeepingCells(_ bytes: [UInt8], replacing range: Range<Int>) {
        if isCSVRenderingActive && !range.isEmpty && !liesInOneCSVField(range) {
            replaceCells(in: range, with: bytes)
        } else {
            insertIntoCell(bytes, replacing: range)
        }
    }

    /// Puts composed `bytes` in place of `range` as typing would, and
    /// returns where they landed: inside the quotes, any quote in them
    /// doubled, when they made the cell need quoting. Nil, after a beep,
    /// when the cell cannot hold them.
    func insertComposedKeepingCells(_ bytes: [UInt8], replacing range: Range<Int>) -> Range<Int>? {
        var result: Range<Int>?
        if let edit = cellInsertion(of: bytes, replacing: range) {
            performEdit(replacing: edit.range, with: edit.bytes, bytesAfterCaret: edit.bytesAfterCaret)
            let end = selection?.activeOffset ?? edit.range.upperBound
            result = (end - typedLength(of: bytes))..<end
        } else {
            NSSound.beep()
        }
        return result
    }

    private func typedLength(of bytes: [UInt8]) -> Int {
        var result = bytes.count
        if let csvDialect, isCSVRenderingActive {
            result = CSVCellEditing.typedValue(of: bytes, dialect: csvDialect, encoding: textEncoding).count
        }
        return result
    }

    private func insertIntoCell(_ bytes: [UInt8], replacing range: Range<Int>) {
        if let edit = cellInsertion(of: bytes, replacing: range) {
            performEdit(replacing: edit.range, with: edit.bytes, bytesAfterCaret: edit.bytesAfterCaret)
        } else {
            NSSound.beep()
        }
    }

    /// Clears the cells `range` covers and types `bytes` into the first, as
    /// one undoable step.
    private func replaceCells(in range: Range<Int>, with bytes: [UInt8]) {
        document?.undoStack.beginGrouping()
        if deleteKeepingCells(range) {
            let caret = selection?.activeOffset ?? range.lowerBound
            insertIntoCell(bytes, replacing: caret..<caret)
        }
        document?.undoStack.endGrouping()
    }

    /// Deletes `range`. Under CSV columns that clears the cells it covers,
    /// as a spreadsheet does, keeping their delimiters, quotes and line
    /// endings so no cell or row is merged into another. Returns false
    /// when the range is too large to clear.
    @discardableResult
    func deleteKeepingCells(_ range: Range<Int>) -> Bool {
        var deleted = true
        if isCSVRenderingActive && csvLines(around: range).count > 64 * 1024 * 1024 {
            presentSelectionTooLarge()
            deleted = false
        } else if let edit = deletionKeepingCells(range) {
            performEdit(replacing: edit.range, with: edit.bytes, bytesAfterCaret: edit.bytesAfterCaret)
        } else {
            selection = TextSelection(anchorOffset: range.lowerBound, activeOffset: range.lowerBound)
        }
        return deleted
    }

    /// The edit that deletes `range`: under CSV columns the one clearing the
    /// cells it covers, nil when it covers no cell content.
    func deletionKeepingCells(_ range: Range<Int>) -> CSVCellEdit? {
        var result: CSVCellEdit? = CSVCellEdit(range: range, bytes: [], bytesAfterCaret: 0)
        if let csvDialect, let document, isCSVRenderingActive {
            let lines = csvLines(around: range)
            result = CSVCellEditing.clearing(
                (range.lowerBound - lines.lowerBound)..<(range.upperBound - lines.lowerBound),
                in: document.bytes(in: lines), dialect: csvDialect, encoding: textEncoding)?
                .shifted(by: lines.lowerBound)
        }
        return result
    }

    /// The whole lines `range` touches, without the last one's ending.
    private func csvLines(around range: Range<Int>) -> Range<Int> {
        lineContentRange(containing: range.lowerBound).lowerBound
            ..< lineContentRange(containing: range.upperBound).upperBound
    }

    private func liesInOneCSVField(_ range: Range<Int>) -> Bool {
        csvRow(containing: range.lowerBound).flatMap { editedField(for: range, in: $0) } != nil
    }

    private func cellInsertion(of bytes: [UInt8], replacing range: Range<Int>) -> CSVCellEdit? {
        var result: CSVCellEdit? = CSVCellEdit(range: range, bytes: bytes, bytesAfterCaret: 0)
        if let csvDialect, let row = csvRow(containing: range.lowerBound),
           let field = editedField(for: range, in: row) {
            result = CSVCellEditing.insertion(of: bytes, replacing: field.range, inField: field.bytes,
                                              dialect: csvDialect, encoding: textEncoding)?
                .shifted(by: field.start)
        }
        return result
    }

    /// Backspace (`backward`) or Forward Delete at `caret` under CSV
    /// columns: removes a character of the caret's cell, and at the cell's
    /// edge beeps rather than delete the delimiter, as Numbers does.
    func deleteCharacterInCell(backward: Bool, at caret: Int, in row: (start: Int, map: CSVRowMap)) {
        if let csvDialect, let field = editedField(for: caret..<caret, in: row),
           let range = CSVCellEditing.deletion(backward: backward, at: field.range.lowerBound,
                                               inField: field.bytes, dialect: csvDialect,
                                               encoding: textEncoding) {
            performEdit(replacing: (field.start + range.lowerBound)..<(field.start + range.upperBound), with: [])
        } else {
            NSSound.beep()
        }
    }

    /// The field `range` lies in, or nil when it reaches beyond one. A caret
    /// parked in a column the row has no cell for is in an empty field at
    /// the line's end, which the edit creates.
    private func editedField(for range: Range<Int>, in row: (start: Int, map: CSVRowMap)) -> EditedField? {
        var result: EditedField?
        let lower = range.lowerBound - row.start
        let upper = range.upperBound - row.start
        if let column = csvCaretColumn, column >= row.map.cells.count, range.isEmpty {
            result = EditedField(bytes: [], start: range.lowerBound, range: 0..<0)
        } else if let index = row.map.cellIndex(forByte: lower),
                  upper <= row.map.cells[index].byteRange.upperBound {
            let fieldStart = row.map.cells[index].byteRange.lowerBound
            result = EditedField(bytes: row.map.fieldBytes(ofCell: index), start: row.start + fieldStart,
                                 range: (lower - fieldStart)..<(upper - fieldStart))
        }
        return result
    }
}
