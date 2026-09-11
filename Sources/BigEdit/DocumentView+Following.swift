import AppKit

extension DocumentView {

    /// Whether the document can absorb appends: only a clean document, since
    /// the piece table addresses the original mapping and an append would
    /// have to be spliced in behind every edit.
    var canFollow: Bool {
        viewport.document?.hasEdits != true && editModel.rule == nil
    }

    /// Replaces the mapping with `grown` — the same file with bytes appended,
    /// whose index has already been extended — keeping the scroll position and
    /// selection and re-running the search and statistics over the new bytes.
    ///
    /// `pinToEnd` says whether the view was at the end *before* the index grew.
    /// The caller decides that, because once the index is extended the old
    /// document's layout already reports the new row count and the view no
    /// longer looks scrolled to the end of anything.
    func adoptGrownFile(_ grown: MappedFile, index: LineIndex, pinToEnd: Bool) {
        let document = EditedDocument(file: grown, editModel: editModel, lineIndex: index)
        mappedFile = grown
        viewport.replaceDocumentKeepingPosition(document)
        setFileFormat(fileFormat)
        syncScroller()
        if pinToEnd {
            viewport.setScrollRow(viewport.maxScrollRow)
        }
        if !currentQuery.isEmpty {
            startSearch(currentQuery, caseSensitive: findBar.isCaseSensitive,
                        jumpToFirstMatch: false)
        }
        if infoPaneVisible {
            statisticsScan?.cancel()
            startStatisticsScan(in: document)
        }
        updateInfoPane()
        updateStatusBar()
    }
}
