import AppKit

extension DocumentView {

    /// The largest document the line operations will rewrite in place.
    ///
    /// They hold every line at once, which is the one thing BigEdit otherwise
    /// never does. Rather than pretend a 50 GB file can be sorted, the ceiling
    /// is stated and refused above — the same bargain Replace All makes with
    /// its match cap.
    static let processLinesSizeLimit = 32 * 1024 * 1024

    enum ProcessLinesRefusal: Error {
        case notEditable
        case tooLarge(size: Int, limit: Int)
        case cannotReadOtherList(name: String)
    }

    /// Whether Process Lines can run on this document at all. It rewrites
    /// the whole document, which needs no caret, so aligned CSV columns are
    /// no obstacle — a sort by column is the same operation.
    var canProcessLines: Bool {
        viewport.isWholeDocumentReplacementAllowed && viewport.document != nil
    }

    /// Runs `operation` over the whole document and applies the result as one
    /// undoable edit.
    ///
    /// The work happens off the main thread; `completion` reports the new line
    /// count, or the reason it did not run. A cancelled run reports success
    /// with no change.
    func processLines(_ operation: LineOperation,
                      completion: @escaping (Result<Int, Error>) -> Void) {
        if canProcessLines {
            rewriteLines(title: "Processing lines…", completion: completion) { lines, isCancelled in
                try LineProcessor.apply(operation, to: lines, isCancelled: isCancelled)
            }
        } else {
            completion(.failure(ProcessLinesRefusal.notEditable))
        }
    }

    /// Runs a set operation against `other`, loading that list off the main
    /// thread first, and applies the result as one undoable edit.
    func processSetOperation(_ kind: SetOperationKind, other: OtherLineList,
                             options: LineMatchOptions,
                             completion: @escaping (Result<Int, Error>) -> Void) {
        if canProcessLines {
            rewriteLines(title: "Processing lines…", completion: completion) { lines, isCancelled in
                guard let otherLines = other.loadLines() else {
                    throw ProcessLinesRefusal.cannotReadOtherList(name: other.name)
                }
                return try LineProcessor.apply(
                    .setOperation(kind, other: otherLines, options: options),
                    to: lines, isCancelled: isCancelled)
            }
        } else {
            completion(.failure(ProcessLinesRefusal.notEditable))
        }
    }

    /// Whether `kind` can be run on this document by streaming its result to
    /// a new file instead of rewriting it in place — the route for a
    /// document above the Process Lines ceiling. Only the filtering kinds
    /// stream, and nothing about the document has to be editable for it.
    func canStreamSetOperation(_ kind: SetOperationKind) -> Bool {
        kind.isFilter && viewport.document != nil
    }

    /// Streams the lines of the document that survive `kind` against
    /// `other` to `destination`, behind a cancellable progress sheet.
    /// `completion` reports the number of lines written; a cancelled run
    /// reports success with nil.
    func streamSetOperation(_ kind: SetOperationKind, other: OtherLineList,
                            options: LineMatchOptions, to destination: URL,
                            completion: @escaping (Result<Int?, Error>) -> Void) {
        guard let document = viewport.document, canStreamSetOperation(kind) else {
            completion(.failure(ProcessLinesRefusal.notEditable))
            return
        }
        let sheet = SaveProgressSheet(title: "Writing \(destination.lastPathComponent)…")
        let cancelled = CancelToken()
        sheet.onCancel = { cancelled.cancel() }
        sheet.setProgress(0)
        window?.beginSheet(sheet.window) { _ in }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outcome: Result<Int?, Error>
            do {
                guard let otherLines = other.loadLines() else {
                    throw ProcessLinesRefusal.cannotReadOtherList(name: other.name)
                }
                guard let keep = try LineSetOperation.filter(for: kind, other: otherLines,
                                                             options: options) else {
                    throw ProcessLinesRefusal.notEditable
                }
                let written = FileWriter.saveSynchronously(
                    document: document, keepingLinesWhere: keep, to: destination,
                    cancelToken: cancelled)
                switch written {
                case .success(let count):
                    outcome = .success(count)
                case .failure(let error):
                    if case .cancelled = error {
                        outcome = .success(nil)
                    } else {
                        outcome = .failure(error)
                    }
                }
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                self?.window?.endSheet(sheet.window)
                completion(outcome)
            }
        }
    }

    /// Runs `transform` over every line of the document off the main thread,
    /// behind a cancellable progress sheet, and applies its result as one
    /// undoable edit. A nil result means the run was cancelled.
    func rewriteLines(title: String,
                      completion: @escaping (Result<Int, Error>) -> Void,
                      transform: @escaping ([String], _ isCancelled: () -> Bool) throws -> [String]?) {
        guard let document = viewport.document, viewport.isWholeDocumentReplacementAllowed else {
            completion(.failure(ProcessLinesRefusal.notEditable))
            return
        }
        guard document.length <= DocumentView.processLinesSizeLimit else {
            completion(.failure(ProcessLinesRefusal.tooLarge(
                size: document.length, limit: DocumentView.processLinesSizeLimit)))
            return
        }

        let sheet = SaveProgressSheet(title: title)
        let cancelled = CancelToken()
        sheet.onCancel = { cancelled.cancel() }
        sheet.setProgress(0)
        window?.beginSheet(sheet.window) { _ in }

        let bytes = document.bytes(in: 0..<document.length)
        let newline = document.newlineBytes

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lineDocument = LineDocument(bytes: bytes, newline: newline)
            var outcome: Result<[UInt8]?, Error>
            do {
                let processed = try transform(lineDocument.lines, { cancelled.isCancelled })
                outcome = .success(processed.map { lineDocument.bytes(from: $0) })
            } catch {
                outcome = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.window?.endSheet(sheet.window)
                switch outcome {
                case .success(let replacement):
                    if let replacement {
                        self.viewport.replaceEntireDocument(with: replacement)
                        completion(.success(LineDocument(bytes: replacement,
                                                         newline: newline).lines.count))
                    } else {
                        completion(.success(lineDocument.lines.count))   // cancelled
                    }
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
}
