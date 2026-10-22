import AppKit

/// Adding and deleting whole columns under aligned CSV columns, as Numbers'
/// Table menu does. A column runs through every line, so the container
/// rewrites the file for it; the viewport only says which column.
extension ViewportView {

    @objc func addColumnBefore(_ sender: Any?) {
        requestCSVColumnInsertion(after: false)
    }

    @objc func addColumnAfter(_ sender: Any?) {
        requestCSVColumnInsertion(after: true)
    }

    /// Deletes the caret's column from every row. The table keeps at least
    /// one column, as in Numbers.
    @objc func deleteColumn(_ sender: Any?) {
        if canDeleteCSVColumn, let column = csvCaretPosition()?.column {
            onCSVColumnChange?(.removal(of: column))
        } else {
            NSSound.beep()
        }
    }

    /// Whether the caret is in a cell of a table that can be edited.
    var canEditCSVColumns: Bool {
        canEditCSVRows && csvCaretPosition() != nil
    }

    var canDeleteCSVColumn: Bool {
        var result = false
        if canEditCSVColumns, let column = csvCaretPosition()?.column, let csvColumnLayout {
            result = csvColumnLayout.columnWidths.count > 1 && column < csvColumnLayout.columnWidths.count
        }
        return result
    }

    /// Asks for an empty column before or after the caret's, as wide as it.
    private func requestCSVColumnInsertion(after: Bool) {
        if canEditCSVColumns, let column = csvCaretPosition()?.column {
            onCSVColumnChange?(.insertion(before: after ? column + 1 : column, widthOf: column))
        } else {
            NSSound.beep()
        }
    }
}
