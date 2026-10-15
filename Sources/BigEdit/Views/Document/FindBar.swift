import AppKit

/// Receives the user's intent from a `FindBar`.
protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBar, didSubmitQuery query: String)
    func findBarRequestedNext(_ bar: FindBar)
    func findBarRequestedPrevious(_ bar: FindBar)
    func findBarRequestedClose(_ bar: FindBar)
    /// Show or hide the list of every match.
    func findBarRequestedResultsToggle(_ bar: FindBar)
    func findBar(_ bar: FindBar, didRequestReplaceAll pattern: String, with replacement: String)
    func findBarRequestedRevert(_ bar: FindBar)
    /// Open the window that edits the saved patterns.
    func findBarRequestedManagePatterns(_ bar: FindBar)
    /// The query text changed under the user's fingers, before Enter.
    func findBar(_ bar: FindBar, queryDidChange query: String)
    /// The replacement text changed.
    func findBar(_ bar: FindBar, replacementDidChange replacement: String)
    /// A few lines of the document, for the pattern assistant to look at.
    func findBarSampleText(_ bar: FindBar) -> String?
}

extension FindBarDelegate {
    func findBarRequestedManagePatterns(_ bar: FindBar) {}
    func findBar(_ bar: FindBar, queryDidChange query: String) {}
    func findBar(_ bar: FindBar, replacementDidChange replacement: String) {}
    func findBarSampleText(_ bar: FindBar) -> String? { nil }
}

/// A search bar shown above the document, laid out the way the system's own
/// find bars are: a search field whose magnifier menu holds the options
/// (Match Case, Regular Expression, Show All Matches), the result count, a
/// previous / next segmented control, and Done. In `.findAndReplace` mode a
/// second row appears with a replacement field, Replace All, and Revert.
/// It carries no search logic — it just reports the user's actions.
final class FindBar: NSView, NSSearchFieldDelegate {

    enum Mode {
        case find
        case findAndReplace
    }

    weak var delegate: FindBarDelegate?

    var mode: Mode = .find {
        didSet {
            if mode != oldValue {
                applyModeVisibility()
                layoutChildren()
            }
        }
    }

    /// The height the bar occupies — taller when the replace row is shown.
    var preferredHeight: CGFloat {
        mode == .findAndReplace ? 2 * FindBar.rowHeight : FindBar.rowHeight
    }

    let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let navigationControl = NSSegmentedControl()
    private let doneButton = NSButton()

    /// The options live in the search field's magnifier menu, as in Xcode.
    /// The field shows a *copy* of this template, so state is kept on these
    /// items and the copies are matched back to them by tag.
    private let optionsMenu = NSMenu()
    private let matchCaseItem = NSMenuItem()
    private let regularExpressionItem = NSMenuItem()
    private let dotMatchesNewlineItem = NSMenuItem()
    private let referenceItem = NSMenuItem()
    private let showAllMatchesItem = NSMenuItem()
    private let savedPatternsItem = NSMenuItem()
    private let savedPatternsMenu = NSMenu(title: "Saved Patterns")
    private let savePatternItem = NSMenuItem()
    private let managePatternsItem = NSMenuItem()
    private let describePatternItem = NSMenuItem()
    private let explainPatternItem = NSMenuItem()

    /// Held while the assistant sheet is up.
    private var assistantSheet: PatternAssistantSheet?

    /// Where the Saved Patterns submenu reads from and Save Pattern… writes
    /// to. Tests point it at a library of their own.
    var patternLibrary: PatternLibrary = .shared {
        didSet {
            rebuildSavedPatternsMenu()
        }
    }

    /// Tags of the saved-pattern items start here; the options use 1–3.
    private static let savedPatternTagBase = 1000

    let replacementField = NSTextField()
    private let replaceStatusLabel = NSTextField(labelWithString: "")
    private let replaceAllButton = NSButton()
    private let revertButton = NSButton()

