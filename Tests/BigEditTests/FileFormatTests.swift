import XCTest
@testable import BigEdit

/// The status bar labels files by detected encoding and line endings (no
/// decoding), so the bounded head-sample detection must be right.
final class FileFormatTests: XCTestCase {

    private func format(_ data: Data) -> FileFormat? {
        let url = TestHelpers.writeTempFile(data)
        defer { TestHelpers.remove(url) }
        guard let file = MappedFile(path: url.path) else { return nil }
        return FileFormat(scanning: file)
    }

    func testUTF8WithUnixLineEndings() {
        let f = format(Data("hello\nworld\n".utf8))
        XCTAssertEqual(f?.encoding, "UTF-8")
        XCTAssertEqual(f?.lineEnding, "LF")
    }

    func testUTF8WithWindowsLineEndings() {
        let f = format(Data("a\r\nb\r\n".utf8))
        XCTAssertEqual(f?.encoding, "UTF-8")
        XCTAssertEqual(f?.lineEnding, "CRLF")
    }

    func testMultiByteIsStillUTF8() {
        let f = format(Data("Юн Фосэ\n".utf8))
        XCTAssertEqual(f?.encoding, "UTF-8")
    }

    func testUTF16LEBOMDetected() {
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: Array("hi".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        XCTAssertEqual(format(data)?.encoding, "UTF-16 LE")
    }

    func testNullBytesLookBinary() {
        let f = format(Data([0x68, 0x00, 0x69, 0x00]))
        XCTAssertEqual(f?.encoding, "Binary")
    }

    func testInvalidUTF8IsLabelledNotUTF8() {
        // 0xFF mid-stream (not a BOM at the very start before text) is invalid.
        let f = format(Data([0x61, 0x62, 0xFF, 0x63]))
        XCTAssertEqual(f?.encoding, "Not UTF-8")
    }
}
