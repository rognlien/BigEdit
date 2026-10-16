import AppKit

/// Text the document's encoding has no way to write.
extension DocumentView {

    /// Explains, the first time in a document, why typed or pasted text was
    /// not inserted; after that the beep alone says it.
    func explainUnrepresentableText(_ text: String) {
        if !hasExplainedUnrepresentableText, let window,
           let character = textEncoding.firstUnrepresentableCharacter(in: text) {
            hasExplainedUnrepresentableText = true
            let alert = NSAlert()
            alert.messageText = "“\(character)” can’t be written in \(textEncoding.label)"
            alert.informativeText = "This document is in \(textEncoding.label), which has no way "
                + "to represent this character, so it was not inserted."
            alert.beginSheetModal(for: window)
        }
    }

    /// The status Replace All shows when its replacement cannot be written
    /// in the document's encoding, or `nil` when it can.
    func unrepresentableReplacementStatus(_ replacement: String) -> String? {
        textEncoding.firstUnrepresentableCharacter(in: replacement).map {
            "“\($0)” can’t be written in \(textEncoding.label)"
        }
    }
}
