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
