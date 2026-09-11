import AppKit

/// One entry in the results list: the line a match is on, and a snippet of
/// that line with the match's position within the snippet.
///
/// Built on demand for the rows the table asks for — a search may hold a
/// million matches, and nothing about them is materialised until a row is
/// scrolled into view.
struct SearchResultRow: Equatable {

    /// 1-based, as the gutter numbers lines.
    let lineNumber: Int

    /// The line, or the part of it around the match; leading and trailing
    /// ellipses mark where it was cut.
    let text: String

    /// The match within `text`, in UTF-16 units, for emphasis.
    let matchRange: NSRange

    /// How much of the line is kept before and after the match.
    static let bytesBefore = 80
    static let bytesAfter = 200

    /// The row for `match`, read through `document`'s layout.
    static func make(match: Range<Int>, in document: EditedDocument,
                     encoding: TextEncoding) -> SearchResultRow? {
        let layout = document.layout
        guard document.length > 0, match.lowerBound < document.length else {
            return nil
        }
        let row = layout.visualRow(forLogicalByteOffset: match.lowerBound)
        guard let line = layout.visualLines(forRows: row..<(row + 1)).first else {
            return nil
        }

        let lineRange = line.byteRange
        var start = max(lineRange.lowerBound, match.lowerBound - bytesBefore)
        var end = min(max(lineRange.upperBound, match.upperBound), match.lowerBound + bytesAfter)
        end = max(end, min(match.upperBound, lineRange.upperBound))
        if encoding == .utf8 {
            // Never cut a multi-byte character in half.
            while start > lineRange.lowerBound, let byte = document.byte(at: start), byte & 0xC0 == 0x80 {
                start -= 1
            }
            while end < lineRange.upperBound, let byte = document.byte(at: end), byte & 0xC0 == 0x80 {
                end += 1
            }
        }

        let matchStart = max(start, match.lowerBound)
        let matchEnd = min(end, match.upperBound)
        var prefix = encoding.decode(document.bytes(in: start..<matchStart))
        var matched = encoding.decode(document.bytes(in: matchStart..<matchEnd))
        var suffix = encoding.decode(document.bytes(in: matchEnd..<end))
        if start > lineRange.lowerBound {
            prefix = "…" + prefix
        }
        if end < lineRange.upperBound {
            suffix += "…"
        }
        prefix = SearchResultRow.flattened(prefix)
        matched = SearchResultRow.flattened(matched)
        suffix = SearchResultRow.flattened(suffix)

        return SearchResultRow(
            lineNumber: line.documentLine + 1,
            text: prefix + matched + suffix,
            matchRange: NSRange(location: prefix.utf16.count, length: matched.utf16.count)
        )
    }

    /// A list row is one line, so line breaks inside a snippet — a pattern
    /// that matched across lines — are shown as a symbol rather than breaking
    /// the row, and a CR is dropped as the viewport drops it.
    private static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "⏎")
    }
}

/// A pane below the viewport listing every match of the current search, with
/// its line number and a snippet, so a search with thousands of hits can be
/// read as a list rather than stepped through one ⌘G at a time.
///
/// The table is virtual: rows are built by `rowProvider` only as they come
/// into view. Selecting a row asks the owner to move to that match; the owner
/// keeps the selection in step as ⌘G moves on.
final class SearchResultsPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {

    static let preferredHeight: CGFloat = 200

    /// The most rows listed. A million-row table is possible but pointless to
    /// scroll; the title says when the list is cut.
    static let rowLimit = 100_000

    /// Builds the row at an index, or `nil` if it cannot be shown.
    var rowProvider: ((Int) -> SearchResultRow?)?

    /// The user chose a match.
    var onSelect: ((Int) -> Void)?

    /// The user closed the panel.
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var rowCount = 0
    private var isSelectingProgrammatically = false

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)

        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        if let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") {
            closeButton.image = image
            closeButton.imagePosition = .imageOnly
        } else {
            closeButton.title = "X"
        }
        addSubview(closeButton)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 18
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        layoutChildren()
    }

    required init?(coder: NSCoder) {
        fatalError("SearchResultsPanel is created programmatically")
    }

    // MARK: - Content

    /// Reflects the search's current state: the rows to list and the title.
    func update(matchCount: Int, isComplete: Bool, isTruncated: Bool) {
        rowCount = min(matchCount, SearchResultsPanel.rowLimit)
        let formatted = SearchResultsPanel.numberFormatter.string(from: NSNumber(value: matchCount))
            ?? "\(matchCount)"
        var title: String
        if matchCount == 0 {
            title = isComplete ? "No matches" : "Searching…"
        } else if rowCount < matchCount {
            let listed = SearchResultsPanel.numberFormatter.string(from: NSNumber(value: rowCount))
                ?? "\(rowCount)"
            title = "First \(listed) of \(formatted)\(isTruncated ? "+" : "") matches"
        } else {
            title = "\(formatted) match\(matchCount == 1 ? "" : "es")\(isComplete ? "" : "…")"
        }
        titleLabel.stringValue = title
        tableView.reloadData()
    }

    /// Highlights the row for match `index` without reporting a selection.
    func select(index: Int) {
        isSelectingProgrammatically = true
        if index >= 0 && index < rowCount {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
        isSelectingProgrammatically = false
    }

    var listedRowCount: Int {
        rowCount
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("matchCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? SearchResultsPanel.makeCell(identifier)
        cell.attributedStringValue = attributedText(forRow: row)
        return cell
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return field
    }

    /// `1234  text with the match in bold`.
    private func attributedText(forRow row: Int) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let result = NSMutableAttributedString()
        if let entry = rowProvider?(row) {
            let number = SearchResultsPanel.numberFormatter.string(from: NSNumber(value: entry.lineNumber))
                ?? "\(entry.lineNumber)"
            result.append(NSAttributedString(
                string: "\(number)  ",
                attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            let snippet = NSMutableAttributedString(
                string: entry.text,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            if entry.matchRange.location + entry.matchRange.length <= snippet.length {
                snippet.addAttribute(.font, value: bold, range: entry.matchRange)
            }
            result.append(snippet)
        } else {
            result.append(NSAttributedString(
                string: "—", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        return result
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !isSelectingProgrammatically && tableView.selectedRow >= 0 {
            onSelect?(tableView.selectedRow)
        }
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutChildren()
    }

    private func layoutChildren() {
        let padding: CGFloat = 8
        let headerHeight: CGFloat = 22
        let headerY = bounds.height - headerHeight
        closeButton.frame = NSRect(x: bounds.width - padding - 24, y: headerY, width: 24, height: headerHeight)
        titleLabel.frame = NSRect(x: padding, y: headerY + 3, width: max(0, bounds.width - padding * 2 - 32),
                                  height: 16)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, headerY))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        line.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        line.stroke()
    }
}
