import XCTest
@testable import BigEdit

/// The status bar labels files by detected encoding and line endings (no
/// decoding), so the bounded sample detection must be right.
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

    func testASavedSingleByteDocumentKeepsItsEncoding() {
        let before = format(Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))!
        let after = format(Data("cafe\n".utf8))!

        let kept = after.keepingSingleByteEncoding(of: before)

        XCTAssertEqual(kept.textEncoding, .windows1252)
        XCTAssertEqual(kept.encoding, "Windows-1252")
        XCTAssertEqual(kept.lineEnding, "LF")
    }

    func testOnlyASingleByteEncodingIsKept() {
        let before = format(Data("café\n".utf8))!
        let after = format(Data([0x63, 0xE9, 0x0A]))!

        XCTAssertEqual(after.keepingSingleByteEncoding(of: before).textEncoding, .windows1252)
        XCTAssertEqual(before.keepingSingleByteEncoding(of: before).textEncoding, .utf8)
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

    func testInvalidUTF8IsReadAsWindows1252() {
        // 0xFF mid-stream (not a BOM at the very start before text) is invalid.
        let f = format(Data([0x61, 0x62, 0xFF, 0x63]))
        XCTAssertEqual(f?.encoding, "Windows-1252", "not UTF-8 is read as Windows-1252 now")
    }

    // MARK: - Sampling beyond the head

    private let largeLength = SmallDocument.byteLimit + 1024 * 1024

    /// ASCII lines too long for a small document, so only the sample windows are read.
    private func largeASCII() -> [UInt8] {
        (0..<largeLength).map { $0 % 80 == 79 ? 0x0A : 0x61 }
    }

    private func encoding(of bytes: [UInt8]) -> String? {
        format(Data(bytes))?.encoding
    }

    private func place(_ sequence: [UInt8], at offset: Int, in bytes: inout [UInt8]) {
        bytes.replaceSubrange(offset..<(offset + sequence.count), with: sequence)
    }

    func testALargeASCIIFileIsUTF8() {
        XCTAssertEqual(encoding(of: largeASCII()), "UTF-8")
    }

    func testAHighByteOnlyAtTheEndOfALargeFileIsWindows1252() {
        var bytes = largeASCII()
        place([0xE9], at: largeLength - 2, in: &bytes)

        XCTAssertEqual(encoding(of: bytes), "Windows-1252")
    }

    func testAHighByteOnlyInTheMiddleOfALargeFileIsWindows1252() {
        var bytes = largeASCII()
        let middle = FileFormat.sampleWindows(inFileOf: largeLength)[8]
        place([0xE9], at: middle.lowerBound + middle.count / 2, in: &bytes)

        XCTAssertEqual(encoding(of: bytes), "Windows-1252")
    }

    func testSequencesCutByWindowEdgesStayUTF8() {
        var bytes = largeASCII()
        let windows = FileFormat.sampleWindows(inFileOf: largeLength)
        let emoji = Array("🙂".utf8)
        place(emoji, at: windows[3].lowerBound - 1, in: &bytes)
        place(Array("é".utf8), at: windows[5].upperBound - 1, in: &bytes)
        place(emoji, at: windows[9].upperBound - 1, in: &bytes)
        place(emoji, at: windows[12].lowerBound - 3, in: &bytes)

        XCTAssertEqual(encoding(of: bytes), "UTF-8")
    }

    func testValidMultiByteTextThroughoutALargeFileIsUTF8() {
        let line = Array("blåbærgrød 🙂 Юн Фосэ\n".utf8)
        let bytes = Array((0..<(largeLength / line.count + 1)).map { _ in line }.joined())

        XCTAssertEqual(encoding(of: bytes), "UTF-8")
    }

    func testAHighByteAnywhereInASmallFileIsWindows1252() {
        var bytes = Array(largeASCII().prefix(SmallDocument.byteLimit))
        let offset = SmallDocument.byteLimit / 2 + 13
        place([0xE9], at: offset, in: &bytes)

        XCTAssertEqual(FileFormat.sampleWindows(inFileOf: bytes.count), [0..<bytes.count])
        XCTAssertEqual(encoding(of: bytes), "Windows-1252")
    }

    func testValidMultiByteTextPastTheHeadOfASmallFileIsUTF8() {
        var bytes = Array(largeASCII().prefix(1024 * 1024))
        place(Array("café 🙂".utf8), at: 512 * 1024, in: &bytes)

        XCTAssertEqual(encoding(of: bytes), "UTF-8")
    }

    func testATruncatedSequenceAtTheEndOfAFileIsNotUTF8() {
        var bytes = largeASCII()
        place([0xC3], at: largeLength - 1, in: &bytes)

        XCTAssertEqual(encoding(of: bytes), "Windows-1252")
    }

    func testTheSampleOfAHugeFileIsBounded() {
        let length = 50 * 1024 * 1024 * 1024
        let windows = FileFormat.sampleWindows(inFileOf: length)

        XCTAssertLessThanOrEqual(windows.map(\.count).reduce(0, +), 1024 * 1024)
        XCTAssertEqual(windows.first?.lowerBound, 0)
        XCTAssertEqual(windows.last?.upperBound, length)
    }

    func testAByteOrderMarkStillDecidesALargeFile() {
        var bytes = largeASCII()
        place([0xEF, 0xBB, 0xBF], at: 0, in: &bytes)
        place([0xE9], at: largeLength - 2, in: &bytes)

        XCTAssertEqual(encoding(of: bytes), "UTF-8")
    }
}
