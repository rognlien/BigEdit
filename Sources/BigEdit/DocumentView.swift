import AppKit

/// Container that pairs the `ViewportView` with a custom `NSScroller`, and
/// hosts the `FindBar` plus the search orchestration.
///
/// We deliberately do *not* use `NSScrollView`. Its document view would need a
/// height of `visualRowCount × lineHeight` — billions of points for a large
/// file — where AppKit's drawing precision and scroller behaviour break down.
/// Instead the scroller is driven directly over the range `0...visualRowCount`,
/// and the viewport stays a fixed size. This sidesteps the geometry problem.
final class DocumentView: NSView, FindBarDelegate {

    let viewport = ViewportView(frame: .zero)
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 16, height: 100))
    private let findBar = FindBar(frame: .zero)
    private let infoPane = InfoPane(frame: .zero)

    private let editModel = EditModel()

    private var findBarVisible = false
    private var infoPaneVisible = false
    private var searchScan: SearchScan?
    private var statisticsScan: StatisticsScan?
    private var currentQuery = ""
    private var currentMatchIndex = -1

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        addSubview(viewport)
        viewport.setEditModel(editModel)

        scroller.scrollerStyle = .legacy
        scroller.target = self
        scroller.action = #selector(scrollerDidChange(_:))
        addSubview(scroller)

        findBar.delegate = self
        findBar.isHidden = true
        addSubview(findBar)

        infoPane.isHidden = true
        addSubview(infoPane)

        viewport.onScrollChange = { [weak self] in
            self?.syncScroller()
        }

        layoutComponents()
    }

    required init?(coder: NSCoder) {
        fatalError("DocumentView is created programmatically")
    }

    /// Attaches a file and starts showing it.
    func load(file: MappedFile, index: LineIndex) {
        resetSearch()
        editModel.clear()
        statisticsScan?.cancel()
        statisticsScan = nil
        window?.isDocumentEdited = false
        viewport.load(file: file, index: index)
        viewport.setSyntaxMode(DocumentView.syntaxMode(for: file))
        syncScroller()
        if infoPaneVisible {
            startStatisticsScan(in: file)
        }
        updateInfoPane()
    }

    /// Redraws and re-syncs the scroller, e.g. as indexing reports progress.
    func refresh() {
        viewport.needsDisplay = true
        syncScroller()
        updateInfoPane()
    }

    /// The active replacement rule, if any — read by the save command.
    var currentRule: ReplacementRule? {
        return editModel.rule
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutComponents()
    }

    // MARK: - Layout

    /// Places the find bar, viewport, scroller, and info pane.
    private func layoutComponents() {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let findHeight = findBarVisible ? findBar.preferredHeight : 0
        let infoWidth = infoPaneVisible ? InfoPane.preferredWidth : 0
        let contentHeight = max(0, bounds.height - findHeight)
        let documentWidth = max(0, bounds.width - infoWidth)
        let viewportWidth = max(0, documentWidth - scrollerWidth)

        findBar.isHidden = !findBarVisible
        findBar.frame = NSRect(x: 0, y: contentHeight, width: documentWidth, height: findHeight)
        viewport.frame = NSRect(x: 0, y: 0, width: viewportWidth, height: contentHeight)
        scroller.frame = NSRect(x: viewportWidth, y: 0, width: scrollerWidth, height: contentHeight)
        infoPane.isHidden = !infoPaneVisible
        infoPane.frame = NSRect(x: documentWidth, y: 0, width: infoWidth, height: bounds.height)
        syncScroller()
    }

    // MARK: - Scroller

    /// Updates the scroller's knob size and position from the viewport state.
    private func syncScroller() {
        let totalRows = viewport.index?.visualRowCount ?? 0
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

    // MARK: - Find bar

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
        if findBarVisible {
            findBarVisible = false
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

    func findBar(_ bar: FindBar, didRequestReplaceAll pattern: String, with replacement: String) {
        if let rule = ReplacementRule(pattern: pattern, replacement: replacement),
           let file = viewport.file {
            editModel.setRule(rule, file: file) { [weak self] in
                self?.editScanDidProgress()
            }
            viewport.needsDisplay = true
            updateEditStatus()
        } else {
            findBar.updateReplaceStatus("Invalid pattern")
        }
    }

    func findBarRequestedRevert(_ bar: FindBar) {
        editModel.clear()
        viewport.needsDisplay = true
        updateEditStatus()
    }

    // MARK: - Deferred edit

    /// Called on the main queue as the replacement scan finds more occurrences.
    private func editScanDidProgress() {
        viewport.needsDisplay = true
        updateEditStatus()
    }

    /// Reflects the rule's occurrence count and marks the window edited.
    private func updateEditStatus() {
        window?.isDocumentEdited = editModel.isDirty

        var text = ""
        if editModel.rule != nil, let matches = editModel.matches {
            let count = matches.matchCount
            let total = matches.isTruncated ? "\(count)+" : "\(count)"
            let progress = matches.isComplete ? "" : "…"
            text = "\(total) replaced\(progress)"
        }
        findBar.updateReplaceStatus(text)
    }

    // MARK: - Go to Line

    /// Asks the user for a line number and scrolls the viewport to it.
    func showGoToLineSheet() {
        guard let index = viewport.index, let file = viewport.file, index.count > 0,
              let parentWindow = window else {
            return
        }

        let formattedCount = numberFormatter.string(from: NSNumber(value: index.count))
            ?? "\(index.count)"
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Line number (1 – \(formattedCount))"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "e.g. 1234"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: parentWindow) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.scrollToEnteredLine(field.stringValue, in: file, index: index)
            }
        }
    }

    private func scrollToEnteredLine(_ text: String, in file: MappedFile, index: LineIndex) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let entered = Int(trimmed), entered > 0 {
            let targetLine = min(entered - 1, index.count - 1)
            let row = index.visualRow(forDocumentLine: targetLine, file: file)
            viewport.scrollToRow(row)
        }
    }

    // MARK: - Info pane

    var isInfoPaneVisible: Bool {
        infoPaneVisible
    }

    func toggleInfoPane() {
        if infoPaneVisible {
            hideInfoPane()
        } else {
            showInfoPane()
        }
    }

    func showInfoPane() {
        infoPaneVisible = true
        if statisticsScan == nil, let file = viewport.file {
            startStatisticsScan(in: file)
        }
        layoutComponents()
        updateInfoPane()
    }

    func hideInfoPane() {
        infoPaneVisible = false
        layoutComponents()
    }

    /// Kicks off the background word / character count for `file`.
    private func startStatisticsScan(in file: MappedFile) {
        let scan = StatisticsScan()
        statisticsScan = scan
        scan.start(in: file) { [weak self, weak scan] in
            if let self, let scan, self.statisticsScan === scan {
                self.updateInfoPane()
            }
        }
    }

    /// Refreshes the info pane fields from the file, the index, and the
    /// stats scan.
    private func updateInfoPane() {
        guard infoPaneVisible || statisticsScan != nil else {
            return
        }
        if let file = viewport.file {
            let url = URL(fileURLWithPath: file.path)
            infoPane.setName(url.lastPathComponent)
            infoPane.setType(DocumentView.fileTypeDescription(for: file))
            infoPane.setSize(formatSize(file.size))

            if let index = viewport.index {
                let count = numberFormatter.string(from: NSNumber(value: index.count)) ?? "\(index.count)"
                let suffix = index.isComplete ? "" : " (indexing…)"
                infoPane.setLines("\(count)\(suffix)")
            } else {
                infoPane.setLines("—")
            }

            if let stats = statisticsScan {
                let words = numberFormatter.string(from: NSNumber(value: stats.wordCount)) ?? "\(stats.wordCount)"
                let chars = numberFormatter.string(from: NSNumber(value: stats.characterCount)) ?? "\(stats.characterCount)"
                let suffix = stats.isComplete ? "" : " (\(Int(stats.progress * 100))%)"
                infoPane.setWords("\(words)\(suffix)")
                infoPane.setCharacters("\(chars)\(suffix)")
            } else {
                infoPane.setWords("—")
                infoPane.setCharacters("—")
            }
        } else {
            infoPane.clear()
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        let humanReadable = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let exact = numberFormatter.string(from: NSNumber(value: bytes)) ?? "\(bytes)"
        return "\(humanReadable) (\(exact) bytes)"
    }

    private static func fileTypeDescription(for file: MappedFile) -> String {
        let fileExtension = (file.path as NSString).pathExtension
        if fileExtension.isEmpty {
            return "Plain text"
        }
        return fileExtension.uppercased()
    }

    /// Picks a syntax mode from the file extension, falling back to a content
    /// sniff that looks at the first non-whitespace byte (`<` → XML, `{` or
    /// `[` → JSON).
    private static func syntaxMode(for file: MappedFile) -> SyntaxMode {
        let xmlExtensions: Set<String> = [
            "xml", "svg", "xhtml", "html", "htm", "plist",
            "rss", "atom", "xsd", "xsl", "xslt", "pom"
        ]
        let jsonExtensions: Set<String> = [
            "json", "jsonl", "ndjson", "geojson", "har", "jsonc"
        ]
        let markdownExtensions: Set<String> = [
            "md", "markdown", "mdown", "mkd", "mdx"
        ]
        let yamlExtensions: Set<String> = ["yaml", "yml"]
        var mode = SyntaxMode.plain
        let fileExtension = (file.path as NSString).pathExtension.lowercased()
        if xmlExtensions.contains(fileExtension) {
            mode = .xml
        } else if jsonExtensions.contains(fileExtension) {
            mode = .json
        } else if markdownExtensions.contains(fileExtension) {
            mode = .markdown
        } else if yamlExtensions.contains(fileExtension) {
            mode = .yaml
        } else if let leadingByte = firstNonWhitespaceByte(file) {
            if leadingByte == 0x3C {                            // '<'
                mode = .xml
            } else if leadingByte == 0x7B || leadingByte == 0x5B {  // '{' or '['
                mode = .json
            }
        }
        return mode
    }

    /// The first non-whitespace byte of `file`, skipping a UTF-8 BOM. Returns
    /// `nil` if the file is empty or contains only whitespace in the sniffed
    /// prefix.
    private static func firstNonWhitespaceByte(_ file: MappedFile) -> UInt8? {
        var result: UInt8?
        let buffer = file.buffer
        let limit = min(buffer.count, 256)
        var index = 0
        while index < limit {
            let byte = buffer[index]
            let isSkippable = byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
                || byte == 0xEF || byte == 0xBB || byte == 0xBF  // whitespace or UTF-8 BOM
            if isSkippable {
                index += 1
            } else {
                result = byte
                break
            }
        }
        return result
    }

    // MARK: - Search

    /// Cancels any running search and clears match state.
    private func resetSearch() {
        searchScan?.cancel()
        searchScan = nil
        currentQuery = ""
        currentMatchIndex = -1
        viewport.setSearch(scan: nil, currentMatchOffset: nil)
        findBar.updateStatus("")
    }

    /// Starts a fresh background search for `query`.
    private func startSearch(_ query: String, caseSensitive: Bool) {
        searchScan?.cancel()
        currentQuery = query
        currentMatchIndex = -1

        if let file = viewport.file,
           let scan = SearchScan(query: query, caseSensitive: caseSensitive) {
            searchScan = scan
            viewport.setSearch(scan: scan, currentMatchOffset: nil)
            findBar.updateStatus("Searching…")
            scan.start(in: file) { [weak self, weak scan] in
                if let self, let scan, self.searchScan === scan {
                    self.searchDidProgress(scan)
                }
            }
        } else {
            resetSearch()
        }
    }

    /// Called on the main queue as matches accumulate.
    private func searchDidProgress(_ scan: SearchScan) {
        if currentMatchIndex == -1 && scan.matchCount > 0 {
            moveToMatch(index: 0)  // Jump to the first match once results appear.
        } else {
            viewport.needsDisplay = true
            updateMatchStatus()
        }
    }

    /// Selects match `index`, scrolls it into view, and emphasises it.
    private func moveToMatch(index: Int) {
        if let scan = searchScan,
           let offset = scan.matchOffset(at: index),
           let file = viewport.file,
           let lineIndex = viewport.index {
            currentMatchIndex = index
            let row = lineIndex.visualRow(forByteOffset: offset, file: file)
            viewport.setSearch(scan: scan, currentMatchOffset: offset)
            viewport.scrollToRow(row)
            updateMatchStatus()
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
