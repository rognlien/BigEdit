import AppKit

/// A list of lines a set operation compares the document against: another
/// open document, or a file chosen from disk. The lines are loaded when the
/// operation runs, off the main thread, so a large list does not stall the
/// sheet; `nil` means the source could not be read.
struct OtherLineList {
    let name: String
    let loadLines: () -> [String]?

    /// The lines of an open document, read through its unsaved edits.
    static func document(named name: String, _ document: EditedDocument) -> OtherLineList {
        OtherLineList(name: name) {
            LineDocument(bytes: document.bytes(in: 0..<document.length),
                         newline: document.newlineBytes).lines
        }
    }

    /// The lines of a file on disk.
    static func file(at url: URL) -> OtherLineList {
        OtherLineList(name: url.lastPathComponent) {
            guard let file = MappedFile(path: url.path) else {
                return nil
            }
            return LineDocument(bytes: Array(file.buffer), newline: [0x0A]).lines
        }
    }
}

/// What the Process Lines sheet asks for: a plain line operation, or a set
/// operation whose other list still has to be loaded.
enum ProcessLinesRequest {
    case operation(LineOperation)
    case setOperation(SetOperationKind, other: OtherLineList, options: LineMatchOptions)
}

/// Asks which line operation to run, and with what pattern.
///
/// The operations rewrite the whole document, so the sheet stays deliberately
/// plain: pick one, fill in what it needs, press Process. What each field
/// means changes with the operation, and fields that do not apply are hidden
/// rather than disabled — an empty box that does nothing is worse than no box.
final class ProcessLinesSheet: NSObject {

    /// The operations offered, in menu order.
    private enum Choice: Int, CaseIterable {
        case removeDuplicates
        case removeContaining
        case keepContaining
        case sort
        case naturalSort
        case replaceWithin
        case subtract
        case intersect
        case union
        case symmetricDifference

        var title: String {
            switch self {
            case .removeDuplicates: return "Remove duplicate lines"
            case .removeContaining: return "Remove lines containing…"
            case .keepContaining: return "Keep only lines containing…"
            case .sort: return "Sort lines"
            case .naturalSort: return "Sort lines naturally (file9 before file10)"
            case .replaceWithin: return "Replace within each line (regular expression)"
            case .subtract: return SetOperationKind.subtract.title
            case .intersect: return SetOperationKind.intersect.title
            case .union: return SetOperationKind.union.title
            case .symmetricDifference: return SetOperationKind.symmetricDifference.title
            }
        }

        /// The set operation this choice stands for, if it is one.
        var setOperation: SetOperationKind? {
            switch self {
            case .subtract: return .subtract
            case .intersect: return .intersect
            case .union: return .union
            case .symmetricDifference: return .symmetricDifference
            default: return nil
            }
        }

        /// What the first text field means here, or `nil` when it is not used.
        var patternLabel: String? {
            switch self {
            case .removeDuplicates: return nil
            case .removeContaining, .keepContaining: return "Text"
            case .sort, .naturalSort: return "Sort by (optional regular expression)"
            case .replaceWithin: return "Find (regular expression)"
            case .subtract, .intersect, .union, .symmetricDifference:
                return "Compare by (optional regular expression — its first group, if any)"
            }
        }

        var usesReplacement: Bool {
            self == .replaceWithin
        }

        var usesCaseSensitivity: Bool {
            self == .removeContaining || self == .keepContaining
        }

        var usesOtherList: Bool {
            setOperation != nil
        }
    }

    private static let contentSize = NSSize(width: 460, height: 300)

    private let window: NSWindow
    private let operationPopUp = NSPopUpButton()
    private let otherListLabel = NSTextField(labelWithString: "Other list")
    private let otherListPopUp = NSPopUpButton()
    private let patternLabel = NSTextField(labelWithString: "")
    private let patternField = NSTextField()
    private let replacementLabel = NSTextField(labelWithString: "Replace with")
    private let replacementField = NSTextField()
    private let caseCheckbox = NSButton()
    private let trimCheckbox = NSButton()
    private let ignoreCaseCheckbox = NSButton()
    private let processButton = NSButton()
    private let cancelButton = NSButton()

