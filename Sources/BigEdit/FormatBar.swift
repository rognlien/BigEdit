import AppKit

/// Receives the user's choices from a `FormatBar`.
protocol FormatBarDelegate: AnyObject {
    /// The view mode changed — plain text, or delimited data as columns.
    func formatBar(_ bar: FormatBar, didSelect mode: FormatBar.Mode)
    /// One of the CSV options changed; the whole dialect is handed over.
    func formatBar(_ bar: FormatBar, didChange dialect: CSVDialect)
}

/// A thin strip across the top of the document with the view-mode selector at
/// its right-hand end.
///
/// The selector is a two-segment radio control: **Text** or **CSV**. The CSV
/// side stays disabled until detection finds delimited data, so an ordinary
/// file cannot be put into a mode that would make no sense for it. Choosing
/// CSV reveals a second row with the options that decide how the file is
/// split into columns.
final class FormatBar: NSView {

    enum Mode {
        case text
        case csv
    }

    weak var delegate: FormatBarDelegate?

    /// The height the bar occupies — taller when the CSV options are shown.
    var preferredHeight: CGFloat {
        mode == .csv ? 60 : 28
    }

    private(set) var mode: Mode = .text
    private(set) var dialect = CSVDialect()

    /// Whether detection found delimited data in the current document.
    private var isCSVAvailable = false

    private let modeSelector = NSSegmentedControl()
    private let delimiterLabel = NSTextField(labelWithString: "Delimiter")
    private let delimiterPopUp = NSPopUpButton()
    private let customDelimiterField = NSTextField()
    private let quoteLabel = NSTextField(labelWithString: "Quote")
    private let quotePopUp = NSPopUpButton()
    private let headerCheckbox = NSButton()
    private let pinHeaderCheckbox = NSButton()
    private let trimCheckbox = NSButton()

    /// The named delimiters offered, in menu order. `nil` marks the custom entry.
    private static let delimiterChoices: [(title: String, character: Character?)] = [
        ("Comma  ,", ","),
        ("Semicolon  ;", ";"),
        ("Tab", "\t"),
        ("Pipe  |", "|"),
        ("Custom…", nil)
    ]

    private static let quoteChoices: [(title: String, character: Character?)] = [
        ("Double  \"", "\""),
        ("Single  '", "'"),
        ("None", nil)
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureModeRow()
        configureOptionsRow()
        applyModeVisibility()
        layoutChildren()
    }

    required init?(coder: NSCoder) {
        fatalError("FormatBar is created programmatically")
    }

    // MARK: - Configuration from the document

    /// Tells the bar whether the current document looks like delimited data,
    /// and with which dialect. Passing `nil` removes the CSV option and returns
    /// the bar to plain text.
    func setDetectedDialect(_ detected: CSVDialect?) {
        isCSVAvailable = detected != nil
        if let detected {
            dialect = detected
        }
        if !isCSVAvailable && mode == .csv {
            mode = .text
        }
        updateModeSelector()
        applyDialectToControls()
        applyModeVisibility()
        layoutChildren()
    }

    /// Restores a previously chosen mode (e.g. when switching back to a
    /// document), without telling the delegate about a change it made itself.
    func setMode(_ newMode: Mode) {
        mode = (newMode == .csv && !isCSVAvailable) ? .text : newMode
        updateModeSelector()
        applyModeVisibility()
        layoutChildren()
    }

    // MARK: - Building the controls

    private func configureModeRow() {
        modeSelector.segmentCount = 2
        modeSelector.setLabel("Text", forSegment: 0)
        modeSelector.setLabel("CSV", forSegment: 1)
        modeSelector.trackingMode = .selectOne
        modeSelector.segmentStyle = .rounded
        modeSelector.controlSize = .small
        modeSelector.font = NSFont.systemFont(ofSize: 11)
        modeSelector.target = self
        modeSelector.action = #selector(modeChanged)
        updateModeSelector()
        addSubview(modeSelector)
    }

