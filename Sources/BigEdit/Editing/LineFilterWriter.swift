import Foundation

/// Streams a document to a file, keeping only the lines a predicate accepts.
///
/// This is how a set operation reaches a document larger than the Process
/// Lines ceiling: `subtract` and `intersect` decide each line on its own, so
/// the document is read once in windows cut at line boundaries and never
/// held whole. Kept lines are written byte for byte, terminators included,
/// so a CRLF file stays a CRLF file and nothing is re-encoded. Output goes
/// to a temp file beside the destination and is renamed into place, like
/// every other save.
extension FileWriter {

    /// Each window is cut after its last newline, so a line is never split
    /// between two windows; a line longer than this grows the window.
    static let lineFilterWindow = 4 * 1024 * 1024

    /// Writes the lines of `document` that `keep` accepts to `destination`.
    /// Runs on a background queue; `onProgress` and `completion` fire on
    /// the main queue, the latter with the number of lines kept.
    static func save(
        document: EditedDocument,
        keepingLinesWhere keep: @escaping (String) -> Bool,
        to destination: URL,
        cancelToken: CancelToken,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<Int, WriteError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = filterLines(document: document, keep: keep, to: destination,
                                     cancelToken: cancelToken) { fraction in
                DispatchQueue.main.async { onProgress(fraction) }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The same, synchronously on the calling thread. Used by tests and the
    /// headless commands; `windowSize` is exposed so a test can force a line
    /// window boundary inside a small file.
    static func saveSynchronously(
        document: EditedDocument,
        keepingLinesWhere keep: (String) -> Bool,
        to destination: URL,
        cancelToken: CancelToken = CancelToken(),
        windowSize: Int = lineFilterWindow
    ) -> Result<Int, WriteError> {
        filterLines(document: document, keep: keep, to: destination,
                    cancelToken: cancelToken, windowSize: windowSize, onProgress: { _ in })
    }

    private static func filterLines(
        document: EditedDocument,
        keep: (String) -> Bool,
        to destination: URL,
        cancelToken: CancelToken,
        windowSize: Int = lineFilterWindow,
        onProgress: (Double) -> Void
    ) -> Result<Int, WriteError> {
        var kept = 0
        let outcome = performWrite(destination: destination) { descriptor in
            streamFilteredLines(fd: descriptor, document: document, keep: keep,
                                cancelToken: cancelToken, windowSize: windowSize,
                                keptCount: &kept, onProgress: onProgress)
        }
        switch outcome {
        case .success:
            return .success(kept)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The window loop: read a run of whole lines, test each, write the
    /// survivors in one go.
    private static func streamFilteredLines(
        fd: Int32,
        document: EditedDocument,
        keep: (String) -> Bool,
        cancelToken: CancelToken,
        windowSize: Int,
        keptCount: inout Int,
        onProgress: (Double) -> Void
    ) -> Result<Void, WriteError> {
        let total = document.length
        var cursor = 0
        var result: Result<Void, WriteError> = .success(())
        var output: [UInt8] = []

        while cursor < total {
            if cancelToken.isCancelled {
                result = .failure(.cancelled)
                break
            }
            let window = nextLineWindow(in: document, from: cursor, total: total,
                                        windowSize: windowSize)
            output.removeAll(keepingCapacity: true)
            keptCount += appendKeptLines(of: window.bytes, keep: keep, to: &output)
            result = output.withUnsafeBytes { raw -> Result<Void, WriteError> in
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

    /// The next window starting at `cursor`: grown until it holds a whole
    /// line, then cut after its last newline unless it reaches the end.
    static func nextLineWindow(in document: EditedDocument, from cursor: Int,
                                       total: Int, windowSize: Int) -> (bytes: [UInt8], end: Int) {
        let size = max(1, windowSize)
        var windowEnd = min(total, cursor + size)
        var bytes = document.bytes(in: cursor..<windowEnd)
        while windowEnd < total && !bytes.contains(0x0A) {
            let grownEnd = min(total, windowEnd + max(size, bytes.count))
            bytes.append(contentsOf: document.bytes(in: windowEnd..<grownEnd))
            windowEnd = grownEnd
        }
        if windowEnd < total, let lastNewline = bytes.lastIndex(of: 0x0A) {
            bytes.removeSubrange((lastNewline + 1)...)
            windowEnd = cursor + lastNewline + 1
        }
        return (bytes, windowEnd)
    }

    /// Appends each line of `bytes` that `keep` accepts, terminator and all,
    /// and returns how many were kept. The predicate sees the line as
    /// `LineProcessor` would: decoded, without its CR or LF.
    private static func appendKeptLines(of bytes: [UInt8], keep: (String) -> Bool,
                                        to output: inout [UInt8]) -> Int {
        var kept = 0
        var lineStart = 0
        func consider(lineEnd: Int, terminatorEnd: Int) {
            var textEnd = lineEnd
            if textEnd > lineStart && bytes[textEnd - 1] == 0x0D {
                textEnd -= 1
            }
            let text = String(decoding: bytes[lineStart..<textEnd], as: UTF8.self)
            if keep(text) {
                output.append(contentsOf: bytes[lineStart..<terminatorEnd])
                kept += 1
            }
        }
        for (position, byte) in bytes.enumerated() where byte == 0x0A {
            consider(lineEnd: position, terminatorEnd: position + 1)
            lineStart = position + 1
        }
        if lineStart < bytes.count {
            consider(lineEnd: bytes.count, terminatorEnd: bytes.count)
        }
        return kept
    }
}
