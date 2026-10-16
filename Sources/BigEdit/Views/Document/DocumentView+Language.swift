import AppKit

/// Choosing the language a document is coloured as, in place of the one
/// detected from its name and contents.
extension DocumentView {

    /// The language the document is coloured as.
    var language: Language {
        chosenLanguage ?? detectedLanguage
    }

    /// Colours the document as `choice`, or as the detected language for nil.
    func chooseLanguage(_ choice: Language?) {
        chosenLanguage = choice
        viewport.setLanguage(language)
        if let file = mappedFile {
            formatBar.setMarkdownAvailability(
                unavailableReason: DocumentView.markdownUnavailableReason(for: file, language: language))
            if formatBar.mode == .markdown, language != LanguageRegistry.markdown {
                formatBar.setMode(.text)
                formatBar(formatBar, didSelect: .text)
            }
        }
        updateStatusBar()
        rememberViewState()
    }

    /// Automatic, Plain Text and every language, the current choice ticked.
    func languageMenuItems() -> [NSMenuItem] {
        let automatic = languageItem(
            title: "Automatic (\(detectedLanguage.displayName))", identifier: nil)
        let languages = [Language.plain] + LanguageRegistry.all.sorted { $0.displayName < $1.displayName }
        return [automatic, .separator()] + languages.map { languageItem(title: $0.displayName, identifier: $0.identifier) }
    }

    private func languageItem(title: String, identifier: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(languageMenuItemChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = identifier
        item.state = chosenLanguage?.identifier == identifier ? .on : .off
        return item
    }

    @objc private func languageMenuItemChosen(_ sender: NSMenuItem) {
        let identifier = sender.representedObject as? String
        let choice = identifier.flatMap { $0 == Language.plain.identifier ? .plain : LanguageRegistry.language(identifier: $0) }
        chooseLanguage(choice)
    }
}
