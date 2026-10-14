import AppKit

/// A window for editing the saved patterns: one row each, every column
/// editable in place, with buttons to add and remove rows.
final class PatternLibraryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                  NSTextFieldDelegate, NSWindowDelegate {

    let window: NSWindow
    let library: PatternLibrary

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let locationLabel = NSTextField(labelWithString: "")
    private let content = CompareResultsContentView(frame: .zero)

    private enum Column: String, CaseIterable {
        case name, pattern, replacement, regularExpression, matchCase, note

        var title: String {
            switch self {
            case .name: return "Name"
            case .pattern: return "Pattern"
            case .replacement: return "Replace With"
            case .regularExpression: return "Regex"
            case .matchCase: return "Match Case"
            case .note: return "Note"
            }
        }

        var width: CGFloat {
            switch self {
            case .name: return 140
            case .pattern: return 200
            case .replacement: return 140
            case .regularExpression: return 50
            case .matchCase: return 76
            case .note: return 180
            }
        }

        var isCheckbox: Bool {
            self == .regularExpression || self == .matchCase
        }
    }

    init(library: PatternLibrary) {
        self.library = library
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Saved Patterns"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 200)
        window.setFrameAutosaveName("BigEditSavedPatterns")
        super.init()
        window.delegate = self
        buildContents()
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidChange(_:)),
            name: PatternLibrary.didChangeNotification, object: library)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show() {
        reloadLocation()
        tableView.reloadData()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Building

    private func buildContents() {
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 40
            tableView.addTableColumn(tableColumn)
        }
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        content.addSubview(scrollView)

        addButton.title = "+"
        addButton.bezelStyle = .smallSquare
        addButton.target = self
        addButton.action = #selector(addTapped)
        content.addSubview(addButton)

        removeButton.title = "−"
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        content.addSubview(removeButton)

        locationLabel.font = NSFont.systemFont(ofSize: 11)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(locationLabel)

        content.onLayout = { [weak self] in self?.layoutChildren() }
        layoutChildren()
    }

    private func layoutChildren() {
        let bounds = content.bounds
        let padding: CGFloat = 16
        let buttonSize: CGFloat = 24
        addButton.frame = NSRect(x: padding, y: padding, width: buttonSize, height: buttonSize)
        removeButton.frame = NSRect(x: padding + buttonSize - 1, y: padding,
                                    width: buttonSize, height: buttonSize)
        locationLabel.frame = NSRect(x: padding + 2 * buttonSize + 12, y: padding + 4,
                                     width: max(0, bounds.width - padding * 2 - 2 * buttonSize - 12),
                                     height: 16)
        let tableBottom = padding + buttonSize + 12
        scrollView.frame = NSRect(x: padding, y: tableBottom, width: bounds.width - 2 * padding,
                                  height: max(0, bounds.height - tableBottom - padding))
    }

    private func reloadLocation() {
        locationLabel.stringValue = "Kept in \(library.fileURL.path)"
        locationLabel.toolTip = library.fileURL.path
    }

    @objc private func libraryDidChange(_ notification: Notification) {
        reloadLocation()
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func addTapped() {
        let pattern = SavedPattern(name: library.suggestedName(for: "New Pattern"), pattern: "")
        report(library.add(pattern))
        let row = library.patterns.count - 1
        if row >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.editColumn(0, row: row, with: nil, select: true)
        }
    }

    @objc private func removeTapped() {
        let ids = tableView.selectedRowIndexes.compactMap { index -> UUID? in
            library.patterns.indices.contains(index) ? library.patterns[index].id : nil
        }
        for id in ids {
            report(library.remove(id: id))
        }
    }

    private func report(_ error: Error?) {
        if let error {
            NSAlert(error: error).beginSheetModal(for: window) { _ in }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        library.patterns.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
              library.patterns.indices.contains(row) else {
            return nil
        }
        let pattern = library.patterns[row]
        if column.isCheckbox {
            let checkbox = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSButton
                ?? makeCheckbox(tableColumn.identifier)
            checkbox.state = (column == .regularExpression ? pattern.isRegularExpression
                                                            : pattern.isCaseSensitive) ? .on : .off
            return checkbox
        }
        let field = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTextField
            ?? makeField(tableColumn.identifier, monospaced: column == .pattern || column == .replacement)
        switch column {
        case .name: field.stringValue = pattern.name
        case .pattern: field.stringValue = pattern.pattern
        case .replacement: field.stringValue = pattern.replacement
        case .note: field.stringValue = pattern.note
        case .regularExpression, .matchCase: break
        }
        return field
    }

    private func makeField(_ identifier: NSUserInterfaceItemIdentifier, monospaced: Bool) -> NSTextField {
        let field = NSTextField(string: "")
        field.identifier = identifier
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.lineBreakMode = .byTruncatingTail
        field.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12)
        field.delegate = self
        return field
    }

    private func makeCheckbox(_ identifier: NSUserInterfaceItemIdentifier) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
        checkbox.identifier = identifier
        return checkbox
    }

    /// A text cell finished editing: write its column back to its row.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let identifier = field.identifier, let column = Column(rawValue: identifier.rawValue) else {
            return
        }
        let row = tableView.row(for: field)
        guard library.patterns.indices.contains(row) else {
            return
        }
        var pattern = library.patterns[row]
        switch column {
        case .name: pattern.name = field.stringValue
        case .pattern: pattern.pattern = field.stringValue
        case .replacement: pattern.replacement = field.stringValue
        case .note: pattern.note = field.stringValue
        case .regularExpression, .matchCase: break
        }
        if pattern != library.patterns[row] {
            report(library.update(pattern))
        }
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard let identifier = sender.identifier, let column = Column(rawValue: identifier.rawValue) else {
            return
        }
        let row = tableView.row(for: sender)
        guard library.patterns.indices.contains(row) else {
            return
        }
        var pattern = library.patterns[row]
        if column == .regularExpression {
            pattern.isRegularExpression = sender.state == .on
        } else {
            pattern.isCaseSensitive = sender.state == .on
        }
        report(library.update(pattern))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }
}
