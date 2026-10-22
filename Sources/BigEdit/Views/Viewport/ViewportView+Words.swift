import AppKit

/// Word boundaries as the system text views find them, read from a bounded
/// window around the caret so the cost never grows with the line.
extension ViewportView {

    /// Text around a caret, decoded: where it starts in the document and
    /// where the caret falls in it.
    private struct WordWindow {
        let start: Int
        let text: NSAttributedString
        let caret: Int
    }

    /// How far a word step looks either way; a longer word is stepped over
    /// in parts.
    static let wordLookLength = 4096

    /// The end of the word `offset` is in, or of the next one.
    func nextWordOffset(after offset: Int) -> Int {
        wordOffset(from: offset, forward: true)
    }

    /// The start of the word `offset` is in or after, or of the one before.
    func previousWordOffset(before offset: Int) -> Int {
        wordOffset(from: offset, forward: false)
    }

    private func wordOffset(from offset: Int, forward: Bool) -> Int {
        var result = offset
        if let window = wordWindow(around: offset) {
            let index = wordBoundary(in: window.text, from: window.caret, forward: forward)
            result = window.start + byteLength(of: window.text.string, upTo: index)
        }
        return result
    }

    /// The next boundary from `index` that steps over a letter or digit:
    /// like the system text views, a move skips runs of punctuation,
    /// symbols and spaces rather than stopping at each.
    private func wordBoundary(in text: NSAttributedString, from index: Int, forward: Bool) -> Int {
        var boundary = index
        var steppedOverWord = false
        while !steppedOverWord {
            let next = text.nextWord(from: boundary, forward: forward)
            let stepped = NSRange(location: min(boundary, next), length: abs(next - boundary))
            steppedOverWord = next == boundary
                || (text.string as NSString).substring(with: stepped).rangeOfCharacter(from: .alphanumerics) != nil
            boundary = next
        }
        return boundary
    }

    private func wordWindow(around offset: Int) -> WordWindow? {
        var result: WordWindow?
        if let document {
            var start = max(0, offset - ViewportView.wordLookLength)
            while start < offset, document.isContinuationByte(at: start) {
                start += 1
            }
            var end = min(document.length, offset + ViewportView.wordLookLength)
            while end > offset, document.isContinuationByte(at: end) {
                end -= 1
            }
            let before = textEncoding.decode(document.bytes(in: start..<offset))
            let after = textEncoding.decode(document.bytes(in: offset..<end))
            result = WordWindow(start: start, text: NSAttributedString(string: before + after),
                                caret: before.utf16.count)
        }
        return result
    }

    /// The bytes the first `utf16Count` units of `text` take in the
    /// document's encoding.
    private func byteLength(of text: String, upTo utf16Count: Int) -> Int {
        let end = String.Index(utf16Offset: utf16Count, in: text)
        return text[..<end].unicodeScalars.reduce(0) { $0 + textEncoding.byteLength(of: $1) }
    }
}
