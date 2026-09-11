import AppKit

/// A small modal sheet shown while a `FileWriter` save is running: title,
/// progress bar, percentage, and a Cancel button.
final class SaveProgressSheet: NSObject {

    let window: NSWindow

    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let progressBar: NSProgressIndicator
    private let cancelButton: NSButton

    /// Invoked when the user clicks Cancel.
    var onCancel: (() -> Void)?

    convenience init(fileName: String) {
        self.init(title: "Saving \(fileName)…")
    }

    init(title: String) {
        let contentRect = NSRect(x: 0, y: 0, width: 420, height: 130)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        detailLabel = NSTextField(labelWithString: "0%")
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0

        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"  // Escape

        super.init()

        let content = NSView(frame: contentRect)
        content.addSubview(titleLabel)
        content.addSubview(progressBar)
        content.addSubview(detailLabel)
        content.addSubview(cancelButton)

        let pad: CGFloat = 20
        titleLabel.frame = NSRect(x: pad, y: 92, width: contentRect.width - 2 * pad, height: 18)
        progressBar.frame = NSRect(x: pad, y: 62, width: contentRect.width - 2 * pad, height: 20)
        detailLabel.frame = NSRect(x: pad, y: 38, width: 200, height: 16)
        cancelButton.frame = NSRect(x: contentRect.width - pad - 90, y: 12, width: 90, height: 32)

        window.contentView = content
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
    }

    /// Updates the progress bar and the percentage label.
    func setProgress(_ fraction: Double) {
        progressBar.doubleValue = fraction
        detailLabel.stringValue = "\(Int(fraction * 100))%"
    }

    @objc private func cancelTapped() {
        cancelButton.isEnabled = false
        detailLabel.stringValue = "Cancelling…"
        onCancel?()
    }
}
