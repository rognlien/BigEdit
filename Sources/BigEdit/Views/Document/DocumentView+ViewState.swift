import AppKit

/// Remembering how each file was shown, so reopening it shows it the same
/// way: the view mode, the CSV options and resized columns, and the chosen
/// language.
extension DocumentView {

    /// Stores the current view state under the file's path. While column
    /// changes are unsaved, the widths stored are the ones that fit the file
    /// on disk, so a document closed without saving, or a change undone,
    /// never leaves them shifted against its columns.
    func rememberViewState() {
        if unsavedColumnChanges == 0 {
            columnWidthsOnDisk = viewport.csvChosenColumnWidths
        }
        if let path = mappedFile?.path {
            let state = DocumentViewState(mode: formatBar.mode, dialect: formatBar.dialect,
                                          columnWidths: columnWidthsOnDisk,
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
