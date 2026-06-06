import Foundation

/// A best-effort description of a file's text encoding and line endings, judged
/// from a bounded head sample (so it stays cheap on multi-gigabyte files).
///
/// BigEdit decodes everything as UTF-8; this is for *labelling* only, so the
/// user can tell when a file isn't UTF-8 and the on-screen text may be garbled.
struct FileFormat {

    let encoding: String
    let lineEnding: String

    /// Whether the content is something other than plain UTF-8 text.
    var isUTF8: Bool { encoding == "UTF-8" }

    private static let sampleLimit = 64 * 1024

    init(scanning file: MappedFile) {
        let buffer = file.buffer
        let count = min(buffer.count, FileFormat.sampleLimit)

        encoding = FileFormat.detectEncoding(buffer, count: count)
        lineEnding = FileFormat.detectLineEnding(buffer, count: count)
    }

    private static func detectEncoding(_ buffer: UnsafeRawBufferPointer, count: Int) -> String {
        if count >= 2, buffer[0] == 0xFF, buffer[1] == 0xFE { return "UTF-16 LE" }
        if count >= 2, buffer[0] == 0xFE, buffer[1] == 0xFF { return "UTF-16 BE" }
        if count >= 3, buffer[0] == 0xEF, buffer[1] == 0xBB, buffer[2] == 0xBF { return "UTF-8" }

        for i in 0..<count where buffer[i] == 0x00 {
            _ = i
            return "Binary"
        }

        // Validate the sample as UTF-8, trimming any sequence cut at the end.
        var end = count
        if end < buffer.count {
            var trim = 0
            while end > 0 && trim < 3 && (buffer[end - 1] & 0xC0) == 0x80 {
                end -= 1
                trim += 1
            }
            if end > 0 && (buffer[end - 1] & 0x80) != 0 {
                end -= 1   // drop a lead byte whose continuations were cut
            }
        }
        let bytes = Array(UnsafeRawBufferPointer(rebasing: buffer[0..<end]))
        if String(bytes: bytes, encoding: .utf8) != nil {
            return "UTF-8"
        }
        return "Not UTF-8"
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
