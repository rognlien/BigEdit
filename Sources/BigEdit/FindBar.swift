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

/// A search bar shown above the document. In `.find` mode it is a single row:
/// search field, result count, previous / next / close. In `.findAndReplace`
/// mode a second row appears with a replacement field, Replace All, and Revert.
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
        mode == .findAndReplace ? 72 : 40
    }

    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()
    private let resultsButton = NSButton()
    private let caseToggleButton = NSButton()
    private let regexToggleButton = NSButton()

    private let replacementField = NSTextField()
    private let replaceStatusLabel = NSTextField(labelWithString: "")
    private let replaceAllButton = NSButton()
    private let revertButton = NSButton()

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

    /// Whether the case toggle is on — search distinguishes upper/lower case.
    /// Whether the query is a regular expression rather than literal text.
    var isRegularExpression: Bool {
        regexToggleButton.state == .on
    }

    var isCaseSensitive: Bool {
        return caseToggleButton.state == .on
    }

    /// Updates the find result-count text (e.g. "3 of 1,024").
    func updateStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// Updates the replace status text (e.g. "1,234 replaced").
    func updateReplaceStatus(_ text: String) {
        replaceStatusLabel.stringValue = text
    }

    // MARK: - Configuration

    private func configureFindRow() {
        searchField.delegate = self
        searchField.sendsWholeSearchString = true   // Search on Enter, not per keystroke.
        searchField.sendsSearchStringImmediately = false
        searchField.placeholderString = "Find"
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        addSubview(searchField)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingHead
        addSubview(statusLabel)

        configureButton(previousButton, symbol: "chevron.up", fallback: "<", action: #selector(previousTapped))
        configureButton(nextButton, symbol: "chevron.down", fallback: ">", action: #selector(nextTapped))
        configureButton(closeButton, symbol: "xmark", fallback: "X", action: #selector(closeTapped))
        configureButton(resultsButton, symbol: "list.bullet", fallback: "≡", action: #selector(resultsTapped))
        resultsButton.setButtonType(.pushOnPushOff)
        resultsButton.toolTip = "Show all matches"

        caseToggleButton.title = "Aa"
        caseToggleButton.bezelStyle = .rounded
        caseToggleButton.setButtonType(.pushOnPushOff)
        caseToggleButton.state = .on   // Default is case-sensitive.
        caseToggleButton.target = self
        caseToggleButton.action = #selector(caseToggleChanged)
        caseToggleButton.toolTip = "Match case"
        caseToggleButton.font = NSFont.systemFont(ofSize: 11)
        addSubview(caseToggleButton)

        regexToggleButton.title = ".*"
        regexToggleButton.bezelStyle = .rounded
        regexToggleButton.setButtonType(.pushOnPushOff)
        regexToggleButton.state = .off   // Literal by default.
        regexToggleButton.target = self
        regexToggleButton.action = #selector(regexToggleChanged)
        regexToggleButton.toolTip = "Regular expression"
        regexToggleButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        addSubview(regexToggleButton)
    }

    private func configureReplaceRow() {
        replacementField.delegate = self
        replacementField.isBezeled = true
        replacementField.bezelStyle = .roundedBezel
        replacementField.placeholderString = "Replace with"
        replacementField.target = self
        replacementField.action = #selector(replaceAllTapped)
        addSubview(replacementField)

        replaceStatusLabel.font = NSFont.systemFont(ofSize: 11)
        replaceStatusLabel.textColor = .secondaryLabelColor
        replaceStatusLabel.alignment = .right
        replaceStatusLabel.lineBreakMode = .byTruncatingHead
        addSubview(replaceStatusLabel)

        configureTextButton(replaceAllButton, title: "Replace All", action: #selector(replaceAllTapped))
        configureTextButton(revertButton, title: "Revert", action: #selector(revertTapped))
    }

    private func configureButton(_ button: NSButton, symbol: String, fallback: String, action: Selector) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = fallback
        }
        addSubview(button)
    }

    private func configureTextButton(_ button: NSButton, title: String, action: Selector) {
        button.bezelStyle = .rounded
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

    private func layoutChildren() {
        let controlHeight: CGFloat = 24
        let padding: CGFloat = 8
        let gap: CGFloat = 6
        let buttonWidth: CGFloat = 32
        let statusWidth: CGFloat = 150

        // The find row sits at the top of the bar.
        let findRowY = bounds.height - padding - controlHeight

        var right = bounds.width - padding
        closeButton.frame = NSRect(x: right - buttonWidth, y: findRowY, width: buttonWidth, height: controlHeight)
        right -= buttonWidth + gap
        nextButton.frame = NSRect(x: right - buttonWidth, y: findRowY, width: buttonWidth, height: controlHeight)
        right -= buttonWidth
        previousButton.frame = NSRect(x: right - buttonWidth, y: findRowY, width: buttonWidth, height: controlHeight)
        right -= buttonWidth + gap
        resultsButton.frame = NSRect(x: right - buttonWidth, y: findRowY, width: buttonWidth, height: controlHeight)
        right -= buttonWidth + gap
        let caseWidth: CGFloat = 36
        caseToggleButton.frame = NSRect(x: right - caseWidth, y: findRowY, width: caseWidth, height: controlHeight)
        right -= caseWidth
        regexToggleButton.frame = NSRect(x: right - caseWidth, y: findRowY, width: caseWidth, height: controlHeight)
        right -= caseWidth + gap
        statusLabel.frame = NSRect(x: right - statusWidth, y: findRowY, width: statusWidth, height: controlHeight)
        right -= statusWidth + gap
        searchField.frame = NSRect(x: padding, y: findRowY, width: max(120, right - padding), height: controlHeight)

        if mode == .findAndReplace {
            let replaceAllWidth: CGFloat = 100
            let revertWidth: CGFloat = 72
            let replaceStatusWidth: CGFloat = 130

            var replaceRight = bounds.width - padding
            revertButton.frame = NSRect(x: replaceRight - revertWidth, y: padding, width: revertWidth, height: controlHeight)
            replaceRight -= revertWidth + gap
            replaceAllButton.frame = NSRect(x: replaceRight - replaceAllWidth, y: padding, width: replaceAllWidth, height: controlHeight)
            replaceRight -= replaceAllWidth + gap
            replaceStatusLabel.frame = NSRect(x: replaceRight - replaceStatusWidth, y: padding, width: replaceStatusWidth, height: controlHeight)
            replaceRight -= replaceStatusWidth + gap
            replacementField.frame = NSRect(x: padding, y: padding, width: max(120, replaceRight - padding), height: controlHeight)
        }
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

    @objc private func nextTapped() {
        delegate?.findBarRequestedNext(self)
    }

    @objc private func previousTapped() {
        delegate?.findBarRequestedPrevious(self)
    }

    @objc private func closeTapped() {
        delegate?.findBarRequestedClose(self)
    }

    @objc private func replaceAllTapped() {
        delegate?.findBar(self, didRequestReplaceAll: searchField.stringValue, with: replacementField.stringValue)
    }

    @objc private func revertTapped() {
        delegate?.findBarRequestedRevert(self)
    }

    @objc private func resultsTapped() {
        delegate?.findBarRequestedResultsToggle(self)
    }

    /// Reflects whether the results list is showing.
    func setResultsVisible(_ visible: Bool) {
        resultsButton.state = visible ? .on : .off
    }

    @objc private func regexToggleChanged() {
        // Like the case toggle: re-submit so the search rebuilds in the new mode.
        delegate?.findBar(self, didSubmitQuery: searchField.stringValue)
    }

    @objc private func caseToggleChanged() {
        // Treat a case-toggle as a re-submission so the search rebuilds with
        // the new sensitivity without the user having to hit Enter again.
        delegate?.findBar(self, didSubmitQuery: searchField.stringValue)
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
        }
        return handled
    }
}
