import Foundation

/// A regular-expression find-and-replace: the compiled pattern and the
/// template (`$1`-style) each match is replaced with.
struct RegexReplacementRule {

    let pattern: String
    let template: String
    let options: NSRegularExpression.Options
    let expression: NSRegularExpression

    /// `nil` when the pattern does not compile.
    init?(pattern: String, template: String, options: NSRegularExpression.Options = [.anchorsMatchLines]) {
        guard !pattern.isEmpty,
              let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        self.pattern = pattern
        self.template = template
        self.options = options
        self.expression = compiled
    }

    /// `text` with every match replaced, and how many there were.
    func apply(to text: String) -> (text: String, count: Int) {
        let whole = NSRange(location: 0, length: text.utf16.count)
        let count = expression.numberOfMatches(in: text, range: whole)
        if count == 0 {
            return (text, 0)
        }
        return (expression.stringByReplacingMatches(in: text, range: whole, withTemplate: template), count)
    }
}

/// Streams a document to a file with a regular expression replaced
/// throughout — the form of Replace All with no cap on the match count.
///
/// The document is read in windows cut at line boundaries, each decoded,
/// rewritten with the template, and written out; nothing is held beyond a
/// window. As with search, a match cannot span two windows, so a pattern
/// that matches across lines reaches as far as one window (a few MB of
/// lines), which is not a limit anyone meets. A window that is not valid
/// UTF-8 falls back to line by line, and a line that does not decode is
/// copied through untouched rather than rewritten with substitutions.
extension FileWriter {

    /// Writes `document` to `destination` with `rule` applied. Runs on a
    /// background queue; callbacks fire on the main queue, `completion`
    /// with the number of replacements made.
    static func save(
        document: EditedDocument,
        regexRule rule: RegexReplacementRule,
        to destination: URL,
        cancelToken: CancelToken,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Int, WriteError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = replace(in: document, rule: rule, to: destination, cancelToken: cancelToken) { fraction in
                DispatchQueue.main.async { onProgress(fraction) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The same on the calling thread, for tests and `--replace-regex`.
    static func saveSynchronously(
        document: EditedDocument,
        regexRule rule: RegexReplacementRule,
        to destination: URL,
        cancelToken: CancelToken = CancelToken(),
        windowSize: Int = lineFilterWindow
    ) -> Result<Int, WriteError> {
        replace(in: document, rule: rule, to: destination, cancelToken: cancelToken,
                windowSize: windowSize, onProgress: { _ in })
    }

    private static func replace(
        in document: EditedDocument,
        rule: RegexReplacementRule,
        to destination: URL,
        cancelToken: CancelToken,
        windowSize: Int = lineFilterWindow,
        onProgress: (Double) -> Void
    ) -> Result<Int, WriteError> {
        var replaced = 0
        let outcome = performWrite(destination: destination) { descriptor in
            streamReplacing(fd: descriptor, document: document, rule: rule, cancelToken: cancelToken,
                            windowSize: windowSize, replaced: &replaced, onProgress: onProgress)
        }
        switch outcome {
        case .success:
            return .success(replaced)
        case .failure(let error):
            return .failure(error)
        }
    }

    private static func streamReplacing(
        fd: Int32,
        document: EditedDocument,
        rule: RegexReplacementRule,
        cancelToken: CancelToken,
        windowSize: Int,
        replaced: inout Int,
        onProgress: (Double) -> Void
    ) -> Result<Void, WriteError> {
        let total = document.length
        var cursor = 0
        var result: Result<Void, WriteError> = .success(())

        while cursor < total {
            if cancelToken.isCancelled {
                result = .failure(.cancelled)
                break
            }
            let window = nextLineWindow(in: document, from: cursor, total: total, windowSize: windowSize)
            let rewritten = rewrite(window.bytes, rule: rule, replaced: &replaced)
            result = rewritten.withUnsafeBytes { raw -> Result<Void, WriteError> in
                guard let pointer = raw.baseAddress, raw.count > 0 else {
                    return .success(())
                }
                return writeBytes(fd: fd, pointer: pointer, count: raw.count)
            }
            if case .failure = result {
                break
            }
            cursor = window.end
            onProgress(Double(cursor) / Double(total))
        }
        if case .success = result {
            onProgress(1.0)
        }
        return result
    }

    /// The window with the rule applied: whole when it decodes, else line
    /// by line with undecodable lines copied through.
    static func rewrite(_ bytes: [UInt8], rule: RegexReplacementRule, replaced: inout Int) -> [UInt8] {
        if let text = String(validatingUTF8Bytes: bytes) {
            let outcome = rule.apply(to: text)
            replaced += outcome.count
            return outcome.count == 0 ? bytes : Array(outcome.text.utf8)
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var lineStart = 0
        func emit(_ range: Range<Int>) {
            let slice = bytes[range]
            if let line = String(validatingUTF8Bytes: slice) {
                let outcome = rule.apply(to: line)
                replaced += outcome.count
                if outcome.count == 0 {
                    output.append(contentsOf: slice)
                } else {
                    output.append(contentsOf: Array(outcome.text.utf8))
                }
            } else {
                output.append(contentsOf: slice)
            }
        }
        for (position, byte) in bytes.enumerated() where byte == 0x0A {
            emit(lineStart..<(position + 1))
            lineStart = position + 1
        }
        if lineStart < bytes.count {
            emit(lineStart..<bytes.count)
        }
        return output
    }
}

private extension String {
    /// The bytes as a string, or `nil` if they are not valid UTF-8 — no
    /// replacement characters are ever substituted.
    init?<Bytes: Collection>(validatingUTF8Bytes bytes: Bytes) where Bytes.Element == UInt8 {
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                scalars.append(scalar)
            case .emptyInput:
                break decoding
            case .error:
                return nil
            }
        }
        self = String(scalars)
    }
}
