import AppKit

/// The left-side list of open documents. A view-based `NSTableView` inside a
/// scroll view; the class is its own data source and delegate. Selecting a row
/// switches the active document; a right-click offers Close.
final class DocumentListView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    /// Called when the user selects a different row.
    var onSelect: ((Int) -> Void)?
    /// Called when the user closes a row from its context menu.
    var onClose: ((Int) -> Void)?
    /// Called with file URLs dropped onto the sidebar.
    var onOpenFiles: (([URL]) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var documents: [Document] = []
    /// Guards against feeding programmatic selection changes back out as user
    /// selections.
    private var isSyncingSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 42
        tableView.style = .sourceList
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.menu = makeRowMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)

        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Drag & drop (open files)

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options)
        return (objects as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        if urls.isEmpty {
            return false
        }
        onOpenFiles?(urls)
        return true
    }

    required init?(coder: NSCoder) {
        fatalError("DocumentListView is created programmatically")
    }

    // MARK: - Data

    /// Replaces the list contents and restores the given selection.
    func reload(documents: [Document], selectedIndex: Int?) {
        self.documents = documents
        tableView.reloadData()
        applySelection(selectedIndex)
    }

    /// Refreshes a single row, e.g. when its index finishes and the line count
    /// becomes available.
    func reloadRow(_ index: Int) {
        guard documents.indices.contains(index) else {
            return
        }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: index),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    /// Sets the selected row without emitting an `onSelect` callback.
    func applySelection(_ index: Int?) {
        isSyncingSelection = true
        if let index, documents.indices.contains(index) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
        isSyncingSelection = false
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        documents.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = dequeueCell()
        let document = documents[row]
        cell.nameField.stringValue = document.fileName
        cell.detailField.stringValue = document.secondaryLine
        cell.showsEditedDot = document.isEdited
        cell.closeButton.target = self
        cell.closeButton.action = #selector(closeButtonClicked(_:))
        return cell
    }

    @objc private func closeButtonClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        if row >= 0 {
            onClose?(row)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if isSyncingSelection {
            return
        }
        let row = tableView.selectedRow
        if row >= 0 {
            onSelect?(row)
        }
    }

    private func dequeueCell() -> DocumentRowView {
        let identifier = NSUserInterfaceItemIdentifier("DocumentRowView")
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? DocumentRowView {
            return reused
        }
        let cell = DocumentRowView()
        cell.identifier = identifier
        return cell
    }

    // MARK: - Row context menu

    private func makeRowMenu() -> NSMenu {
        let menu = NSMenu()
        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(closeClickedRow),
            keyEquivalent: ""
        )
        closeItem.target = self
        menu.addItem(closeItem)
        return menu
    }

    @objc private func closeClickedRow() {
        let row = tableView.clickedRow
        if row >= 0 {
            onClose?(row)
        }
    }
}

/// A two-line cell: file name above a smaller, muted size / line-count line.
/// The trailing edge shows an edited dot, replaced by a close button on hover.
final class DocumentRowView: NSTableCellView {

    let nameField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")
    let editedField = NSTextField(labelWithString: "●")
    let closeButton = NSButton()

    /// Whether this document has unsaved edits, so the dot returns when the
    /// pointer leaves and the close button hides.
    var showsEditedDot = false {
        didSet { updateTrailingVisibility() }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    init() {
        super.init(frame: .zero)

        nameField.font = NSFont.systemFont(ofSize: 13)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        addSubview(nameField)

        detailField.font = NSFont.systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingMiddle
        addSubview(detailField)

        editedField.font = NSFont.systemFont(ofSize: 10)
        editedField.textColor = .controlAccentColor
        editedField.alignment = .right
        addSubview(editedField)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close"
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("DocumentRowView is created programmatically")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateTrailingVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateTrailingVisibility()
    }

    /// On hover the close button takes the trailing slot; otherwise the edited
    /// dot shows (when the document has unsaved edits).
    private func updateTrailingVisibility() {
        closeButton.isHidden = !isHovered
        editedField.isHidden = isHovered || !showsEditedDot
    }

    override func layout() {
        super.layout()
        let horizontalPadding: CGFloat = 8
        let dotWidth: CGFloat = 12
        let nameHeight: CGFloat = 17
        let detailHeight: CGFloat = 14
        let gap: CGFloat = 1
        let totalHeight = nameHeight + gap + detailHeight
        let top = (bounds.height - totalHeight) / 2
        let textWidth = max(0, bounds.width - 2 * horizontalPadding - dotWidth)

        // Not flipped: y grows upward, so the name sits above the detail line.
        let detailY = top
        let nameY = detailY + detailHeight + gap
        nameField.frame = NSRect(
            x: horizontalPadding, y: nameY,
            width: textWidth, height: nameHeight
        )
        detailField.frame = NSRect(
            x: horizontalPadding, y: detailY,
            width: textWidth, height: detailHeight
        )
        editedField.frame = NSRect(
            x: bounds.width - horizontalPadding - dotWidth, y: nameY,
            width: dotWidth, height: nameHeight
        )
        let closeSize: CGFloat = 16
        closeButton.frame = NSRect(
            x: bounds.width - horizontalPadding - closeSize,
            y: (bounds.height - closeSize) / 2,
            width: closeSize, height: closeSize
        )
    }
}
