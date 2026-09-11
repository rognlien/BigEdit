import XCTest
@testable import BigEdit

/// A Windows-1252 file must read, copy, search and count correctly — with
/// every byte↔character mapping exact — while staying read-only.
final class TextEncodingTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    /// "blåbærgrød €" in Windows-1252, where each non-ASCII letter is one byte.
    /// Built step by step: a long chain of `+` between literals is something
    /// the type checker gives up on.
    private let sample: [UInt8] = {
        var bytes: [UInt8] = Array("bl".utf8)
        bytes.append(0xE5)                          // å
        bytes.append(contentsOf: Array("b".utf8))
        bytes.append(0xE6)                          // æ
        bytes.append(contentsOf: Array("rgr".utf8))
        bytes.append(0xF8)                          // ø
        bytes.append(contentsOf: Array("d ".utf8))
        bytes.append(0x80)                          // €
        bytes.append(0x0A)
        return bytes
    }()
    private let sampleText = "blåbærgrød €\n"

    private func mapped(_ bytes: [UInt8]) -> MappedFile {
        let url = TestHelpers.writeTempFile(Data(bytes))
        temporaryFiles.append(url)
        return MappedFile(path: url.path)!
    }

    // MARK: - The encoding itself

    func testDecodesWindows1252() {
        XCTAssertEqual(TextEncoding.windows1252.decode(sample), sampleText)
    }

    func testEncodesBackToTheSameBytes() {
        XCTAssertEqual(TextEncoding.windows1252.encode(sampleText), sample)
    }

    func testACharacterOutsideTheEncodingCannotBeEncoded() {
        XCTAssertNil(TextEncoding.windows1252.encode("🙂"))
        XCTAssertEqual(TextEncoding.utf8.encode("🙂"), Array("🙂".utf8))
    }

    func testEveryByteDecodesEvenTheUndefinedOnes() {
        // 0x81 has no meaning in Windows-1252; it must not make decoding fail.
        let text = TextEncoding.windows1252.decode([0x41, 0x81, 0x42])
        XCTAssertEqual(text.count, 3)
        XCTAssertTrue(text.hasPrefix("A") && text.hasSuffix("B"))
    }

    func testByteLengthIsOneInASingleByteEncoding() {
        let scalar: Unicode.Scalar = "ø"
        XCTAssertEqual(TextEncoding.windows1252.byteLength(of: scalar), 1)
        XCTAssertEqual(TextEncoding.utf8.byteLength(of: scalar), 2)
    }

    // MARK: - Detection

    func testAWindows1252FileIsDetectedAndReadOnly() {
        let format = FileFormat(scanning: mapped(sample))
        XCTAssertEqual(format.textEncoding, .windows1252)
        XCTAssertEqual(format.encoding, "Windows-1252")
        XCTAssertFalse(format.isUTF8, "edits are UTF-8, so a 1252 file cannot be edited")
    }

    func testUTF8AndBinaryDetectionAreUnchanged() {
        XCTAssertEqual(FileFormat(scanning: mapped(Array(sampleText.utf8))).textEncoding, .utf8)
        XCTAssertNil(FileFormat(scanning: mapped([0x41, 0x00, 0x42])).textEncoding)
    }

    // MARK: - Search

    func testLiteralSearchEncodesTheNeedle() {
        let file = mapped(sample + sample)
        let scan = SearchScan(query: "ø", encoding: .windows1252)!
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.matchOffsets(beginningIn: 0..<Int.max), [8, 8 + sample.count])
        XCTAssertEqual(scan.queryByteLength, 1, "one byte, as it is in the file")
    }

    func testANeedleTheEncodingCannotHoldIsNotSearchable() {
        XCTAssertNil(SearchScan(query: "🙂", encoding: .windows1252))
    }

    func testRegularExpressionRangesAreByteExact() {
        let file = mapped(sample)
        let scan = SearchScan(regularExpression: "[åæø]+", encoding: .windows1252)!
        scan.runSynchronously(in: file)
        let ranges = scan.matches(beginningIn: 0..<Int.max)
        XCTAssertEqual(ranges, [2..<3, 4..<5, 8..<9], "each letter is one byte")
    }

    // MARK: - Counting, copying, clicking

    func testCharacterCountIsByteCountInASingleByteEncoding() {
        let file = mapped(sample)
        let scan = StatisticsScan(encoding: .windows1252)
        scan.runSynchronously(in: file)
        XCTAssertEqual(scan.characterCount, sample.count)
        XCTAssertEqual(scan.wordCount, 2)
    }

    func testCopyDecodesInTheDocumentsEncoding() {
        XCTAssertEqual(ViewportView.pasteboardText(from: sample, encoding: .windows1252), sampleText)
    }

    func testClickMappingUsesOneByteperCharacter() {
        // In "aøb", the character after ø is at UTF-16 index 2: byte 2 in
        // Latin-1, byte 3 in UTF-8.
        XCTAssertEqual(ViewportView.byteOffset(forUTF16Index: 2, in: "aøb", encoding: .latin1), 2)
        XCTAssertEqual(ViewportView.byteOffset(forUTF16Index: 2, in: "aøb", encoding: .utf8), 3)
    }
}