    private static let rowHeight: CGFloat = 34
    private static let controlHeight: CGFloat = 20
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 8
    private static let smallFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    private enum Option: Int {
        case matchCase = 1
        case regularExpression
        case showAllMatches
        case dotMatchesNewline
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureFindRow()
        configureReplaceRow()
        applyModeVisibility()
        layoutChildren()
        NotificationCenter.default.addObserver(
            self, selector: #selector(patternLibraryDidChange(_:)),
            name: PatternLibrary.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FindBar is created programmatically")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The current query text.
    var query: String {
        searchField.stringValue
    }

    /// Moves keyboard focus to the search field and selects its text.
    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// Whether the search distinguishes upper and lower case.
    var isCaseSensitive: Bool {
        matchCaseItem.state == .on
    }

    /// Whether the query is a regular expression rather than literal text.
    var isRegularExpression: Bool {
        regularExpressionItem.state == .on
    }

    /// Whether `.` in a pattern matches a line break too, so a pattern can
    /// span lines.
    var isDotMatchingNewline: Bool {
        dotMatchesNewlineItem.state == .on
    }

    /// The compile options the current settings ask for.
    var regularExpressionOptions: NSRegularExpression.Options {
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !isCaseSensitive {
            options.insert(.caseInsensitive)
        }
        if isDotMatchingNewline {
            options.insert(.dotMatchesLineSeparators)
        }
        return options
    }

    /// Updates the find result-count text (e.g. "3 of 1,024"). A problem
    /// with the pattern is shown in the warning colour.
    func updateStatus(_ text: String, isProblem: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isProblem ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = isProblem ? text : nil
    }

    /// The status text as shown, for tests.
    var statusText: String {
        statusLabel.stringValue
    }

    /// Whether the status shows a problem with the pattern.
    var statusShowsProblem: Bool {
        statusLabel.textColor == .systemRed
    }

    /// Updates the replace status text (e.g. "1,234 replaced").
    func updateReplaceStatus(_ text: String) {
        replaceStatusLabel.stringValue = text
    }

    /// The replace status text as shown, for tests.
    var replaceStatusText: String {
        replaceStatusLabel.stringValue
    }

    /// Reflects whether the results list is showing.
    func setResultsVisible(_ visible: Bool) {
        showAllMatchesItem.state = visible ? .on : .off
    }

    /// Flips the given options as choosing them from the menu would.
    func toggleOption(matchCase: Bool = false, regularExpression: Bool = false,
                      showAllMatches: Bool = false, dotMatchesNewline: Bool = false) {
        if matchCase {
            toggle(.matchCase)
        }
        if regularExpression {
            toggle(.regularExpression)
        }
        if showAllMatches {
            toggle(.showAllMatches)
        }
        if dotMatchesNewline {
            toggle(.dotMatchesNewline)
        }
    }

    // MARK: - Configuration

    private func configureFindRow() {
        searchField.delegate = self
        searchField.controlSize = .small
        searchField.font = FindBar.smallFont
        searchField.sendsWholeSearchString = true   // Search on Enter, not per keystroke.
        searchField.sendsSearchStringImmediately = false
        searchField.placeholderString = "Find"
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        configureOptionsMenu()
        searchField.searchMenuTemplate = optionsMenu
        addSubview(searchField)

        configureStatusLabel(statusLabel)
        configureNavigationControl()
        configureTextButton(doneButton, title: "Done", action: #selector(doneTapped))
    }

    private func configureOptionsMenu() {
        configureOption(matchCaseItem, title: "Match Case", option: .matchCase, on: true)
        configureOption(regularExpressionItem, title: "Regular Expression", option: .regularExpression, on: false)
        configureOption(dotMatchesNewlineItem, title: "Dot Matches Newline", option: .dotMatchesNewline, on: false)
        referenceItem.title = "Regular Expression Reference"
        referenceItem.target = self
        referenceItem.action = #selector(referenceChosen)
        optionsMenu.addItem(referenceItem)
        optionsMenu.addItem(NSMenuItem.separator())
        configureOption(showAllMatchesItem, title: "Show All Matches", option: .showAllMatches, on: false)
        optionsMenu.addItem(NSMenuItem.separator())
        savedPatternsItem.title = "Saved Patterns"
        savedPatternsItem.submenu = savedPatternsMenu
        optionsMenu.addItem(savedPatternsItem)
        savePatternItem.title = "Save Pattern…"
        savePatternItem.target = self
        savePatternItem.action = #selector(savePatternChosen)
        optionsMenu.addItem(savePatternItem)
        managePatternsItem.title = "Manage Saved Patterns…"
        managePatternsItem.target = self
        managePatternsItem.action = #selector(managePatternsChosen)
        optionsMenu.addItem(managePatternsItem)
        // Apple Intelligence: only offered where the model can be asked.
        if PatternAssistant.isAvailable {
            optionsMenu.addItem(NSMenuItem.separator())
            describePatternItem.title = "Describe a Pattern…"
            describePatternItem.target = self
            describePatternItem.action = #selector(describePatternChosen)
            optionsMenu.addItem(describePatternItem)
            explainPatternItem.title = "Explain This Pattern"
            explainPatternItem.target = self
            explainPatternItem.action = #selector(explainPatternChosen)
            optionsMenu.addItem(explainPatternItem)
        }
        rebuildSavedPatternsMenu()
    }

    /// Asks Apple Intelligence for a pattern and searches with it.
    @objc private func describePatternChosen() {
        guard let window else {
            return
        }
        let sheet = PatternAssistantSheet(mode: .describe(sample: delegate?.findBarSampleText(self)))
        assistantSheet = sheet
        sheet.present(in: window) { [weak self] pattern in
            guard let self else { return }
            self.assistantSheet = nil
            if let pattern {
                self.searchField.stringValue = pattern
                self.regularExpressionItem.state = .on
                self.delegate?.findBar(self, didSubmitQuery: pattern)
            }
        }
    }

    @objc private func explainPatternChosen() {
        guard let window, !searchField.stringValue.isEmpty else {
            NSSound.beep()
            return
        }
        let sheet = PatternAssistantSheet(mode: .explain(pattern: searchField.stringValue))
        assistantSheet = sheet
        sheet.present(in: window) { [weak self] _ in
            self?.assistantSheet = nil
        }
    }

    /// Lists the library's patterns in the submenu, then hands the field a
    /// fresh copy of the template so the copy it shows matches.
    private func rebuildSavedPatternsMenu() {
        savedPatternsMenu.removeAllItems()
        let patterns = patternLibrary.patterns
        if patterns.isEmpty {
            let empty = NSMenuItem(title: "No Saved Patterns", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            savedPatternsMenu.addItem(empty)
        }
        for (index, pattern) in patterns.enumerated() {
            let item = NSMenuItem(title: pattern.name, action: #selector(savedPatternChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = FindBar.savedPatternTagBase + index
            item.toolTip = pattern.pattern + (pattern.note.isEmpty ? "" : " — " + pattern.note)
            savedPatternsMenu.addItem(item)
        }
        savedPatternsMenu.autoenablesItems = false
        searchField.searchMenuTemplate = optionsMenu
    }

    @objc private func patternLibraryDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === patternLibrary {
            rebuildSavedPatternsMenu()
        }
    }

    /// The pattern at `index` in the library, if any.
    func savedPattern(at index: Int) -> SavedPattern? {
        let patterns = patternLibrary.patterns
        return patterns.indices.contains(index) ? patterns[index] : nil
    }

    /// Puts `pattern` into the fields, sets its options, and searches.
    func apply(_ pattern: SavedPattern) {
        searchField.stringValue = pattern.pattern
        replacementField.stringValue = pattern.replacement
        matchCaseItem.state = pattern.isCaseSensitive ? .on : .off
        regularExpressionItem.state = pattern.isRegularExpression ? .on : .off
        delegate?.findBar(self, didSubmitQuery: pattern.pattern)
    }

    /// The fields as a pattern worth saving — `nil` while the query is empty.
    var currentPattern: SavedPattern? {
        let query = searchField.stringValue
        guard !query.isEmpty else {
            return nil
        }
        return SavedPattern(name: patternLibrary.suggestedName(for: query), pattern: query,
                            replacement: replacementField.stringValue,
                            isRegularExpression: isRegularExpression,
                            isCaseSensitive: isCaseSensitive)
    }

    /// Asks for a name and saves the current fields under it.
    func promptToSavePattern() {
        guard var pattern = currentPattern, let window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save Pattern"
        alert.informativeText = "A name for “\(pattern.pattern)”, to find it in the Saved Patterns menu."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = pattern.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                pattern.name = name
            }
            if let error = self.patternLibrary.add(pattern) {
                NSAlert(error: error).beginSheetModal(for: window) { _ in }
            }
        }
    }

    private func configureOption(_ item: NSMenuItem, title: String, option: Option, on: Bool) {
        item.title = title
        item.tag = option.rawValue
        item.state = on ? .on : .off
        item.target = self
        item.action = #selector(optionChosen(_:))
        optionsMenu.addItem(item)
    }

    private func configureNavigationControl() {
        navigationControl.segmentCount = 2
        navigationControl.trackingMode = .momentary
        navigationControl.controlSize = .small
        navigationControl.setImage(NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous match"),
                                   forSegment: 0)
        navigationControl.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next match"),
                                   forSegment: 1)
        navigationControl.setToolTip("Previous match", forSegment: 0)
        navigationControl.setToolTip("Next match", forSegment: 1)
        navigationControl.target = self
        navigationControl.action = #selector(navigationClicked)
        addSubview(navigationControl)
    }

    private func configureReplaceRow() {
        replacementField.delegate = self
        replacementField.controlSize = .small
        replacementField.font = FindBar.smallFont
        replacementField.isBezeled = true
        replacementField.bezelStyle = .roundedBezel
        replacementField.placeholderString = "Replace with"
        replacementField.target = self
        replacementField.action = #selector(replaceAllTapped)
        addSubview(replacementField)

        configureStatusLabel(replaceStatusLabel)
        configureTextButton(replaceAllButton, title: "Replace All", action: #selector(replaceAllTapped))
        configureTextButton(revertButton, title: "Revert", action: #selector(revertTapped))
    }

    private func configureStatusLabel(_ label: NSTextField) {
        label.font = FindBar.smallFont
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byTruncatingHead
        addSubview(label)
    }

    private func configureTextButton(_ button: NSButton, title: String, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = FindBar.smallFont
        button.title = title
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func applyModeVisibility() {
        let showsReplaceRow = mode == .findAndReplace
        replacementField.isHidden = !showsReplaceRow
        replaceStatusLabel.isHidden = !showsReplaceRow
        replaceAllButton.isHidden = !showsReplaceRow
        revertButton.isHidden = !showsReplaceRow
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    /// Both rows share one width for their text fields, so the replace field
    /// lines up under the search field however the controls beside them
    /// differ.
    private func layoutChildren() {
        let inset = (FindBar.rowHeight - FindBar.controlHeight) / 2
        let findRowY = bounds.height - FindBar.rowHeight + inset
        let replaceRowY = inset
        let findControlsStart = layoutTrailingControls(
            [(doneButton, 64), (navigationControl, 60), (statusLabel, 150)], y: findRowY)
        let replaceControlsStart = layoutTrailingControls(
            [(revertButton, 72), (replaceAllButton, 100), (replaceStatusLabel, 130)], y: replaceRowY)
        let fieldWidth = max(120, min(findControlsStart, replaceControlsStart) - FindBar.padding - FindBar.gap)
        searchField.frame = NSRect(x: FindBar.padding, y: findRowY, width: fieldWidth, height: FindBar.controlHeight)
        replacementField.frame = NSRect(x: FindBar.padding, y: replaceRowY, width: fieldWidth, height: FindBar.controlHeight)
    }

    /// Lays `controls` out right to left from the bar's trailing edge and
    /// returns the x coordinate where the last of them starts.
    private func layoutTrailingControls(_ controls: [(NSView, CGFloat)], y: CGFloat) -> CGFloat {
        var right = bounds.width - FindBar.padding
        for (control, width) in controls {
            control.frame = NSRect(x: right - width, y: y, width: width, height: FindBar.controlHeight)
            right -= width + FindBar.gap
        }
        return right + FindBar.gap
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 0, y: 0.5))
        separator.line(to: NSPoint(x: bounds.width, y: 0.5))
        separator.stroke()
    }

    // MARK: - Actions

    @objc private func searchSubmitted() {
        delegate?.findBar(self, didSubmitQuery: searchField.stringValue)
    }

    @objc private func navigationClicked() {
        if navigationControl.selectedSegment == 0 {
            delegate?.findBarRequestedPrevious(self)
        } else {
            delegate?.findBarRequestedNext(self)
        }
    }

    @objc private func doneTapped() {
        delegate?.findBarRequestedClose(self)
    }

    @objc private func replaceAllTapped() {
        delegate?.findBar(self, didRequestReplaceAll: searchField.stringValue, with: replacementField.stringValue)
    }

    @objc private func revertTapped() {
        delegate?.findBarRequestedRevert(self)
    }

    /// The search field hands over a copy of the menu item, so the template
    /// item with the same tag is the one whose state changes.
    @objc private func optionChosen(_ sender: NSMenuItem) {
        if let option = Option(rawValue: sender.tag) {
            toggle(option)
        }
    }

    @objc private func savedPatternChosen(_ sender: NSMenuItem) {
        if let pattern = savedPattern(at: sender.tag - FindBar.savedPatternTagBase) {
            apply(pattern)
        }
    }

    @objc private func savePatternChosen() {
        promptToSavePattern()
    }

    @objc private func managePatternsChosen() {
        delegate?.findBarRequestedManagePatterns(self)
    }

    /// Match Case and Regular Expression re-submit the query so the search
    /// rebuilds in the new mode without another Enter; Show All Matches only
    /// asks for the list, whose visibility comes back through
    /// `setResultsVisible`.
    private func toggle(_ option: Option) {
        switch option {
        case .matchCase:
            matchCaseItem.state = matchCaseItem.state == .on ? .off : .on
            delegate?.findBar(self, didSubmitQuery: searchField.stringValue)
        case .regularExpression:
            regularExpressionItem.state = regularExpressionItem.state == .on ? .off : .on
            delegate?.findBar(self, didSubmitQuery: searchField.stringValue)
        case .dotMatchesNewline:
            dotMatchesNewlineItem.state = dotMatchesNewlineItem.state == .on ? .off : .on
            delegate?.findBar(self, didSubmitQuery: searchField.stringValue)
        case .showAllMatches:
            delegate?.findBarRequestedResultsToggle(self)
        }
    }

    @objc private func referenceChosen() {
        RegexReferencePopover.show(relativeTo: searchField)
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === searchField {
            delegate?.findBar(self, queryDidChange: searchField.stringValue)
        } else if field === replacementField {
            delegate?.findBar(self, replacementDidChange: replacementField.stringValue)
        }
    }

    /// Reports a change to the fields as typing into them would.
    func simulateTyping(query: String? = nil, replacement: String? = nil) {
        if let query {
            searchField.stringValue = query
            delegate?.findBar(self, queryDidChange: query)
        }
        if let replacement {
            replacementField.stringValue = replacement
            delegate?.findBar(self, replacementDidChange: replacement)
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        var handled = false
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            delegate?.findBarRequestedClose(self)
            handled = true
        } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
            handled = moveFocus(from: control, forward: true)
        } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            handled = moveFocus(from: control, forward: false)
        }
        return handled
    }

    /// Tab from the find field lands in the replace field, and Shift-Tab
    /// from the replace field goes back — while the replace row is showing.
    /// Any other Tab is left to AppKit's own key-view loop.
    private func moveFocus(from control: NSControl, forward: Bool) -> Bool {
        var target: NSTextField?
        if mode == .findAndReplace {
            if forward, control === searchField {
                target = replacementField
            } else if !forward, control === replacementField {
                target = searchField
            }
        }
        if let target {
            window?.makeFirstResponder(target)
            target.selectText(nil)
        }
        return target != nil
    }
}
