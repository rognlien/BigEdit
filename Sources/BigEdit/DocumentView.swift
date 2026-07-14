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
    private let infoDivider = InfoPaneDivider(frame: .zero)
    private let statusBar = StatusBar(frame: .zero)

    private let editModel = EditModel()
    private var fileFormat: FileFormat?

    private var findBarVisible = false
    private var infoPaneVisible = false

    /// Width of the info pane; resizable via its divider. Coordinated app-wide
    /// (see `onInfoPaneWidthChange`) so all documents match.
    private var infoPaneWidth = InfoPane.preferredWidth
    private static let minInfoPaneWidth: CGFloat = 180
    private static let minContentWidth: CGFloat = 300

    /// Called when the user drags the info-pane divider, so the new width can be
    /// applied to other open documents and persisted.
    var onInfoPaneWidthChange: ((CGFloat) -> Void)?
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

        scroller.scrollerStyle = .legacy
        scroller.target = self
        scroller.action = #selector(scrollerDidChange(_:))
        addSubview(scroller)

        findBar.delegate = self
        findBar.isHidden = true
        addSubview(findBar)

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
        viewport.load(document: EditedDocument(file: file, editModel: editModel, lineIndex: index))
        viewport.setSyntaxMode(DocumentView.syntaxMode(for: file))
        syncScroller()
        if infoPaneVisible {
            startStatisticsScan(in: file)
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
    /// and the info pane all depend on the content; live search results are
    /// stale and cleared (searching an edited document arrives in a later
    /// stage).
    private func documentWasEdited() {
        window?.isDocumentEdited = isEdited
        if searchScan != nil {
            searchScan?.cancel()
            searchScan = nil
            currentMatchIndex = -1
            currentQuery = ""
            viewport.setSearch(scan: nil, currentMatchOffset: nil)
            findBar.updateStatus("Edited — search again to refresh")
        }
        syncScroller()
        updateStatusBar()
        updateInfoPane()
    }

    /// Cancels all background work for this document. Call before dropping the
    /// document so its `MappedFile` can be unmapped cleanly.
    func close() {
        resetSearch()
        statisticsScan?.cancel()
        statisticsScan = nil
        editModel.clear()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutComponents()
    }

    // MARK: - Layout

    /// Places the find bar, viewport, scroller, status bar, and info pane.
    private func layoutComponents() {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let findHeight = findBarVisible ? findBar.preferredHeight : 0
        let infoWidth = infoPaneVisible ? clampedInfoWidth() : 0
        let statusHeight = StatusBar.preferredHeight
        let documentWidth = max(0, bounds.width - infoWidth)
        let contentHeight = max(0, bounds.height - findHeight - statusHeight)
        let viewportWidth = max(0, documentWidth - scrollerWidth)

        statusBar.frame = NSRect(x: 0, y: 0, width: documentWidth, height: statusHeight)
        viewport.frame = NSRect(x: 0, y: statusHeight, width: viewportWidth, height: contentHeight)
        scroller.frame = NSRect(x: viewportWidth, y: statusHeight, width: scrollerWidth, height: contentHeight)
        findBar.isHidden = !findBarVisible
        findBar.frame = NSRect(x: 0, y: statusHeight + contentHeight, width: documentWidth, height: findHeight)
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

    // MARK: - Status bar

    /// Sets the detected format (encoding / line endings) shown on the right,
    /// and derives editability from it: only UTF-8 / ASCII text accepts
    /// positional edits, and Return inserts the detected line ending.
    func setFileFormat(_ format: FileFormat?) {
        fileFormat = format
        if let document = viewport.document {
            document.isEditable = format?.isUTF8 ?? false
            document.newlineBytes = format?.lineEnding == "CRLF" ? [0x0D, 0x0A] : [0x0A]
        }
        updateStatusBar()
    }

    private func updateStatusBar() {
        var left = ""
        if let document = viewport.document, let layout = viewport.layout, document.length > 0,
           let caret = viewport.caretByteOffset {
            let row = layout.visualRow(forLogicalByteOffset: caret)
            let line = layout.visualLines(forRows: row..<(row + 1)).first
            let lineNumber = (line?.documentLine ?? 0) + 1
            let lineText = numberFormatter.string(from: NSNumber(value: lineNumber)) ?? "\(lineNumber)"
            let offset = numberFormatter.string(from: NSNumber(value: caret)) ?? "\(caret)"
            left = "Ln \(lineText)  ·  Offset \(offset)"
            if let range = viewport.selectionByteRange {
                let bytes = numberFormatter.string(from: NSNumber(value: range.count)) ?? "\(range.count)"
                let lineCount = selectedLineCount(range, layout: layout)
                let lines = numberFormatter.string(from: NSNumber(value: lineCount)) ?? "\(lineCount)"
                let bytesUnit = range.count == 1 ? "byte" : "bytes"
                let linesUnit = lineCount == 1 ? "line" : "lines"
                left += "  ·  \(bytes) \(bytesUnit), \(lines) \(linesUnit) selected"
            }
        }
        statusBar.setLeft(left)

        var right = ""
        if let format = fileFormat {
            right = format.lineEnding == "—" ? format.encoding : "\(format.lineEnding)  ·  \(format.encoding)"
        }
        statusBar.setRight(right)
    }

    /// The number of document lines the selection touches — derived from the
    /// layout (O(log n) per end), so it's cheap even for a huge selection.
    private func selectedLineCount(_ range: Range<Int>, layout: EditedLayout) -> Int {
        let startLine = documentLine(forByteOffset: range.lowerBound, layout: layout)
        let endLine = documentLine(forByteOffset: max(range.lowerBound, range.upperBound - 1),
                                   layout: layout)
        return endLine - startLine + 1
    }

    private func documentLine(forByteOffset offset: Int, layout: EditedLayout) -> Int {
        let row = layout.visualRow(forLogicalByteOffset: offset)
        return layout.visualLines(forRows: row..<(row + 1)).first?.documentLine ?? 0
    }

    // MARK: - Scroller

    /// Updates the scroller's knob size and position from the viewport state.
    private func syncScroller() {
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
        if viewport.document?.hasEdits == true {
            // The deferred rule and positional edits are mutually exclusive.
            findBar.updateReplaceStatus("Save your edits first")
        } else if let rule = ReplacementRule(pattern: pattern, replacement: replacement),
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

    // MARK: - Go to Line

    /// Asks the user for a line number and scrolls the viewport to it.
    func showGoToLineSheet() {
        guard let layout = viewport.layout, layout.documentLineCount > 0,
              let parentWindow = window else {
            return
        }

        let lineCount = layout.documentLineCount
        let formattedCount = numberFormatter.string(from: NSNumber(value: lineCount))
            ?? "\(lineCount)"
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
                self?.scrollToEnteredLine(field.stringValue, layout: layout)
            }
        }
    }

    private func scrollToEnteredLine(_ text: String, layout: EditedLayout) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let entered = Int(trimmed), entered > 0 {
            let targetLine = min(entered - 1, layout.documentLineCount - 1)
            let row = layout.visualRow(forDocumentLine: targetLine)
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
            infoPane.setPath(file.path)
            infoPane.setType(DocumentView.fileTypeDescription(for: file))
            infoPane.setSize(formatSize(file.size))

            if let document = viewport.document {
                let lineCount = document.layout.documentLineCount
                let count = numberFormatter.string(from: NSNumber(value: lineCount)) ?? "\(lineCount)"
                let suffix = document.lineIndex.isComplete ? "" : " (indexing…)"
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
        if viewport.document?.hasEdits == true {
            // The scan runs over the original file; its offsets would be
            // wrong in the edited document. A later stage searches through
            // the piece table.
            findBar.updateStatus("Search unavailable with unsaved edits")
            return
        }
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
           let layout = viewport.layout {
            currentMatchIndex = index
            let row = layout.visualRow(forLogicalByteOffset: offset)
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

/// A thin draggable strip on the info pane's leading edge, used to resize it.
/// It draws nothing (the info pane draws its own separator line) and shows the
/// horizontal-resize cursor; drags are reported via `onDrag`.
final class InfoPaneDivider: NSView {

    var onDrag: ((NSPoint) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }
}
