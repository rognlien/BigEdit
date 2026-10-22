import AppKit

/// Adding and deleting a column on every row. The whole file is rewritten
/// in memory, so it shares the Process Lines ceiling, and lands as one
/// undoable edit.
extension DocumentView {

    func changeCSVColumns(_ change: CSVColumnChange) {
        if let document = viewport.document, document.length > DocumentView.processLinesSizeLimit {
            presentCSVColumnRefusal(change, size: document.length)
        } else if let document = viewport.document, let dialect = viewport.csvDialect,
                  let caret = viewport.csvCaretPosition() {
            rewriteCSVColumns(change, of: document, dialect: dialect, caretRow: caret.row)
        } else {
            NSSound.beep()
        }
    }

    /// Runs the rewrite off the main thread behind a cancellable progress
    /// sheet, then applies it.
    private func rewriteCSVColumns(_ change: CSVColumnChange, of document: EditedDocument,
                                   dialect: CSVDialect, caretRow: Int) {
        let sheet = SaveProgressSheet(title: progressTitle(for: change))
        let cancelled = CancelToken()
        sheet.onCancel = { cancelled.cancel() }
        sheet.setProgress(0)
        window?.beginSheet(sheet.window) { _ in }

        let bytes = document.bytes(in: 0..<document.length)
        let encoding = textEncoding
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rewritten = CSVColumnEditing.applying(change, to: bytes, dialect: dialect, encoding: encoding,
                                                      isCancelled: { cancelled.isCancelled })
            DispatchQueue.main.async {
                self?.window?.endSheet(sheet.window)
                if let rewritten {
                    self?.finishCSVColumnChange(change, with: rewritten, caretRow: caretRow)
                }
            }
        }
    }

    private func progressTitle(for change: CSVColumnChange) -> String {
        var title = "Adding a column…"
        if case .removal(let column) = change {
            title = "Deleting “\(viewport.csvColumnTitle(column))”…"
        }
        return title
    }

    /// Applies the rewritten table, measures its columns again with every
    /// resized width moved along with its column, and selects the added
    /// column's cell, or the one now where the deleted column was.
    private func finishCSVColumnChange(_ change: CSVColumnChange, with bytes: [UInt8], caretRow: Int) {
        if let dialect = viewport.csvDialect, let widthsBefore = viewport.csvColumnWidths {
            let widths = DocumentView.chosenWidths(viewport.csvChosenColumnWidths, after: change,
                                                   current: widthsBefore.working.columnWidths)
            let scrollRow = viewport.scrollRow
            viewport.replaceEntireTable(with: bytes)
            applyCSVRendering(enabled: true, dialect: dialect)
            viewport.applyCSVChosenColumnWidths(widths)
            if let widthsAfter = viewport.csvColumnWidths {
                viewport.document?.undoStack.attachCompanion(
                    CSVColumnWidthChange(before: widthsBefore, after: widthsAfter))
            }
            viewport.setScrollRow(scrollRow)
            viewport.moveToCell(inRow: caretRow, column: .index(selectedColumn(after: change)))
            rememberViewState()
        }
    }

    private func selectedColumn(after change: CSVColumnChange) -> Int {
        var column: Int
        switch change {
        case .insertion(let before, _):
            column = before
        case .removal(let removed):
            column = min(removed, max(0, (viewport.csvColumnLayout?.columnWidths.count ?? 1) - 1))
        }
        return column
    }

    /// The resized widths, keyed by column, moved to where their columns
    /// are after `change`. An added column takes the current width of the
    /// one it was added beside, as Numbers copies that column's format.
    static func chosenWidths(_ chosen: [Int: Int], after change: CSVColumnChange, current: [Int]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        switch change {
        case .insertion(let before, let source):
            for (column, width) in chosen {
                result[column < before ? column : column + 1] = width
            }
            if source < current.count {
                result[before] = current[source]
            }
        case .removal(let removed):
            for (column, width) in chosen where column != removed {
                result[column < removed ? column : column - 1] = width
            }
        }
        return result
    }

    private func presentCSVColumnRefusal(_ change: CSVColumnChange, size: Int) {
        let formatter = ByteCountFormatter()
        var action = "delete a column from"
        if case .insertion = change {
            action = "add a column to"
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.messageText = "This table is too large to \(action)"
        alert.informativeText = "A column runs through every row, so changing one rewrites the file in "
            + "memory, which is limited to "
            + "\(formatter.string(fromByteCount: Int64(DocumentView.processLinesSizeLimit))). This file is "
            + "\(formatter.string(fromByteCount: Int64(size))). Rows can still be added and deleted."
        alert.runModal()
    }
}