    private func configureOptionsRow() {
        for label in [delimiterLabel, quoteLabel] {
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }

        for popUp in [delimiterPopUp, quotePopUp] {
            popUp.target = self
            popUp.bezelStyle = .rounded
            popUp.controlSize = .small
            popUp.font = NSFont.systemFont(ofSize: 11)
            addSubview(popUp)
        }
        delimiterPopUp.action = #selector(delimiterChanged)
        delimiterPopUp.addItems(withTitles: FormatBar.delimiterChoices.map(\.title))
        quotePopUp.action = #selector(quoteChanged)
        quotePopUp.addItems(withTitles: FormatBar.quoteChoices.map(\.title))

        customDelimiterField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        customDelimiterField.controlSize = .small
        customDelimiterField.alignment = .center
        customDelimiterField.target = self
        customDelimiterField.action = #selector(customDelimiterChanged)
        customDelimiterField.isHidden = true
        addSubview(customDelimiterField)

        configureCheckbox(headerCheckbox, title: "Header row", action: #selector(headerChanged))
        configureCheckbox(pinHeaderCheckbox, title: "Pin header", action: #selector(pinHeaderChanged))
        configureCheckbox(trimCheckbox, title: "Trim spaces", action: #selector(trimChanged))
    }

    private func configureCheckbox(_ checkbox: NSButton, title: String, action: Selector) {
        checkbox.setButtonType(.switch)
        checkbox.title = title
        checkbox.font = NSFont.systemFont(ofSize: 11)
        checkbox.controlSize = .small
        checkbox.target = self
        checkbox.action = action
        addSubview(checkbox)
    }

    /// Both choices are always visible, so the control never changes width;
    /// the CSV side stays disabled until detection finds delimited data, which
    /// is what "detection enables the selector" looks like on screen.
    private func updateModeSelector() {
        modeSelector.setEnabled(true, forSegment: 0)
        modeSelector.setEnabled(isCSVAvailable, forSegment: 1)
        modeSelector.selectedSegment = mode == .csv && isCSVAvailable ? 1 : 0
        modeSelector.toolTip = isCSVAvailable
            ? nil
            : "This file does not look like delimited data"
    }

    /// Mirrors `dialect` into the option controls.
    private func applyDialectToControls() {
        let namedIndex = FormatBar.delimiterChoices.firstIndex { $0.character == dialect.delimiter }
        delimiterPopUp.selectItem(at: namedIndex ?? FormatBar.delimiterChoices.count - 1)
        customDelimiterField.stringValue = String(dialect.delimiter)
        customDelimiterField.isHidden = namedIndex != nil

        let quoteIndex = FormatBar.quoteChoices.firstIndex { $0.character == dialect.quote }
        quotePopUp.selectItem(at: quoteIndex ?? FormatBar.quoteChoices.count - 1)

        headerCheckbox.state = dialect.hasHeaderRow ? .on : .off
        pinHeaderCheckbox.state = dialect.pinsHeaderRow ? .on : .off
        trimCheckbox.state = dialect.trimsFieldWhitespace ? .on : .off
        pinHeaderCheckbox.isEnabled = dialect.hasHeaderRow
    }

    private func applyModeVisibility() {
        let showingOptions = mode == .csv
        for view in [delimiterLabel, delimiterPopUp, quoteLabel, quotePopUp,
                     headerCheckbox, pinHeaderCheckbox, trimCheckbox] {
            view.isHidden = !showingOptions
        }
        let namedDelimiter = FormatBar.delimiterChoices.contains { $0.character == dialect.delimiter }
        customDelimiterField.isHidden = !showingOptions || namedDelimiter
    }

    // MARK: - Actions

    @objc private func modeChanged() {
        mode = modeSelector.selectedSegment == 1 ? .csv : .text
        applyModeVisibility()
        layoutChildren()
        delegate?.formatBar(self, didSelect: mode)
    }

    @objc private func delimiterChanged() {
        let choice = FormatBar.delimiterChoices[delimiterPopUp.indexOfSelectedItem]
        if let character = choice.character {
            dialect.delimiter = character
            customDelimiterField.isHidden = true
            customDelimiterField.stringValue = String(character)
            publishDialect()
        } else {
            customDelimiterField.isHidden = false
            layoutChildren()
            window?.makeFirstResponder(customDelimiterField)
        }
    }

    @objc private func customDelimiterChanged() {
        if let character = customDelimiterField.stringValue.first {
            dialect.delimiter = character
            publishDialect()
        } else {
            customDelimiterField.stringValue = String(dialect.delimiter)
        }
    }

    @objc private func quoteChanged() {
        dialect.quote = FormatBar.quoteChoices[quotePopUp.indexOfSelectedItem].character
        publishDialect()
    }

    @objc private func headerChanged() {
        dialect.hasHeaderRow = headerCheckbox.state == .on
        pinHeaderCheckbox.isEnabled = dialect.hasHeaderRow
        publishDialect()
    }

    @objc private func pinHeaderChanged() {
        dialect.pinsHeaderRow = pinHeaderCheckbox.state == .on
        publishDialect()
    }

    @objc private func trimChanged() {
        dialect.trimsFieldWhitespace = trimCheckbox.state == .on
        publishDialect()
    }

    private func publishDialect() {
        delegate?.formatBar(self, didChange: dialect)
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    /// Lays both rows out from the right-hand edge inwards, so the selector sits
    /// in the top-right corner of the editor whatever the window's width.
    private func layoutChildren() {
        let padding: CGFloat = 10
        let rowHeight: CGFloat = 20
        let modeRowY = bounds.height - rowHeight - 4

        modeSelector.sizeToFit()
        let modeWidth = max(96, modeSelector.frame.width)
        modeSelector.frame = NSRect(x: bounds.width - padding - modeWidth, y: modeRowY,
                                    width: modeWidth, height: rowHeight)

        guard mode == .csv else { return }

        var trailing = bounds.width - padding
        let optionsRowY = modeRowY - rowHeight - 6
        for control in [trimCheckbox, pinHeaderCheckbox, headerCheckbox] {
            control.sizeToFit()
            let width = control.frame.width
            trailing -= width
            control.frame = NSRect(x: trailing, y: optionsRowY, width: width, height: rowHeight)
            trailing -= padding
        }

        trailing = place(quotePopUp, labelled: quoteLabel, trailing: trailing,
                         y: optionsRowY, height: rowHeight, padding: padding)

        if !customDelimiterField.isHidden {
            let fieldWidth: CGFloat = 34
            trailing -= fieldWidth
            customDelimiterField.frame = NSRect(x: trailing, y: optionsRowY,
                                                width: fieldWidth, height: rowHeight)
            trailing -= 6
        }
        _ = place(delimiterPopUp, labelled: delimiterLabel, trailing: trailing,
                  y: optionsRowY, height: rowHeight, padding: padding)
    }

    /// Places a pop-up and its caption right-to-left, returning the new
    /// trailing edge.
    private func place(_ popUp: NSPopUpButton, labelled label: NSTextField,
                       trailing: CGFloat, y: CGFloat, height: CGFloat,
                       padding: CGFloat) -> CGFloat {
        popUp.sizeToFit()
        var edge = trailing
        let popUpWidth = popUp.frame.width
        edge -= popUpWidth
        popUp.frame = NSRect(x: edge, y: y, width: popUpWidth, height: height)
        edge -= 6

        label.sizeToFit()
        let labelWidth = label.frame.width
        edge -= labelWidth
        label.frame = NSRect(x: edge, y: y + 2, width: labelWidth, height: height - 4)
        return edge - padding
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: 0.5))
        line.line(to: NSPoint(x: bounds.width, y: 0.5))
        line.stroke()
    }
}
