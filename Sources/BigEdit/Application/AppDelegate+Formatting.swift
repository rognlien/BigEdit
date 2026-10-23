import AppKit

/// Edit ▸ Format ▸ Pretty Print and Compact, laid out as Settings says.
extension AppDelegate {

    @objc func formatPrettyPrint() {
        formatActiveDocument(.pretty)
    }

    @objc func formatCompact() {
        formatActiveDocument(.compact)
    }

    /// The Format submenu of the Edit menu. Pretty Print takes ⌃⇧I, the
    /// shortcut of Xcode's Format File, which no standard key binding uses.
    func buildFormatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        let prettyPrintItem = NSMenuItem(title: "Pretty Print", action: #selector(formatPrettyPrint),
                                         keyEquivalent: "i")
        prettyPrintItem.keyEquivalentModifierMask = [.control, .shift]
        prettyPrintItem.target = self
        menu.addItem(prettyPrintItem)
        let compactItem = NSMenuItem(title: "Compact", action: #selector(formatCompact), keyEquivalent: "")
        compactItem.target = self
        menu.addItem(compactItem)
        return menu
    }

    private func formatActiveDocument(_ style: FormattingStyle) {
        if let view = activeView, let language = view.formattingLanguage, view.canFormat {
            view.format(style, options: formattingOptions(for: language)) { [weak self] result in
                if case .failure(let error) = result {
                    self?.presentFormattingError(error, language: language)
                }
            }
        } else {
            NSSound.beep()
        }
    }

    private func formattingOptions(for language: FormattingLanguage) -> FormattingOptions {
        language == .json ? settings.jsonFormattingOptions : settings.xmlFormattingOptions
    }

    func presentFormattingError(_ error: FormattingError, language: FormattingLanguage) {
        let line = NumberFormatter.localizedString(from: NSNumber(value: error.line), number: .decimal)
        let column = NumberFormatter.localizedString(from: NSNumber(value: error.column), number: .decimal)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The \(language.displayName) could not be formatted"
        alert.informativeText = "\(error.message) at line \(line), column \(column). Nothing was changed."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }
}
