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

    /// Deletes every row the selection touches, as one undoable edit, and
    /// puts the caret at the start of the row that takes their place. Not
    /// the header row, which names the columns.
    @objc func deleteRow(_ sender: Any?) {
        if canDeleteCSVRows, let rows = selectedCSVRows() {
            document?.undoStack.breakCoalescing()
            csvCaretColumn = nil
            performEdit(replacing: rowsWithTheirSeparator(rows), with: [])
            let caret = lineContentRange(containing: selection?.activeOffset ?? 0).lowerBound
            selection = TextSelection(anchorOffset: caret, activeOffset: caret)
        } else {
            NSSound.beep()
        }
    }

    /// The empty row drawn after a final line ending is not in the file, so
    /// there is nothing to delete there.
    var canDeleteCSVRows: Bool {
        canEditCSVRows && !selectionTouchesCSVHeader && selectedCSVRows()?.isEmpty == false
    }

    /// Whether the selection touches more than one row.
    var selectionSpansCSVRows: Bool {
        var result = false
        if let rows = selectedCSVRows(), let layout {
            result = layout.logicalLineRange(containing: rows.lowerBound).upperBound < rows.upperBound
        }
        return result
    }

    /// `rows` with the line ending that separates them from the rest: their
    /// own last one, or, when they end the file without one, the ending of
    /// the row before, so that row becomes the last.
    private func rowsWithTheirSeparator(_ rows: Range<Int>) -> Range<Int> {
        var result = rows
        if let document, rows.lowerBound > 0, rows.upperBound == document.length,
           document.byte(at: rows.upperBound - 1) != 0x0A {
            result = lineContentRange(containing: rows.lowerBound - 1).upperBound..<rows.upperBound
        }
        return result
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

    /// The table commands, in Numbers' order, after the clipboard ones of a
    /// cell's context menu.
    func addCSVTableItems(to menu: NSMenu) {
        if isCSVRenderingActive {
            menu.addItem(NSMenuItem.separator())
            ViewportView.csvTableItems(includingShortcuts: false).forEach(menu.addItem)
        }
    }

    /// The items of the Table menu, which the context menu repeats without
    /// their shortcuts. They go up the responder chain to the viewport.
    static func csvTableItems(includingShortcuts: Bool) -> [NSMenuItem] {
        let deleteRowItem = NSMenuItem(title: "Delete Row", action: #selector(deleteRow(_:)),
                                       keyEquivalent: includingShortcuts ? "\u{8}" : "")
        deleteRowItem.keyEquivalentModifierMask = [.command, .option]
        return [
            NSMenuItem(title: "Add Row Above", action: #selector(addRowAbove(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Add Row Below", action: #selector(addRowBelow(_:)), keyEquivalent: ""),
            NSMenuItem.separator(),
            deleteRowItem
        ]
    }

    /// A right-click on a cell outside the selection puts the caret there
    /// first, as Numbers selects the cell it opens the menu on, so the row
    /// commands act on the row clicked.
    func placeCaretForCSVContextMenu(at point: NSPoint) {
        if isCSVRenderingActive, point.y >= pinnedHeaderHeight {
            let offset = byteOffset(at: point)
            let isInSelection = selection.map { $0.range.contains(offset) || $0.range.upperBound == offset } ?? false
            if !isInSelection {
                selection = TextSelection(anchorOffset: offset, activeOffset: offset)
                csvCaretColumn = csvVirtualColumn(at: point)
                needsDisplay = true
            }
        }
    }
}
