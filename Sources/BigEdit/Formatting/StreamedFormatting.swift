import Foundation

/// Formats a range of a document a window at a time into the document's add
/// buffer, so text of any size is formatted with no more than a window of it
/// and of its output in memory; past its spill threshold the add buffer
/// keeps the output on disk.
///
/// The document is not changed: the caller splices the appended bytes in as
/// one edit, as a streamed paste does. Should formatting fail or be
/// cancelled, what was appended is left unreferenced.
struct StreamedFormatting {

    /// The appended output, and whether it holds a line break or differs
    /// from the text it formats.
    struct Output {
        let added: Range<Int>
        let containsNewline: Bool
        let isUnchanged: Bool
    }

    /// Thrown when the add buffer took bytes from elsewhere while formatting
    /// ran, so the output no longer lies in one piece.
    struct Interrupted: LocalizedError {
        var errorDescription: String? {
            "The document changed while it was being formatted"
        }
    }

    static let windowLength = 1024 * 1024

    let document: EditedDocument
    let range: Range<Int>
    var windowLength = StreamedFormatting.windowLength

    /// Formats the range with `formatter`, handing each part of the output
    /// to `append`, which puts it in the add buffer and returns where.
    /// Returns nil when `isCancelled` says to stop, and throws where the
    /// text stops being valid.
    func run(formatter: any StreamingFormatter, isCancelled: () -> Bool,
             onProgress: (Double) -> Void, append: ([UInt8]) -> Range<Int>) throws -> Output? {
        var formatter = formatter
        var sink = Sink(document: document, original: range, addedStart: document.addBuffer.count)
        var cursor = range.lowerBound
        while cursor < range.upperBound && !isCancelled() {
            let end = min(range.upperBound, cursor + max(1, windowLength))
            try formatter.feed(document.bytes(in: cursor..<end)[...])
            try sink.take(formatter.takeOutput(), append: append)
            cursor = end
            onProgress(Double(cursor - range.lowerBound) / Double(max(1, range.count)))
        }
        var output: Output?
        if !isCancelled() {
            try formatter.finish()
            try sink.take(formatter.takeOutput(), append: append)
            output = sink.output()
        }
        return output
    }

    /// Where the output goes, and what has been learned about it so far.
    private struct Sink {
        let document: EditedDocument
        let original: Range<Int>
        let addedStart: Int
        var addedEnd: Int
        var containsNewline = false
        var matchesOriginal = true

        init(document: EditedDocument, original: Range<Int>, addedStart: Int) {
            self.document = document
            self.original = original
            self.addedStart = addedStart
            addedEnd = addedStart
        }

        mutating func take(_ bytes: [UInt8], append: ([UInt8]) -> Range<Int>) throws {
            if !bytes.isEmpty {
                let added = append(bytes)
                guard added.lowerBound == addedEnd else {
                    throw Interrupted()
                }
                compare(bytes, at: original.lowerBound + addedEnd - addedStart)
                containsNewline = containsNewline || bytes.contains(0x0A)
                addedEnd = added.upperBound
            }
        }

        /// Checks the output against the text it replaces, until they differ.
        private mutating func compare(_ bytes: [UInt8], at offset: Int) {
            if matchesOriginal {
                matchesOriginal = offset + bytes.count <= original.upperBound
                    && document.bytes(in: offset..<(offset + bytes.count)) == bytes
            }
        }

        func output() -> Output {
            let added = addedStart..<addedEnd
            return Output(added: added, containsNewline: containsNewline,
                          isUnchanged: matchesOriginal && added.count == original.count)
        }
    }
}
