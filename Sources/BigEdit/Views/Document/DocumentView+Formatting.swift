import AppKit

/// Edit ▸ Format: pretty printing or compacting the selection, or the whole
/// document when nothing is selected, as one undoable edit. Text that is not
/// valid is left as it was.
///
/// Text up to `formattingInPlaceLimit` is formatted in memory at once.
/// Longer text streams through the add buffer behind a progress sheet, the
/// way a huge paste does, so the document of any size is formatted in place
/// and one ⌘Z still puts it back.
extension DocumentView {

    /// The longest text formatted in memory at once, quick enough to need
    /// no progress sheet. Tests lower it to reach the streamed path.
    static var formattingInPlaceLimit = 4 * 1024 * 1024

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
            if range.count <= DocumentView.formattingInPlaceLimit {
                completion(formatInPlace(range, of: document, with: formatter))
            } else {
                formatStreamed(StreamedFormatting(document: document, range: range), title: language.displayName,
                               with: formatter, completion: completion)
            }
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

    /// Formats off the main thread behind a cancellable progress sheet,
    /// appending the output to the add buffer on the main thread, and then
    /// splices it in. A cancelled run changes nothing and reports success.
    private func formatStreamed(_ streamed: StreamedFormatting, title: String,
                                with formatter: any StreamingFormatter,
                                completion: @escaping (Result<Void, FormattingError>) -> Void) {
        let sheet = SaveProgressSheet(title: "Formatting \(title)…")
        let cancelled = CancelToken()
        sheet.onCancel = { cancelled.cancel() }
        sheet.setProgress(0)
        window?.beginSheet(sheet.window) { _ in }
        let selectsResult = viewport.selectionByteRange != nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result {
                try streamed.run(formatter: formatter, isCancelled: { cancelled.isCancelled },
                                 onProgress: { fraction in DispatchQueue.main.async { sheet.setProgress(fraction) } },
                                 append: { bytes in DispatchQueue.main.sync { streamed.document.appendToAddBuffer(bytes) } })
            }
            DispatchQueue.main.async {
                self?.window?.endSheet(sheet.window)
                self?.finishStreamedFormatting(outcome, of: streamed, selectingResult: selectsResult,
                                               completion: completion)
            }
        }
    }

    private func finishStreamedFormatting(_ outcome: Result<StreamedFormatting.Output?, Error>,
                                          of streamed: StreamedFormatting, selectingResult: Bool,
                                          completion: (Result<Void, FormattingError>) -> Void) {
        switch outcome {
        case .success(let output?) where !output.isUnchanged && viewport.document === streamed.document:
            viewport.replaceFormatted(streamed.range, withAdded: output.added,
                                      containsNewline: output.containsNewline, selectingResult: selectingResult)
            completion(.success(()))
        case .success:
            completion(.success(()))
        case .failure(let error):
            completion(.failure(locatedInDocument(error, formattedFrom: streamed.range.lowerBound)))
        }
    }

    /// `error`, met in text formatted from `start`, with its line and column
    /// counted in the whole document.
    func locatedInDocument(_ error: Error, formattedFrom start: Int) -> FormattingError {
        var located = error as? FormattingError
            ?? FormattingError(message: error.localizedDescription, line: 1, column: 1, offset: 0)
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
