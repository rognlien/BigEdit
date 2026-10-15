import AppKit

/// Asks Apple Intelligence for a pattern from a description, or for an
/// explanation of a pattern, and hands the pattern back when the user
/// takes it.
final class PatternAssistantSheet: NSObject {

    enum Mode {
        /// Describe what to find; the model proposes a pattern.
        case describe(sample: String?)
        /// Explain an existing pattern.
        case explain(pattern: String)
    }

    private static let contentSize = NSSize(width: 520, height: 318)

    private let window: NSWindow
    private let mode: Mode
    private let promptLabel = NSTextField(labelWithString: "")
    private let promptField = NSTextField()
    private let askButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let patternLabel = NSTextField(labelWithString: "Pattern")
    private let patternField = NSTextField()
    private let explanationField = NSTextField(wrappingLabelWithString: "")
    private let useButton = NSButton()
    private let cancelButton = NSButton()

    private var completion: ((String?) -> Void)?
    private var task: Task<Void, Never>?

    init(mode: Mode) {
        self.mode = mode
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: PatternAssistantSheet.contentSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildContents()
    }

    /// Shows the sheet on `parent`; `completion` gets the pattern the user
    /// chose to use, or `nil`.
    func present(in parent: NSWindow, completion: @escaping (String?) -> Void) {
        self.completion = completion
        parent.beginSheet(window) { _ in }
        switch mode {
        case .describe:
            window.makeFirstResponder(promptField)
        case .explain(let pattern):
            patternField.stringValue = pattern
            ask()
        }
    }

    // MARK: - Building

    private func buildContents() {
        let size = PatternAssistantSheet.contentSize
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        let isDescribe: Bool
        if case .describe = mode {
            isDescribe = true
        } else {
            isDescribe = false
        }

        let title = NSTextField(labelWithString: isDescribe ? "Describe a Pattern" : "Explain This Pattern")
        title.font = NSFont.boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 284, width: 400, height: 20)
        content.addSubview(title)

        promptLabel.stringValue = "What should the pattern find? Say it the way you would to a colleague."
        promptLabel.font = NSFont.systemFont(ofSize: 11)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.frame = NSRect(x: 20, y: 260, width: 480, height: 16)
        promptLabel.isHidden = !isDescribe
        content.addSubview(promptLabel)

        promptField.placeholderString = "e.g. lines that start with a timestamp followed by ERROR"
        promptField.frame = NSRect(x: 20, y: 234, width: 380, height: 24)
        promptField.target = self
        promptField.action = #selector(askTapped)
        promptField.isHidden = !isDescribe
        content.addSubview(promptField)

        askButton.title = "Suggest"
        askButton.bezelStyle = .rounded
        askButton.target = self
        askButton.action = #selector(askTapped)
        askButton.frame = NSRect(x: 408, y: 230, width: 92, height: 32)
        askButton.isHidden = !isDescribe
        content.addSubview(askButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 20, y: 200, width: 16, height: 16)
        content.addSubview(spinner)

        patternLabel.font = NSFont.systemFont(ofSize: 11)
        patternLabel.textColor = .secondaryLabelColor
        patternLabel.frame = NSRect(x: 20, y: 200, width: 400, height: 16)
        patternLabel.isHidden = isDescribe
        content.addSubview(patternLabel)

        patternField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        patternField.frame = NSRect(x: 20, y: 174, width: 480, height: 24)
        patternField.isEditable = isDescribe
        content.addSubview(patternField)

        explanationField.font = NSFont.systemFont(ofSize: 12)
        explanationField.textColor = .labelColor
        explanationField.frame = NSRect(x: 20, y: 64, width: 480, height: 100)
        explanationField.isSelectable = true
        content.addSubview(explanationField)

        cancelButton.title = isDescribe ? "Cancel" : "Done"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 300, y: 16, width: 96, height: 32)
        content.addSubview(cancelButton)

        useButton.title = "Use Pattern"
        useButton.bezelStyle = .rounded
        useButton.target = self
        useButton.action = #selector(useTapped)
        useButton.frame = NSRect(x: 404, y: 16, width: 96, height: 32)
        useButton.isEnabled = false
        useButton.isHidden = !isDescribe
        content.addSubview(useButton)
    }

    // MARK: - Asking

    @objc private func askTapped() {
        ask()
    }

    private func ask() {
        task?.cancel()
        spinner.startAnimation(nil)
        askButton.isEnabled = false
        useButton.isEnabled = false
        explanationField.stringValue = ""
        explanationField.textColor = .labelColor
        let mode = self.mode
        let description = promptField.stringValue
        task = Task { @MainActor [weak self] in
            do {
                switch mode {
                case .describe(let sample):
                    let suggestion = try await PatternAssistant.suggestPattern(for: description, sample: sample)
                    self?.show(pattern: suggestion.pattern, explanation: suggestion.explanation)
                case .explain(let pattern):
                    let explanation = try await PatternAssistant.explain(pattern: pattern)
                    self?.show(pattern: pattern, explanation: explanation)
                }
            } catch {
                self?.show(failure: error.localizedDescription)
            }
        }
    }

    /// Fills in the answer, for the task above and for tests.
    func show(pattern: String, explanation: String) {
        spinner.stopAnimation(nil)
        askButton.isEnabled = true
        patternField.stringValue = pattern
        explanationField.stringValue = explanation
        explanationField.textColor = .labelColor
        useButton.isEnabled = !pattern.isEmpty
    }

    func show(failure: String) {
        spinner.stopAnimation(nil)
        askButton.isEnabled = true
        explanationField.stringValue = failure
        explanationField.textColor = .systemRed
        useButton.isEnabled = false
    }

    /// The pattern as shown, for tests.
    var shownPattern: String {
        patternField.stringValue
    }

    var canUsePattern: Bool {
        useButton.isEnabled
    }

    // MARK: - Finishing

    @objc private func cancelTapped() {
        finish(with: nil)
    }

    @objc private func useTapped() {
        let pattern = patternField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(with: pattern.isEmpty ? nil : pattern)
    }

    private func finish(with pattern: String?) {
        task?.cancel()
        window.sheetParent?.endSheet(window)
        completion?(pattern)
        completion = nil
    }
}