    /// The lists the other-list menu offers, in menu order. A file chosen
    /// from disk is inserted at the front.
    private var otherLists: [OtherLineList] = []
    private var chosenFile: OtherLineList?

    /// Called with the chosen operation, or `nil` if the user cancelled.
    private var completion: ((ProcessLinesRequest?) -> Void)?

    override init() {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: ProcessLinesSheet.contentSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildContents()
    }

    /// Shows the sheet on `parent` and reports the chosen operation.
    /// `otherLists` are the open documents a set operation may compare
    /// against; a file from disk can always be chosen as well.
    func present(in parent: NSWindow, otherLists: [OtherLineList] = [],
                 completion: @escaping (ProcessLinesRequest?) -> Void) {
        self.completion = completion
        self.otherLists = otherLists
        rebuildOtherListMenu(selecting: 0)
        applyChoiceVisibility()
        parent.beginSheet(window) { _ in }
        window.makeFirstResponder(patternField)
    }

    // MARK: - Building

    private func buildContents() {
        // Laid out with explicit frames from the bottom up, so every control
        // has to sit inside the content height set above (300pt).
        let content = NSView(frame: NSRect(origin: .zero, size: ProcessLinesSheet.contentSize))
        window.contentView = content

        let title = NSTextField(labelWithString: "Process Lines")
        title.font = NSFont.boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 266, width: 300, height: 20)
        content.addSubview(title)

        operationPopUp.addItems(withTitles: Choice.allCases.map(\.title))
        operationPopUp.target = self
        operationPopUp.action = #selector(operationChanged)
        operationPopUp.frame = NSRect(x: 20, y: 232, width: 420, height: 25)
        content.addSubview(operationPopUp)

        configureLabel(otherListLabel, y: 210)
        content.addSubview(otherListLabel)

        otherListPopUp.target = self
        otherListPopUp.action = #selector(otherListChanged)
        otherListPopUp.frame = NSRect(x: 20, y: 186, width: 420, height: 25)
        content.addSubview(otherListPopUp)

        configureLabel(patternLabel, y: 162)
        content.addSubview(patternLabel)

        patternField.frame = NSRect(x: 20, y: 138, width: 420, height: 22)
        content.addSubview(patternField)

        configureLabel(replacementLabel, y: 114)
        content.addSubview(replacementLabel)

        replacementField.frame = NSRect(x: 20, y: 90, width: 420, height: 22)
        content.addSubview(replacementField)

        configureCheckbox(caseCheckbox, title: "Match case", y: 112)
        content.addSubview(caseCheckbox)

        configureCheckbox(trimCheckbox, title: "Ignore surrounding whitespace", y: 112)
        content.addSubview(trimCheckbox)

        configureCheckbox(ignoreCaseCheckbox, title: "Ignore case", y: 88)
        content.addSubview(ignoreCaseCheckbox)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"                 // Esc
        cancelButton.frame = NSRect(x: 248, y: 18, width: 90, height: 32)
        content.addSubview(cancelButton)

