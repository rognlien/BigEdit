import AppKit

/// Asks how to split a file into columns when detection found no delimited
/// data in it: the delimiter, the quote, and whether the first row is a header.
final class CSVStructurePrompt {

    private let alert = NSAlert()
    private let delimiterPopUp = NSPopUpButton()
    private let customDelimiterField = NSTextField()
    private let quotePopUp = NSPopUpButton()
    private let headerCheckbox = NSButton(checkboxWithTitle: "First row is a header", target: nil, action: nil)
    private var proposed: CSVDialect

    init(proposing dialect: CSVDialect) {
        proposed = dialect
        alert.messageText = "Show this file as columns?"
        alert.informativeText = "This file does not look like delimited data. Choose how each line is split into columns."
        alert.addButton(withTitle: "Show Columns")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = makeAccessoryView()
        load(dialect)
    }

    /// Shows the prompt on `window` and hands back the chosen dialect, or nil
    /// when it is cancelled.
    func present(in window: NSWindow, completion: @escaping (CSVDialect?) -> Void) {
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn ? self.dialect : nil)
        }
    }

    /// The dialect the controls describe. An empty custom delimiter keeps the
    /// proposed one.
    var dialect: CSVDialect {
        var result = proposed
        let delimiterChoice = FormatBar.delimiterChoices[delimiterPopUp.indexOfSelectedItem]
        result.delimiter = delimiterChoice.character
            ?? customDelimiterField.stringValue.first
            ?? proposed.delimiter
        result.quote = FormatBar.quoteChoices[quotePopUp.indexOfSelectedItem].character
        result.hasHeaderRow = headerCheckbox.state == .on
        return result
    }

    /// Chooses the delimiter menu item at `index`, as a click would — for tests.
    func chooseDelimiter(at index: Int, custom: String = "") {
        delimiterPopUp.selectItem(at: index)
        customDelimiterField.stringValue = custom
        delimiterChanged()
    }

    private func load(_ dialect: CSVDialect) {
        let namedIndex = FormatBar.delimiterChoices.firstIndex { $0.character == dialect.delimiter }
        delimiterPopUp.selectItem(at: namedIndex ?? FormatBar.delimiterChoices.count - 1)
        customDelimiterField.stringValue = namedIndex == nil ? String(dialect.delimiter) : ""
        let quoteIndex = FormatBar.quoteChoices.firstIndex { $0.character == dialect.quote }
        quotePopUp.selectItem(at: quoteIndex ?? FormatBar.quoteChoices.count - 1)
        headerCheckbox.state = dialect.hasHeaderRow ? .on : .off
        delimiterChanged()
    }

    private func makeAccessoryView() -> NSView {
        delimiterPopUp.addItems(withTitles: FormatBar.delimiterChoices.map(\.title))
        delimiterPopUp.target = self
        delimiterPopUp.action = #selector(delimiterChanged)
        quotePopUp.addItems(withTitles: FormatBar.quoteChoices.map(\.title))
        customDelimiterField.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        customDelimiterField.alignment = .center
        customDelimiterField.placeholderString = "Character"
        customDelimiterField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let delimiterRow = NSStackView(views: [delimiterPopUp, customDelimiterField])
        delimiterRow.spacing = 8
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Delimiter:"), delimiterRow],
            [NSTextField(labelWithString: "Quote:"), quotePopUp],
            [NSGridCell.emptyContentView, headerCheckbox]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.frame.size = grid.fittingSize
        return grid
    }

    @objc private func delimiterChanged() {
        let isCustom = FormatBar.delimiterChoices[delimiterPopUp.indexOfSelectedItem].character == nil
        customDelimiterField.isEnabled = isCustom
        if isCustom {
            alert.window.makeFirstResponder(customDelimiterField)
        }
    }
}
