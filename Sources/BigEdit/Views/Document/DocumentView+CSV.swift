import AppKit

extension DocumentView {

    /// Applies the chosen view mode: plain text, or delimited data drawn as
    /// aligned columns.
    func formatBar(_ bar: FormatBar, didSelect mode: FormatBar.Mode) {
        applyCSVRendering(enabled: mode == .csv, dialect: bar.dialect)
    }

    /// Re-measures the columns when an option changes, since a different
    /// delimiter, quote, or trim setting moves every field boundary.
    func formatBar(_ bar: FormatBar, didChange dialect: CSVDialect) {
        applyCSVRendering(enabled: bar.mode == .csv, dialect: dialect)
    }

    /// Sorts the table by `column` as one undoable edit. With `descending`
    /// nil — a header click — the direction toggles when the column is
    /// already the sorted one, and is ascending otherwise.
    func sortCSV(byColumn column: Int, descending: Bool?) {
        guard let dialect = viewport.csvDialect else {
            return
        }
        let current = viewport.csvSortIndicator
        let direction = descending ?? (current?.column == column && current?.descending == false)
        rewriteLines(title: "Sorting by \(viewport.csvColumnTitle(column))…",
                     completion: { [weak self] result in
                         self?.finishCSVSort(result, column: column, descending: direction)
                     },
                     transform: { lines, isCancelled in
                         CSVSorter.sorted(lines, byColumn: column, dialect: dialect,
                                          descending: direction, isCancelled: isCancelled)
                     })
    }

    private func finishCSVSort(_ result: Result<Int, Error>, column: Int, descending: Bool) {
        switch result {
        case .success:
            viewport.setCSVSortIndicator(column: column, descending: descending)
            viewport.setScrollRow(0)
        case .failure(let error):
            presentCSVSortFailure(error)
        }
    }

    private func presentCSVSortFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        switch error {
        case ProcessLinesRefusal.tooLarge(let size, let limit):
            let formatter = ByteCountFormatter()
            alert.messageText = "This table is too large to sort"
            alert.informativeText = "Sorting holds every line in memory, so it is limited to "
                + "\(formatter.string(fromByteCount: Int64(limit))). This file is "
                + "\(formatter.string(fromByteCount: Int64(size)))."
        default:
            alert.messageText = "This table cannot be sorted"
            alert.informativeText = "Sorting rewrites the file, which is not possible for a file "
                + "that is not UTF-8 text or while a replacement rule is active."
        }
        alert.runModal()
    }

    private func applyCSVRendering(enabled: Bool, dialect: CSVDialect) {
        var columnLayout: CSVColumnLayout?
        if enabled, let mappedFile {
            columnLayout = CSVColumnLayout.measure(file: mappedFile, dialect: dialect,
                                                   encoding: textEncoding)
        }
        viewport.setCSVRendering(dialect: enabled ? dialect : nil, columnLayout: columnLayout)
        layoutComponents()
        viewport.needsDisplay = true
        updateStatusBar()
    }
}
