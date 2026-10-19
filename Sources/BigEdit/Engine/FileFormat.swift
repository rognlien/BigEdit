import Foundation

/// A best-effort description of a file's text encoding and line endings, judged
/// from bounded samples (so it stays cheap on multi-gigabyte files).
///
/// BigEdit decodes everything as UTF-8; this is for *labelling* only, so the
/// user can tell when a file isn't UTF-8 and the on-screen text may be garbled.
struct FileFormat {

    let encoding: String
    let lineEnding: String

    /// The encoding the bytes are decoded with, or `nil` when they are not
    /// decoded at all (binary, or UTF-16, which is labelled but not read).
    let textEncoding: TextEncoding?

    /// Whether the content is UTF-8.
    var isUTF8: Bool { textEncoding == .utf8 }

    private static let sampleLimit = 64 * 1024

    /// How many windows of `sampleLimit` bytes a file too large to validate
    /// whole is sampled at, so at most a megabyte is read whatever its size.
    private static let sampleWindowCount = 16

    init(scanning file: MappedFile) {
        let buffer = file.buffer
        let count = min(buffer.count, FileFormat.sampleLimit)

        let detected = FileFormat.detectEncoding(buffer, headCount: count)
        encoding = detected.label
        textEncoding = detected.encoding
        lineEnding = FileFormat.detectLineEnding(buffer, count: count)
    }

    private init(encoding: String, lineEnding: String, textEncoding: TextEncoding?) {
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.textEncoding = textEncoding
    }

    /// This format, but in `previous`'s single-byte encoding where the scan
    /// took the bytes for UTF-8. For a file BigEdit has just written from a
    /// single-byte document that is still what the bytes are in — the
    /// samples may simply have no byte above 0x7F left in them.
    func keepingSingleByteEncoding(of previous: FileFormat) -> FileFormat {
        var result = self
        if let kept = previous.textEncoding, kept.isSingleByte, isUTF8 {
            result = FileFormat(encoding: previous.encoding, lineEnding: lineEnding, textEncoding: kept)
        }
        return result
    }

    /// Text that is neither UTF-8 nor binary is read as Windows-1252: the
    /// superset of Latin-1 that legacy logs and exports on every platform
    /// actually use, and one in which every byte decodes to something. Byte
    /// order marks and the null bytes of binary are looked for in the head;
    /// invalid UTF-8 in every sample window.
    private static func detectEncoding(_ buffer: UnsafeRawBufferPointer, headCount count: Int)
        -> (label: String, encoding: TextEncoding?) {
        if count >= 2, buffer[0] == 0xFF, buffer[1] == 0xFE { return ("UTF-16 LE", nil) }
        if count >= 2, buffer[0] == 0xFE, buffer[1] == 0xFF { return ("UTF-16 BE", nil) }
        if count >= 3, buffer[0] == 0xEF, buffer[1] == 0xBB, buffer[2] == 0xBF {
            return ("UTF-8", .utf8)
        }

        for i in 0..<count where buffer[i] == 0x00 {
            _ = i
            return ("Binary", nil)
        }

        let windows = sampleWindows(inFileOf: buffer.count)
        if windows.allSatisfy({ isValidUTF8(buffer, in: $0) }) {
            return ("UTF-8", .utf8)
        }
        return (TextEncoding.windows1252.label, .windows1252)
    }

    /// Where a file of `length` bytes is checked for invalid UTF-8: the whole
    /// of a small document, and otherwise the head, the tail and windows
    /// evenly spaced between them, so a legacy byte that first appears deep
    /// in a large file is still likely to be seen.
    static func sampleWindows(inFileOf length: Int) -> [Range<Int>] {
        var result: [Range<Int>]
        if SmallDocument.includes(length: length) {
            result = [0..<length]
        } else {
            let lastStart = length - sampleLimit
            result = (0..<sampleWindowCount).map { index in
                let start = lastStart * index / (sampleWindowCount - 1)
                return start..<(start + sampleLimit)
            }
        }
        return result
    }

    /// Whether the bytes in `window` are valid UTF-8, ignoring a sequence
    /// either of the window's edges cuts short.
    private static func isValidUTF8(_ buffer: UnsafeRawBufferPointer, in window: Range<Int>) -> Bool {
        let start = completeSequenceStart(buffer, from: window.lowerBound)
        let end = max(start, completeSequenceEnd(buffer, upTo: window.upperBound))
        return String(bytes: buffer[start..<end], encoding: .utf8) != nil
    }

    /// `start`, moved past the continuation bytes of a sequence that began
    /// before it. A sequence has at most three, so a fourth is left for
    /// validation to reject.
    private static func completeSequenceStart(_ buffer: UnsafeRawBufferPointer, from start: Int) -> Int {
        var result = start
        if start > 0 {
            while result < start + 3 && result < buffer.count && (buffer[result] & 0xC0) == 0x80 {
                result += 1
            }
        }
        return result
    }

    /// `end`, moved back before a sequence it cuts short. The end of the file
    /// cuts nothing, so a truncated final sequence there stays invalid.
    private static func completeSequenceEnd(_ buffer: UnsafeRawBufferPointer, upTo end: Int) -> Int {
        var result = end
        if result < buffer.count {
            var trim = 0
            while result > 0 && trim < 3 && (buffer[result - 1] & 0xC0) == 0x80 {
                result -= 1
                trim += 1
            }
            if result > 0 && (buffer[result - 1] & 0x80) != 0 {
                result -= 1   // drop a lead byte whose continuations were cut
            }
        }
        return result
    }

    private static func detectLineEnding(_ buffer: UnsafeRawBufferPointer, count: Int) -> String {
        var sawCR = false
        for i in 0..<count {
            if buffer[i] == 0x0A {
                return (i > 0 && buffer[i - 1] == 0x0D) ? "CRLF" : "LF"
            }
            if buffer[i] == 0x0D {
                sawCR = true
            }
        }
        return sawCR ? "CR" : "—"
    }
}
