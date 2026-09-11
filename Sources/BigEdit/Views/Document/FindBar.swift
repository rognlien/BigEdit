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
    private let showAllMatchesItem = NSMenuItem()

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
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureFindRow()
        configureReplaceRow()
        applyModeVisibility()
        layoutChildren()
    }

    required init?(coder: NSCoder) {
        fatalError("FindBar is created programmatically")
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

    /// Updates the find result-count text (e.g. "3 of 1,024").
    func updateStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// Updates the replace status text (e.g. "1,234 replaced").
    func updateReplaceStatus(_ text: String) {
        replaceStatusLabel.stringValue = text
    }

    /// Reflects whether the results list is showing.
    func setResultsVisible(_ visible: Bool) {
        showAllMatchesItem.state = visible ? .on : .off
    }

    /// Flips the given options as choosing them from the menu would.
    func toggleOption(matchCase: Bool = false, regularExpression: Bool = false, showAllMatches: Bool = false) {
        if matchCase {
            toggle(.matchCase)
        }
        if regularExpression {
            toggle(.regularExpression)
        }
        if showAllMatches {
            toggle(.showAllMatches)
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
        optionsMenu.addItem(NSMenuItem.separator())
        configureOption(showAllMatchesItem, title: "Show All Matches", option: .showAllMatches, on: false)
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
        case .showAllMatches:
            delegate?.findBarRequestedResultsToggle(self)
        }
    }

    // MARK: - NSSearchFieldDelegate

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
