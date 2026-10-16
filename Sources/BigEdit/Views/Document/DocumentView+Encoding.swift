import AppKit

/// Text the document's encoding has no way to write.
extension DocumentView {

    /// Whether the document is in a single-byte encoding that could be
    /// converted to UTF-8. Not while a deferred replacement rule is shown,
    /// since the conversion writes the document's bytes, not the rule's.
    var canConvertToUTF8: Bool {
        textEncoding.isSingleByte && viewport.document != nil && currentRule == nil
    }

    /// Explains, the first time in a document, why typed or pasted text was
    /// not inserted, and offers the conversion that would let it in; after
    /// that the beep alone says it.
    func explainUnrepresentableText(_ text: String) {
        if !hasExplainedUnrepresentableText, let window,
           let character = textEncoding.firstUnrepresentableCharacter(in: text) {
            hasExplainedUnrepresentableText = true
            let alert = NSAlert()
            alert.messageText = "“\(character)” can’t be written in \(textEncoding.label)"
            alert.informativeText = "This document is in \(textEncoding.label), which has no way "
                + "to represent this character, so it was not inserted. Converting the document "
                + "to UTF-8 lets it hold any character."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Convert to UTF-8…")
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertSecondButtonReturn, let self {
                    (NSApp.delegate as? AppDelegate)?.offerConversionToUTF8(in: self)
                }
            }
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
