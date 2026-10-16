import AppKit

/// Remembering how each file was shown, so reopening it shows it the same
/// way: the view mode, the CSV options and resized columns, and the chosen
/// language.
extension DocumentView {

    /// Stores the current view state under the file's path.
    func rememberViewState() {
        if let path = mappedFile?.path {
            let state = DocumentViewState(mode: formatBar.mode, dialect: formatBar.dialect,
                                          columnWidths: viewport.csvChosenColumnWidths,
                                          language: chosenLanguage)
            viewStateStore.store(state, forPath: path)
        }
    }

    /// Shows the file the way it was last shown, when that was remembered.
    func restoreViewState(for file: MappedFile) {
        if let state = viewStateStore.state(forPath: file.path) {
            if let language = state.chosenLanguage {
                chooseLanguage(language)
            }
            if state.viewMode == .csv, let dialect = state.dialect {
                formatBar.setDetectedDialect(dialect)
            }
            formatBar.setMode(state.viewMode)
            formatBar(formatBar, didSelect: formatBar.mode)
            viewport.applyCSVChosenColumnWidths(state.columnWidths)
            rememberViewState()
        }
    }
}