        processButton.title = "Process"
        processButton.bezelStyle = .rounded
        processButton.target = self
        processButton.action = #selector(processTapped)
        processButton.keyEquivalent = "\r"
        processButton.frame = NSRect(x: 346, y: 18, width: 94, height: 32)
        content.addSubview(processButton)
    }

    private func configureLabel(_ label: NSTextField, y: CGFloat) {
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: y, width: 420, height: 16)
    }

    private func configureCheckbox(_ checkbox: NSButton, title: String, y: CGFloat) {
        checkbox.setButtonType(.switch)
        checkbox.title = title
        checkbox.font = NSFont.systemFont(ofSize: 11)
        checkbox.frame = NSRect(x: 20, y: y, width: 260, height: 20)
    }

    /// The other-list menu: a chosen file first, then every other open
    /// document, then the item that picks a file.
    private func rebuildOtherListMenu(selecting index: Int) {
        otherListPopUp.removeAllItems()
        for list in availableLists {
            otherListPopUp.addItem(withTitle: list.name)
        }
        if !availableLists.isEmpty {
            otherListPopUp.menu?.addItem(NSMenuItem.separator())
        }
        otherListPopUp.addItem(withTitle: "Choose File…")
        if index < availableLists.count {
            otherListPopUp.selectItem(at: index)
        }
    }

    private var availableLists: [OtherLineList] {
        if let chosenFile {
            return [chosenFile] + otherLists
        }
        return otherLists
    }

    /// The list the menu currently names, or `nil` while only "Choose File…"
    /// is there.
    private var selectedOtherList: OtherLineList? {
        let index = otherListPopUp.indexOfSelectedItem
        return availableLists.indices.contains(index) ? availableLists[index] : nil
    }

    private var choice: Choice {
        Choice(rawValue: operationPopUp.indexOfSelectedItem) ?? .removeDuplicates
    }

    @objc private func operationChanged() {
        applyChoiceVisibility()
    }

    /// "Choose File…" is the last item: picking it opens a panel over the
    /// sheet, and the file it returns becomes the selected list.
    @objc private func otherListChanged() {
        guard otherListPopUp.indexOfSelectedItem == otherListPopUp.numberOfItems - 1 else {
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the list of lines to compare against."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                self.chosenFile = OtherLineList.file(at: url)
            }
            // A chosen file is first in the menu; without one the first
            // open document is selected again, or nothing when there is none.
            self.rebuildOtherListMenu(selecting: 0)
            self.applyChoiceVisibility()
        }
    }

    /// Shows only the fields the chosen operation actually reads.
    private func applyChoiceVisibility() {
        let current = choice
        let showsPattern = current.patternLabel != nil
        patternLabel.stringValue = current.patternLabel ?? ""
        patternLabel.isHidden = !showsPattern
        patternField.isHidden = !showsPattern
        replacementLabel.isHidden = !current.usesReplacement
        replacementField.isHidden = !current.usesReplacement
        caseCheckbox.isHidden = !current.usesCaseSensitivity
        otherListLabel.isHidden = !current.usesOtherList
        otherListPopUp.isHidden = !current.usesOtherList
        trimCheckbox.isHidden = !current.usesOtherList
        ignoreCaseCheckbox.isHidden = !current.usesOtherList
        processButton.isEnabled = !current.usesOtherList || selectedOtherList != nil
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        finish(with: nil)
    }

    @objc private func processTapped() {
        if let request = request() {
            finish(with: request)
        } else {
            NSSound.beep()
        }
    }

    /// The request described by the current fields, or `nil` when a set
    /// operation has no list to compare against yet.
    private func request() -> ProcessLinesRequest? {
        let pattern = patternField.stringValue
        let caseSensitive = caseCheckbox.state == .on
        var result: ProcessLinesRequest?
        switch choice {
        case .removeDuplicates:
            result = .operation(.removeDuplicateLines)
        case .removeContaining:
            result = .operation(.removeLinesContaining(pattern: pattern, caseSensitive: caseSensitive))
        case .keepContaining:
            result = .operation(.keepLinesContaining(pattern: pattern, caseSensitive: caseSensitive))
        case .sort:
            result = .operation(.sortLines(natural: false, keyPattern: pattern.isEmpty ? nil : pattern))
        case .naturalSort:
            result = .operation(.sortLines(natural: true, keyPattern: pattern.isEmpty ? nil : pattern))
        case .replaceWithin:
            result = .operation(.replaceWithinLines(pattern: pattern,
                                                    replacement: replacementField.stringValue))
        case .subtract, .intersect, .union, .symmetricDifference:
            if let kind = choice.setOperation, let other = selectedOtherList {
                let options = LineMatchOptions(
                    trimsWhitespace: trimCheckbox.state == .on,
                    ignoresCase: ignoreCaseCheckbox.state == .on,
                    keyPattern: pattern.isEmpty ? nil : pattern)
                result = .setOperation(kind, other: other, options: options)
            }
        }
        return result
    }

    private func finish(with request: ProcessLinesRequest?) {
        window.sheetParent?.endSheet(window)
        completion?(request)
        completion = nil
    }
}
