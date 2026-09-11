import AppKit

/// The list of every match below the viewport.
extension DocumentView {

    /// Shows or hides the list of every match below the viewport.
    func setResultsVisible(_ visible: Bool) {
        if visible != resultsVisible {
            resultsVisible = visible
            findBar.setResultsVisible(visible)
            layoutComponents()
            refreshResultsPanel()
            if visible && currentMatchIndex >= 0 {
                resultsPanel.select(index: currentMatchIndex)
            }
        }
    }

    func toggleSearchResults() {
        if !findBarVisible {
            showFindBar(replace: false)
        }
        setResultsVisible(!resultsVisible)
    }

    func refreshResultsPanel() {
        if resultsVisible {
            resultsPanel.update(matchCount: searchScan?.matchCount ?? 0,
                                isComplete: searchScan?.isComplete ?? true,
                                isTruncated: searchScan?.isTruncated ?? false)
        }
    }

    /// The row for match `index`, built on demand as the table scrolls.
    func resultRow(at index: Int) -> SearchResultRow? {
        var result: SearchResultRow?
        if let scan = searchScan, let document = viewport.document,
           let offset = scan.matchOffset(at: index) {
            let range = offset..<(offset + scan.matchLength(at: index))
            result = SearchResultRow.make(match: range, in: document, encoding: textEncoding)
        }
        return result
    }
}
