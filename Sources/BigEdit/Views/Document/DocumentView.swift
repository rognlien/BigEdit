import AppKit

/// Container that pairs the `ViewportView` with a custom `NSScroller`, and
/// hosts the `FindBar` plus the search orchestration.
///
/// We deliberately do *not* use `NSScrollView`. Its document view would need a
/// height of `visualRowCount × lineHeight` — billions of points for a large
/// file — where AppKit's drawing precision and scroller behaviour break down.
/// Instead the scroller is driven directly over the range `0...visualRowCount`,
/// and the viewport stays a fixed size. This sidesteps the geometry problem.
final class DocumentView: NSView, FindBarDelegate, FormatBarDelegate {

    let viewport = ViewportView(frame: .zero)
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))
    let findBar = FindBar(frame: .zero)
    let resultsPanel = SearchResultsPanel(frame: .zero)
    var resultsVisible = false
    let formatBar = FormatBar(frame: .zero)
    let infoPane = InfoPane(frame: .zero)
    private let infoDivider = InfoPaneDivider(frame: .zero)
    let statusBar = StatusBar(frame: .zero)

    let editModel = EditModel()
    var fileFormat: FileFormat?

    /// Shown in the status bar while the document follows its file on disk.
    var isFollowing = false {
        didSet {
            updateStatusBar()
        }
    }

    /// The encoding the file is decoded with — UTF-8 until a format is known,
    /// and for anything the format does not decode at all.
    var textEncoding: TextEncoding {
        fileFormat?.textEncoding ?? .utf8
    }

    /// The mapped file behind the current document, kept so CSV column
    /// widths can be re-measured when an option changes.
    var mappedFile: MappedFile?

    var findBarVisible = false
    var infoPaneVisible = false

    /// Width of the info pane; resizable via its divider. Coordinated app-wide
    /// (see `onInfoPaneWidthChange`) so all documents match.
    private var infoPaneWidth = InfoPane.preferredWidth
    private static let minInfoPaneWidth: CGFloat = 180
    private static let minContentWidth: CGFloat = 300

    /// Called when the user drags the info-pane divider, so the new width can be
    /// applied to other open documents and persisted.
    var onInfoPaneWidthChange: ((CGFloat) -> Void)?
    var searchScan: SearchScan?
    var statisticsScan: StatisticsScan?
    var currentQuery = ""
    var currentMatchIndex = -1
    var jumpToFirstMatch = true
    var searchRefreshTimer: Timer?
    private var statisticsRefreshTimer: Timer?
    var replaceAllScan: SearchScan?

    let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addSubview(viewport)

        scroller.scrollerStyle = .legacy
        scroller.target = self
        scroller.action = #selector(scrollerDidChange(_:))
        addSubview(scroller)

        findBar.delegate = self
        findBar.isHidden = true
        addSubview(findBar)

        resultsPanel.isHidden = true
        resultsPanel.rowProvider = { [weak self] index in self?.resultRow(at: index) }
        resultsPanel.onSelect = { [weak self] index in self?.moveToMatch(index: index) }
        resultsPanel.onClose = { [weak self] in self?.setResultsVisible(false) }
        addSubview(resultsPanel)

        formatBar.delegate = self
        addSubview(formatBar)

        infoPane.isHidden = true
        addSubview(infoPane)

        infoDivider.isHidden = true
        infoDivider.onDrag = { [weak self] locationInWindow in
            self?.dragInfoDivider(to: locationInWindow)
        }
        addSubview(infoDivider)

        addSubview(statusBar)

        viewport.onScrollChange = { [weak self] in
            self?.syncScroller()
        }
        viewport.onSelectionChange = { [weak self] in
            self?.updateStatusBar()
        }
        viewport.onEdit = { [weak self] in
            self?.documentWasEdited()
        }
        viewport.onCSVSortRequest = { [weak self] column, descending in
            self?.sortCSV(byColumn: column, descending: descending)
        }

        layoutComponents()
    }

    required init?(coder: NSCoder) {
        fatalError("DocumentView is created programmatically")
    }

    /// Attaches a file and starts showing it. With `inheritingHistory`, the
    /// file is the one just saved from the current document, and its edit
    /// history is carried over so undo reaches back across the save.
    func load(file: MappedFile, index: LineIndex, inheritingHistory: Bool = false) {
        let previous = inheritingHistory ? viewport.document : nil
        resetSearch()
        editModel.clear()
        replaceAllScan?.cancel()
        replaceAllScan = nil
        statisticsScan?.cancel()
        statisticsScan = nil
        statisticsRefreshTimer?.invalidate()
        window?.isDocumentEdited = false
        let document: EditedDocument
        if let previous {
            document = EditedDocument(file: file, editModel: editModel, lineIndex: index,
                                      inheritingHistoryFrom: previous)
        } else {
            document = EditedDocument(file: file, editModel: editModel, lineIndex: index)
        }
        document.journal = EditJournal.open(for: file.path)
        viewport.load(document: document)
        viewport.setSyntaxMode(DocumentView.syntaxMode(for: file))
        mappedFile = file
        viewport.setCSVRendering(dialect: nil, columnLayout: nil)
        let encoding = FileFormat(scanning: file).textEncoding ?? .utf8
        formatBar.setDetectedDialect(CSVDialect.detect(in: file, encoding: encoding))
        formatBar.setMode(.text)
        layoutComponents()
        syncScroller()
        if infoPaneVisible, let document = viewport.document {
            startStatisticsScan(in: document)
        }
        updateInfoPane()
    }

    /// Redraws and re-syncs the scroller, e.g. as indexing reports progress.
    func refresh() {
        viewport.layout?.indexDidProgress()
        viewport.needsDisplay = true
        syncScroller()
        updateInfoPane()
    }

    /// The active replacement rule, if any — read by the save command.
    var currentRule: ReplacementRule? {
        return editModel.rule
    }

    /// The logical document shown in the viewport — read by the save command.
    var editedDocument: EditedDocument? {
        return viewport.document
    }

    /// True while the document has unsaved changes — positional edits or a
    /// deferred-edit rule.
    var isEdited: Bool {
        return editModel.isDirty || (viewport.document?.hasEdits ?? false)
    }

    /// Called after every positional edit: dirty state, scroller, status bar,
    /// and the info pane all depend on the content. Live search results go
    /// stale — highlights clear immediately and the search re-runs once the
    /// typing pauses.
    func documentWasEdited() {
        window?.isDocumentEdited = isEdited
        if !currentQuery.isEmpty {
            searchScan?.cancel()
            currentMatchIndex = -1
            viewport.setSearch(scan: nil, currentMatchOffset: nil)
            findBar.updateStatus("…")
            searchRefreshTimer?.invalidate()
            searchRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) {
                [weak self] _ in
                self?.refreshSearchAfterEdit()
            }
        }
        // Counts describe the edited document, so they go stale on every
        // keystroke. Re-run them after a pause rather than per character.
        if infoPaneVisible {
            statisticsScan?.cancel()
            statisticsScan = nil
            statisticsRefreshTimer?.invalidate()
            statisticsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) {
                [weak self] _ in
                self?.refreshStatisticsAfterEdit()
            }
        }
        syncScroller()
        updateStatusBar()
        updateInfoPane()
    }

    /// Recounts words and characters over the edited document once typing has
    /// paused.
    private func refreshStatisticsAfterEdit() {
        if infoPaneVisible, let document = viewport.document {
            startStatisticsScan(in: document)
        }
    }

    /// Re-runs the current query over the edited document, without jumping
    /// the viewport to the first match.
    private func refreshSearchAfterEdit() {
        if !currentQuery.isEmpty {
            startSearch(currentQuery, caseSensitive: findBar.isCaseSensitive,
                        jumpToFirstMatch: false)
        }
    }

    /// Cancels all background work for this document. Call before dropping the
    /// document so its `MappedFile` can be unmapped cleanly.
    func close() {
        resetSearch()
        replaceAllScan?.cancel()
        replaceAllScan = nil
        statisticsScan?.cancel()
        statisticsScan = nil
        statisticsRefreshTimer?.invalidate()
        editModel.clear()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutComponents()
    }

    // MARK: - Layout

    /// Places the find bar, viewport, scroller, status bar, and info pane.
    func layoutComponents() {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let findHeight = findBarVisible ? findBar.preferredHeight : 0
        let resultsHeight = resultsVisible ? SearchResultsPanel.preferredHeight : 0
        let formatHeight = formatBar.preferredHeight
        let infoWidth = infoPaneVisible ? clampedInfoWidth() : 0
        let statusHeight = StatusBar.preferredHeight
        let documentWidth = max(0, bounds.width - infoWidth)
        let contentHeight = max(0, bounds.height - findHeight - resultsHeight - formatHeight - statusHeight)
        let viewportWidth = max(0, documentWidth - scrollerWidth)
        let contentBottom = statusHeight + resultsHeight

        statusBar.frame = NSRect(x: 0, y: 0, width: documentWidth, height: statusHeight)
        resultsPanel.isHidden = !resultsVisible
        resultsPanel.frame = NSRect(x: 0, y: statusHeight, width: documentWidth, height: resultsHeight)
        viewport.frame = NSRect(x: 0, y: contentBottom, width: viewportWidth, height: contentHeight)
        scroller.frame = NSRect(x: viewportWidth, y: contentBottom, width: scrollerWidth, height: contentHeight)
        findBar.isHidden = !findBarVisible
        findBar.frame = NSRect(x: 0, y: contentBottom + contentHeight, width: documentWidth, height: findHeight)
        formatBar.frame = NSRect(x: 0, y: contentBottom + contentHeight + findHeight,
                                 width: documentWidth, height: formatHeight)
        infoPane.isHidden = !infoPaneVisible
        infoPane.frame = NSRect(x: documentWidth, y: 0, width: infoWidth, height: bounds.height)
        infoDivider.isHidden = !infoPaneVisible
        infoDivider.frame = NSRect(x: documentWidth, y: 0, width: 6, height: bounds.height)
        syncScroller()
    }

    /// The info-pane width, clamped so neither pane gets too narrow.
    private func clampedInfoWidth() -> CGFloat {
        let maxWidth = max(DocumentView.minInfoPaneWidth, bounds.width - DocumentView.minContentWidth)
        return min(max(infoPaneWidth, DocumentView.minInfoPaneWidth), maxWidth)
    }

    /// Sets the info-pane width (e.g. applied app-wide) and re-lays out.
    func setInfoPaneWidth(_ width: CGFloat) {
        infoPaneWidth = width
        layoutComponents()
    }

    private func dragInfoDivider(to locationInWindow: NSPoint) {
        let point = convert(locationInWindow, from: nil)
        infoPaneWidth = bounds.width - point.x
        infoPaneWidth = clampedInfoWidth()
        layoutComponents()
        onInfoPaneWidthChange?(infoPaneWidth)
    }

    // MARK: - Scroller

    /// Updates the scroller's knob size and position from the viewport state.
    func syncScroller() {
        let totalRows = viewport.layout?.visualRowCount ?? 0
        let perPage = viewport.rowsPerPage

        if totalRows > perPage {
            let maxScroll = viewport.maxScrollRow
            scroller.isEnabled = true
            scroller.knobProportion = CGFloat(perPage) / CGFloat(totalRows)
            scroller.doubleValue = maxScroll > 0 ? viewport.scrollRow / maxScroll : 0
        } else {
            scroller.isEnabled = false
            scroller.knobProportion = 1
            scroller.doubleValue = 0
        }
    }

    /// Translates a scroller interaction back into a viewport scroll position.
    @objc private func scrollerDidChange(_ sender: NSScroller) {
        switch sender.hitPart {
        case .knob, .knobSlot:
            viewport.setScrollRow(Double(sender.doubleValue) * viewport.maxScrollRow)
        case .decrementPage:
            viewport.scrollByPages(-1)
        case .incrementPage:
            viewport.scrollByPages(1)
        case .decrementLine:
            viewport.scrollByRows(-1)
        case .incrementLine:
            viewport.scrollByRows(1)
        default:
            break
        }
        syncScroller()
    }
}
