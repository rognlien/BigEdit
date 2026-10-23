import AppKit

/// Edit ▸ Format: pretty printing or compacting the selection, or the whole
/// document when nothing is selected, as one undoable edit. Text that is not
/// valid is left as it was.
extension DocumentView {

    /// The language the document is formatted as, or nil when Format does
    /// not apply to it.
    var formattingLanguage: FormattingLanguage? {
        FormattingLanguage.of(language)
    }

    /// Whether Format can run: an editable JSON or XML document, shown as
    /// text rather than as CSV columns.
    var canFormat: Bool {
        formattingLanguage != nil && viewport.document != nil && viewport.isEditingAllowed
            && formatBar.mode != .csv && !viewport.isCSVRenderingActive
    }

    /// Formats the selection, or the whole document, laid out by `options`
    /// in the document's own line ending and encoding. `completion` reports
    /// where the text stopped being valid, when it did.
    func format(_ style: FormattingStyle, options: FormattingOptions,
                completion: @escaping (Result<Void, FormattingError>) -> Void) {
        if let document = viewport.document, let language = formattingLanguage, canFormat {
            let range = viewport.selectionByteRange ?? 0..<document.length
            var documentOptions = options
            documentOptions.newline = document.newlineBytes
            documentOptions.encoding = textEncoding
            let formatter = language.formatter(style: style, options: documentOptions)
            completion(formatInPlace(range, of: document, with: formatter))
        } else {
            NSSound.beep()
        }
    }

    /// Formats `range` in memory and puts the result in its place, unless
    /// nothing changed.
    private func formatInPlace(_ range: Range<Int>, of document: EditedDocument,
                               with formatter: any StreamingFormatter) -> Result<Void, FormattingError> {
        var formatter = formatter
        var result: Result<Void, FormattingError> = .success(())
        let original = document.bytes(in: range)
        do {
            let formatted = try formatter.format(original)
            if formatted != original {
                viewport.replaceFormatted(range, with: formatted, selectingResult: viewport.selectionByteRange != nil)
            }
        } catch {
            result = .failure(locatedInDocument(error, formattedFrom: range.lowerBound))
        }
        return result
    }

    /// `error`, met in text formatted from `start`, with its line and column
    /// counted in the whole document.
    func locatedInDocument(_ error: Error, formattedFrom start: Int) -> FormattingError {
        var located = error as? FormattingError
            ?? FormattingError(message: "\(error)", line: 1, column: 1, offset: 0)
        if start > 0, let layout = viewport.layout, let document = viewport.document {
            let offset = start + located.offset
            let lineStart = layout.logicalLineStart(containing: offset)
            located = FormattingError(
                message: located.message,
                line: documentLine(forByteOffset: offset, layout: layout) + 1,
                column: DocumentView.characterCount(in: lineStart..<offset, of: document) + 1,
                offset: offset)
        }
        return located
    }

    /// The characters in `range`, read a megabyte at a time.
    private static func characterCount(in range: Range<Int>, of document: EditedDocument) -> Int {
        let chunkLength = 1024 * 1024
        var count = 0
        var start = range.lowerBound
        while start < range.upperBound {
            let end = min(range.upperBound, start + chunkLength)
            let bytes = document.bytes(in: start..<end)
            count += document.encoding.isSingleByte ? bytes.count : bytes.filter { $0 & 0xC0 != 0x80 }.count
            start = end
        }
        return count
    }
}
