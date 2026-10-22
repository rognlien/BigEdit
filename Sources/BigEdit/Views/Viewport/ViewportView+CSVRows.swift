import AppKit

/// Adding and deleting whole rows under aligned CSV columns, as Numbers'
/// Table menu does. A row is a line of the file, so each command is one
/// positional edit, whatever the file's size.
extension ViewportView {

    /// Inserts an empty row above the caret's row and puts the caret in its
    /// first cell. Not above a header row, which stays the first line.
    @objc func addRowAbove(_ sender: Any?) {
        if canAddCSVRowAbove, let row = selectedCSVRows() {
            let newline = document?.newlineBytes ?? [0x0A]
            let bytes = emptyCSVRow() + newline
            insertCSVRow(bytes, at: row.lowerBound, bytesAfterCaret: bytes.count)
        } else {
            NSSound.beep()
        }
    }

    /// Inserts an empty row below the caret's row and puts the caret in its
    /// first cell. The new row goes after the row's content, so a last row
    /// without a line ending gets one and the new row ends the file as the
    /// old one did.
    @objc func addRowBelow(_ sender: Any?) {
        if canEditCSVRows, let caret = selection?.activeOffset {
            let newline = document?.newlineBytes ?? [0x0A]
            let row = emptyCSVRow()
            insertCSVRow(newline + row, at: lineContentRange(containing: caret).upperBound,
                         bytesAfterCaret: row.count)
        } else {
            NSSound.beep()
        }
    }

    /// Whether the row commands apply: the table is drawn as columns, it
    /// can be edited, and there is a caret to say which row.
    var canEditCSVRows: Bool {
        isCSVRenderingActive && isEditingAllowed && selection != nil
    }

    /// A header row names the columns, so nothing goes above it.
    var canAddCSVRowAbove: Bool {
        canEditCSVRows && !selectionTouchesCSVHeader
    }

    /// Whether the selection reaches the header row.
    var selectionTouchesCSVHeader: Bool {
        csvDialect?.hasHeaderRow == true && selectedCSVRows()?.lowerBound == 0
    }

    /// The whole lines the selection touches, endings included. A selection
    /// ending at the start of a line does not touch that line.
    func selectedCSVRows() -> Range<Int>? {
        var result: Range<Int>?
        if let selection, let layout {
            let range = selection.range
            let last = range.isEmpty ? range.lowerBound : range.upperBound - 1
            result = layout.logicalLineRange(containing: range.lowerBound).lowerBound
                ..< layout.logicalLineRange(containing: last).upperBound
        }
        return result
    }

    /// A row with as many empty cells as the table has columns.
    private func emptyCSVRow() -> [UInt8] {
        var result: [UInt8] = []
        if let csvDialect, let delimiter = textEncoding.encode(String(csvDialect.delimiter)) {
            let columnCount = max(1, csvColumnLayout?.columnWidths.count ?? 1)
            result = Array(repeating: delimiter, count: columnCount - 1).flatMap { $0 }
        }
        return result
    }

    /// Inserts `bytes` at `offset` as an undoable edit of its own, leaving
    /// the caret `bytesAfterCaret` before their end.
    private func insertCSVRow(_ bytes: [UInt8], at offset: Int, bytesAfterCaret: Int) {
        document?.undoStack.breakCoalescing()
        csvCaretColumn = nil
        performEdit(replacing: offset..<offset, with: bytes, bytesAfterCaret: bytesAfterCaret)
        document?.undoStack.breakCoalescing()
    }
}
