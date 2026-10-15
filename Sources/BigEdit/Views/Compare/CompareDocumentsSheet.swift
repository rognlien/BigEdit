import AppKit

/// What the Compare Documents sheet asks for: the two lists and how their
/// lines are matched.
struct CompareRequest {
    let first: OtherLineList
    let second: OtherLineList
    let options: LineMatchOptions
}

/// Picks two open documents to compare, and how to match their lines.
final class CompareDocumentsSheet: NSObject {

    private static let contentSize = NSSize(width: 460, height: 268)

    private let window: NSWindow
    private let firstPopUp = NSPopUpButton()
    private let secondPopUp = NSPopUpButton()
    private let patternField = NSTextField()
    private let trimCheckbox = NSButton()
    private let ignoreCaseCheckbox = NSButton()
    private let compareButton = NSButton()
    private let cancelButton = NSButton()

    private var lists: [OtherLineList] = []
    private var completion: ((CompareRequest?) -> Void)?

    override init() {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CompareDocumentsSheet.contentSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildContents()
    }

    /// Shows the sheet on `parent` over `lists` — the open documents, in
    /// sidebar order — with `activeIndex` preselected as the first list and
    /// the next document as the second.
    func present(in parent: NSWindow, lists: [OtherLineList], activeIndex: Int,
                 completion: @escaping (CompareRequest?) -> Void) {
        self.completion = completion
        self.lists = lists
        for popUp in [firstPopUp, secondPopUp] {
            popUp.removeAllItems()
            popUp.addItems(withTitles: lists.map(\.name))
        }
        let first = lists.indices.contains(activeIndex) ? activeIndex : 0
        let second = lists.count > 1 ? (first + 1) % lists.count : first
        firstPopUp.selectItem(at: first)
        secondPopUp.selectItem(at: second)
        parent.beginSheet(window) { _ in }
    }

    // MARK: - Building

    private func buildContents() {
        let content = NSView(frame: NSRect(origin: .zero, size: CompareDocumentsSheet.contentSize))
        window.contentView = content

        let title = NSTextField(labelWithString: "Compare Documents")
        title.font = NSFont.boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 234, width: 300, height: 20)
        content.addSubview(title)

        content.addSubview(makeLabel("First", y: 212))
        firstPopUp.frame = NSRect(x: 20, y: 186, width: 420, height: 25)
        content.addSubview(firstPopUp)

        content.addSubview(makeLabel("Second", y: 164))
        secondPopUp.frame = NSRect(x: 20, y: 138, width: 420, height: 25)
        content.addSubview(secondPopUp)

        content.addSubview(makeLabel("Compare by (optional regular expression — its first group, if any)", y: 116))
        patternField.frame = NSRect(x: 20, y: 92, width: 420, height: 22)
        content.addSubview(patternField)

        configureCheckbox(trimCheckbox, title: "Ignore surrounding whitespace", y: 64)
        content.addSubview(trimCheckbox)
        configureCheckbox(ignoreCaseCheckbox, title: "Ignore case", y: 42)
        content.addSubview(ignoreCaseCheckbox)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 248, y: 14, width: 90, height: 32)
        content.addSubview(cancelButton)

        compareButton.title = "Compare"
        compareButton.bezelStyle = .rounded
        compareButton.target = self
        compareButton.action = #selector(compareTapped)
        compareButton.keyEquivalent = "\r"
        compareButton.frame = NSRect(x: 346, y: 14, width: 94, height: 32)
        content.addSubview(compareButton)
    }

    private func makeLabel(_ text: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: y, width: 420, height: 16)
        return label
    }

    private func configureCheckbox(_ checkbox: NSButton, title: String, y: CGFloat) {
        checkbox.setButtonType(.switch)
        checkbox.title = title
        checkbox.font = NSFont.systemFont(ofSize: 11)
        checkbox.frame = NSRect(x: 20, y: y, width: 260, height: 20)
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        finish(with: nil)
    }

    @objc private func compareTapped() {
        let first = firstPopUp.indexOfSelectedItem
        let second = secondPopUp.indexOfSelectedItem
        guard lists.indices.contains(first), lists.indices.contains(second) else {
            NSSound.beep()
            return
        }
        let pattern = patternField.stringValue
        let options = LineMatchOptions(
            trimsWhitespace: trimCheckbox.state == .on,
            ignoresCase: ignoreCaseCheckbox.state == .on,
            keyPattern: pattern.isEmpty ? nil : pattern)
        finish(with: CompareRequest(first: lists[first], second: lists[second], options: options))
    }

    private func finish(with request: CompareRequest?) {
        window.sheetParent?.endSheet(window)
        completion?(request)
        completion = nil
    }
}
