import AppKit

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

        var title: String {
            switch self {
            case .removeDuplicates: return "Remove duplicate lines"
            case .removeContaining: return "Remove lines containing…"
            case .keepContaining: return "Keep only lines containing…"
            case .sort: return "Sort lines"
            case .naturalSort: return "Sort lines naturally (file9 before file10)"
            case .replaceWithin: return "Replace within each line (regular expression)"
            }
        }

        /// What the first text field means here, or `nil` when it is not used.
        var patternLabel: String? {
            switch self {
            case .removeDuplicates: return nil
            case .removeContaining, .keepContaining: return "Text"
            case .sort, .naturalSort: return "Sort by (optional regular expression)"
            case .replaceWithin: return "Find (regular expression)"
            }
        }

        var usesReplacement: Bool {
            self == .replaceWithin
        }

        var usesCaseSensitivity: Bool {
            self == .removeContaining || self == .keepContaining
        }
    }

    private let window: NSWindow
    private let operationPopUp = NSPopUpButton()
    private let patternLabel = NSTextField(labelWithString: "")
    private let patternField = NSTextField()
    private let replacementLabel = NSTextField(labelWithString: "Replace with")
    private let replacementField = NSTextField()
    private let caseCheckbox = NSButton()
    private let processButton = NSButton()
    private let cancelButton = NSButton()

    /// Called with the chosen operation, or `nil` if the user cancelled.
    private var completion: ((LineOperation?) -> Void)?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 232),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildContents()
    }

    /// Shows the sheet on `parent` and reports the chosen operation.
    func present(in parent: NSWindow, completion: @escaping (LineOperation?) -> Void) {
        self.completion = completion
        applyChoiceVisibility()
        parent.beginSheet(window) { _ in }
        window.makeFirstResponder(patternField)
    }

    // MARK: - Building

    private func buildContents() {
        // Laid out with explicit frames from the bottom up, so every control
        // has to sit inside the content height set above (232pt).
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 232))
        window.contentView = content

        let title = NSTextField(labelWithString: "Process Lines")
        title.font = NSFont.boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 198, width: 300, height: 20)
        content.addSubview(title)

        operationPopUp.addItems(withTitles: Choice.allCases.map(\.title))
        operationPopUp.target = self
        operationPopUp.action = #selector(operationChanged)
        operationPopUp.frame = NSRect(x: 20, y: 164, width: 420, height: 25)
        content.addSubview(operationPopUp)

        patternLabel.font = NSFont.systemFont(ofSize: 11)
        patternLabel.textColor = .secondaryLabelColor
        patternLabel.frame = NSRect(x: 20, y: 142, width: 420, height: 16)
        content.addSubview(patternLabel)

        patternField.frame = NSRect(x: 20, y: 118, width: 420, height: 22)
        content.addSubview(patternField)

        replacementLabel.font = NSFont.systemFont(ofSize: 11)
        replacementLabel.textColor = .secondaryLabelColor
        replacementLabel.frame = NSRect(x: 20, y: 94, width: 420, height: 16)
        content.addSubview(replacementLabel)

        replacementField.frame = NSRect(x: 20, y: 70, width: 420, height: 22)
        content.addSubview(replacementField)

        caseCheckbox.setButtonType(.switch)
        caseCheckbox.title = "Match case"
        caseCheckbox.font = NSFont.systemFont(ofSize: 11)
        caseCheckbox.frame = NSRect(x: 20, y: 92, width: 140, height: 20)
        content.addSubview(caseCheckbox)

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

    private var choice: Choice {
        Choice(rawValue: operationPopUp.indexOfSelectedItem) ?? .removeDuplicates
    }

    @objc private func operationChanged() {
        applyChoiceVisibility()
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
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        finish(with: nil)
    }

    @objc private func processTapped() {
        finish(with: operation())
    }

    /// The operation described by the current fields.
    private func operation() -> LineOperation {
        let pattern = patternField.stringValue
        let caseSensitive = caseCheckbox.state == .on
        var result: LineOperation
        switch choice {
        case .removeDuplicates:
            result = .removeDuplicateLines
        case .removeContaining:
            result = .removeLinesContaining(pattern: pattern, caseSensitive: caseSensitive)
        case .keepContaining:
            result = .keepLinesContaining(pattern: pattern, caseSensitive: caseSensitive)
        case .sort:
            result = .sortLines(natural: false, keyPattern: pattern.isEmpty ? nil : pattern)
        case .naturalSort:
            result = .sortLines(natural: true, keyPattern: pattern.isEmpty ? nil : pattern)
        case .replaceWithin:
            result = .replaceWithinLines(pattern: pattern,
                                         replacement: replacementField.stringValue)
        }
        return result
    }

    private func finish(with operation: LineOperation?) {
        window.sheetParent?.endSheet(window)
        completion?(operation)
        completion = nil
    }
}
