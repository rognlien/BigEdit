import AppKit

/// The find bar, the search it drives, and moving between matches.
extension DocumentView {

    /// Shows the find bar (if hidden) and focuses the search field. When
    /// `replace` is true the bar shows its replacement row.
    func showFindBar(replace: Bool) {
        findBar.mode = replace ? .findAndReplace : .find
        findBarVisible = true
        layoutComponents()
        findBar.focusSearchField()
    }

    /// Hides the find bar and clears the active search.
    func hideFindBar() {
        if findBarVisible || resultsVisible {
            findBarVisible = false
            resultsVisible = false
            findBar.setResultsVisible(false)
            layoutComponents()
        }
        resetSearch()
        window?.makeFirstResponder(viewport)
    }

    func findNext() {
        if let scan = searchScan, scan.matchCount > 0 {
            let count = scan.matchCount
            let next = currentMatchIndex + 1 >= count ? 0 : currentMatchIndex + 1
            moveToMatch(index: next)
        }
    }

    func findPrevious() {
        if let scan = searchScan, scan.matchCount > 0 {
            let count = scan.matchCount
            let previous = currentMatchIndex <= 0 ? count - 1 : currentMatchIndex - 1
            moveToMatch(index: previous)
        }
    }

    // MARK: - FindBarDelegate

    func findBar(_ bar: FindBar, didSubmitQuery query: String) {
        if query.isEmpty {
            resetSearch()
        } else {
            let caseSensitive = bar.isCaseSensitive
            let modeChanged = searchScan?.caseSensitive != caseSensitive
                || searchScan?.isRegularExpression != bar.isRegularExpression
            if query != currentQuery || modeChanged {
                startSearch(query, caseSensitive: caseSensitive)
            } else {
                let goPrevious = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if goPrevious {
                    findPrevious()
                } else {
                    findNext()
                }
            }
        }
    }

    func findBarRequestedNext(_ bar: FindBar) {
        findNext()
    }

    func findBarRequestedPrevious(_ bar: FindBar) {
        findPrevious()
    }

    func findBarRequestedClose(_ bar: FindBar) {
        hideFindBar()
    }

    func findBarRequestedResultsToggle(_ bar: FindBar) {
        setResultsVisible(!resultsVisible)
    }

    /// Called on the main queue as the replacement scan finds more occurrences.
    func editScanDidProgress() {
        viewport.needsDisplay = true
        updateEditStatus()
    }

    /// Reflects the rule's occurrence count and marks the window edited.
    func updateEditStatus() {
        window?.isDocumentEdited = isEdited

        var text = ""
        if editModel.rule != nil, let matches = editModel.matches {
            let count = matches.matchCount
            let total = matches.isTruncated ? "\(count)+" : "\(count)"
            let progress = matches.isComplete ? "" : "…"
            text = "\(total) replaced\(progress)"
        }
        findBar.updateReplaceStatus(text)
    }

    /// Cancels any running search and clears match state.
    func resetSearch() {
        searchRefreshTimer?.invalidate()
        searchRefreshTimer = nil
        searchScan?.cancel()
        searchScan = nil
        currentQuery = ""
        currentMatchIndex = -1
        viewport.setSearch(scan: nil, currentMatchOffset: nil)
        findBar.updateStatus("")
        refreshResultsPanel()
    }

    /// Starts a fresh background search for `query` over the logical
    /// document (through the piece table when there are unsaved edits).
    func startSearch(_ query: String, caseSensitive: Bool,
                             jumpToFirstMatch: Bool = true) {
        searchScan?.cancel()
        currentQuery = query
        currentMatchIndex = -1
        self.jumpToFirstMatch = jumpToFirstMatch

        if let document = viewport.document,
           let scan = makeSearchScan(query, caseSensitive: caseSensitive) {
            searchScan = scan
            viewport.setSearch(scan: scan, currentMatchOffset: nil)
            findBar.updateStatus("Searching…")
            scan.start(in: document) { [weak self, weak scan] in
                if let self, let scan, self.searchScan === scan {
                    self.searchDidProgress(scan)
                }
            }
        } else {
            resetSearch()
            if findBar.isRegularExpression && !query.isEmpty {
                findBar.updateStatus("Invalid pattern")
            }
        }
    }

    /// A scan in whichever mode the find bar is set to. `nil` for an empty
    /// query — or, in regular-expression mode, for a pattern that does not
    /// compile.
    func makeSearchScan(_ query: String, caseSensitive: Bool) -> SearchScan? {
        findBar.isRegularExpression
            ? SearchScan(regularExpression: query, caseSensitive: caseSensitive,
                         encoding: textEncoding)
            : SearchScan(query: query, caseSensitive: caseSensitive, encoding: textEncoding)
    }

    /// Called on the main queue as matches accumulate.
    private func searchDidProgress(_ scan: SearchScan) {
        if currentMatchIndex == -1 && scan.matchCount > 0 && jumpToFirstMatch {
            moveToMatch(index: 0)  // Jump to the first match once results appear.
        } else {
            viewport.needsDisplay = true
            updateMatchStatus()
        }
        refreshResultsPanel()
    }

    /// Selects match `index`, scrolls it into view, and emphasises it.
    func moveToMatch(index: Int) {
        if let scan = searchScan,
           let offset = scan.matchOffset(at: index),
           let layout = viewport.layout {
            currentMatchIndex = index
            let row = layout.visualRow(forLogicalByteOffset: offset)
            viewport.setSearch(scan: scan, currentMatchOffset: offset)
            viewport.scrollToRow(row)
            updateMatchStatus()
            if resultsVisible {
                resultsPanel.select(index: index)
            }
        }
    }

    /// Refreshes the find bar's result-count text, including a percentage
    /// while the scan is still in progress (so it's clearly *moving* even
    /// when no matches have been found yet).
    private func updateMatchStatus() {
        var text = ""
        if let scan = searchScan {
            let count = scan.matchCount
            if count == 0 {
                if scan.isComplete {
                    text = "Not found"
                } else {
                    text = "Searching… \(Int(scan.scanProgress * 100))%"
                }
            } else {
                let position = currentMatchIndex >= 0 ? "\(currentMatchIndex + 1) of " : ""
                let total = scan.isTruncated ? "\(count)+" : "\(count)"
                let progress = scan.isComplete ? "" : " — \(Int(scan.scanProgress * 100))%"
                text = "\(position)\(total)\(progress)"
            }
        }
        findBar.updateStatus(text)
    }
}
