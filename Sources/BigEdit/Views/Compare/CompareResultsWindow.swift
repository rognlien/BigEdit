import AppKit

/// One line in a compare result, with how it should be shown.
struct CompareRow: Equatable {

    enum Kind: Equatable {
        /// A line of one of the lists.
        case plain
        /// A line only the second document has (a sequence diff's `+`).
        case added
        /// A line only the first document has (a sequence diff's `-`).
        case removed
        /// A line both have, shown for context.
        case context
        /// A hunk header such as `@@ -1,3 +1,4 @@`.
        case header
    }

    let text: String
    let kind: Kind

    init(_ text: String, kind: Kind = .plain) {
        self.text = text
        self.kind = kind
    }
}

/// One tab of a compare result: a title, its rows, and the text that Copy
/// and Save write out for it.
struct CompareSection {
    let title: String
    let rows: [CompareRow]
    /// A file name to suggest when the section is saved.
    let suggestedFileName: String

    /// The rows as text, one per line.
    var exportText: String {
        rows.map(\.text).joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }
}

/// A window showing the result of comparing two documents: a segmented
/// control picks the section (only in one, only in the other, in both, the
/// changes), a table lists its lines, and the lines can be copied, saved to
/// a file, or opened as a new document.
///
/// The table is view-based and only builds the rows that are on screen, so
/// a result with a million lines costs what the viewport shows.
final class CompareResultsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                  NSWindowDelegate {

    let window: NSWindow

    /// Asked to open `text` as a new document named like `fileName`.
    var onOpenAsDocument: ((_ text: String, _ fileName: String) -> Void)?

    /// Called when the window closes, so the owner can let go of it.
    var onClose: (() -> Void)?

    private let sections: [CompareSection]
    private let sectionControl = NSSegmentedControl()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let copyButton = NSButton()
    private let saveButton = NSButton()
    private let openButton = NSButton()
    private let content = CompareResultsContentView(frame: .zero)

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    init(title: String, sections: [CompareSection]) {
        self.sections = sections
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 240)
        super.init()
        window.delegate = self
        buildContents()
        selectSection(0)
    }

    /// Shows the window, centred over `parent` when there is one.
    func show(relativeTo parent: NSWindow?) {
        if let parent {
            let frame = parent.frame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                          y: frame.midY - size.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// The section the control shows.
    var selectedSection: CompareSection {
        sections[max(0, min(sectionControl.selectedSegment, sections.count - 1))]
    }

    /// Selects section `index` as choosing it in the control would.
    func selectSection(_ index: Int) {
        guard sections.indices.contains(index) else {
            return
        }
        sectionControl.selectedSegment = index
        sectionChanged()
    }

    // MARK: - Building

    private func buildContents() {
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        sectionControl.segmentCount = sections.count
        sectionControl.trackingMode = .selectOne
        for (index, section) in sections.enumerated() {
            let count = CompareResultsWindow.numberFormatter.string(
                from: NSNumber(value: section.rows.count)) ?? "\(section.rows.count)"
            sectionControl.setLabel("\(section.title) (\(count))", forSegment: index)
        }
        sectionControl.target = self
        sectionControl.action = #selector(sectionChanged)
        content.addSubview(sectionControl)

        summaryLabel.font = NSFont.systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(summaryLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("line"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 18
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        content.addSubview(scrollView)

        configureButton(copyButton, title: "Copy", action: #selector(copyTapped))
        configureButton(saveButton, title: "Save As…", action: #selector(saveTapped))
        configureButton(openButton, title: "Open as Document", action: #selector(openTapped))

        content.onLayout = { [weak self] in self?.layoutChildren() }
        layoutChildren()
    }

    private func configureButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.target = self
        button.action = action
        content.addSubview(button)
    }

    private func layoutChildren() {
        let bounds = content.bounds
        let padding: CGFloat = 16
        let controlHeight: CGFloat = 24
        let buttonHeight: CGFloat = 32
        let buttonWidth: CGFloat = 150
        sectionControl.sizeToFit()
        let controlWidth = min(sectionControl.frame.width, bounds.width - 2 * padding)
        sectionControl.frame = NSRect(x: padding, y: bounds.height - padding - controlHeight,
                                      width: controlWidth, height: controlHeight)
        summaryLabel.frame = NSRect(x: padding, y: sectionControl.frame.minY - 20,
                                    width: bounds.width - 2 * padding, height: 16)
        let buttonsY = padding
        var right = bounds.width - padding
        for button in [openButton, saveButton, copyButton] {
            button.frame = NSRect(x: right - buttonWidth, y: buttonsY,
                                  width: buttonWidth, height: buttonHeight)
            right -= buttonWidth + 8
        }
        let tableTop = summaryLabel.frame.minY - 8
        let tableBottom = buttonsY + buttonHeight + 12
        scrollView.frame = NSRect(x: padding, y: tableBottom, width: bounds.width - 2 * padding,
                                  height: max(0, tableTop - tableBottom))
    }

    // MARK: - Sections

    @objc private func sectionChanged() {
        let section = selectedSection
        let count = CompareResultsWindow.numberFormatter.string(
            from: NSNumber(value: section.rows.count)) ?? "\(section.rows.count)"
        summaryLabel.stringValue = section.rows.isEmpty
            ? "Nothing here."
            : "\(count) line\(section.rows.count == 1 ? "" : "s")"
        let hasRows = !section.rows.isEmpty
        copyButton.isEnabled = hasRows
        saveButton.isEnabled = hasRows
        openButton.isEnabled = hasRows && onOpenAsDocument != nil
        tableView.reloadData()
        if hasRows {
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: - Actions

    /// Copies the selected rows, or the whole section when none are selected.
    @objc private func copyTapped() {
        let rows = selectedSection.rows
        let selected = tableView.selectedRowIndexes
        let chosen = selected.isEmpty ? rows : selected.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        let text = chosen.map(\.text).joined(separator: "\n") + "\n"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func saveTapped() {
        let section = selectedSection
        let panel = NSSavePanel()
        panel.nameFieldStringValue = section.suggestedFileName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                do {
                    try section.exportText.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openTapped() {
        let section = selectedSection
        onOpenAsDocument?(section.exportText, section.suggestedFileName)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        selectedSection.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("compareCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? CompareResultsWindow.makeCell(identifier)
        let rows = selectedSection.rows
        if rows.indices.contains(row) {
            cell.attributedStringValue = CompareResultsWindow.attributedText(for: rows[row])
        } else {
            cell.stringValue = ""
        }
        return cell
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return field
    }

    /// The row's text in the colour its kind calls for; a tab or a control
    /// character is left to the field, which draws it as a space.
    static func attributedText(for row: CompareRow) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let colour: NSColor
        switch row.kind {
        case .plain, .context: colour = .labelColor
        case .added: colour = .systemGreen
        case .removed: colour = .systemRed
        case .header: colour = .secondaryLabelColor
        }
        let text = row.text.replacingOccurrences(of: "\r", with: "")
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

/// The window's content view: it only exists to report resizes, since the
/// window owner lays the controls out by hand.
final class CompareResultsContentView: NSView {

    var onLayout: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?()
    }
}
