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
    func insertKeepingCells(_ bytes: [UInt8], replacing range: Range<Int>) {
        if let edit = cellInsertion(of: bytes, replacing: range) {
            performEdit(replacing: edit.range, with: edit.bytes, bytesAfterCaret: edit.bytesAfterCaret)
        } else {
            NSSound.beep()
        }
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
