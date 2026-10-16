import XCTest
@testable import BigEdit

final class EditModelTests: XCTestCase {

    func testReplacementRuleRejectsInvalidInput() {
        XCTAssertNil(ReplacementRule(pattern: "", replacement: "x"))         // empty pattern
        XCTAssertNil(ReplacementRule(pattern: "a\nb", replacement: "x"))     // newline in pattern
        XCTAssertNil(ReplacementRule(pattern: "x", replacement: "a\nb"))     // newline in replacement
        XCTAssertNotNil(ReplacementRule(pattern: "foo", replacement: "bar")) // valid
        XCTAssertNotNil(ReplacementRule(pattern: "foo", replacement: ""))    // delete is valid
    }

    func testTransformedBytesAppliesReplacement() {
        let content = "foo bar foo baz foo"
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let rule = ReplacementRule(pattern: "foo", replacement: "BAZ")!
        let model = EditModel()
        model.setRuleSynchronously(rule, file: file)

        let transformed = model.transformedBytes(forOriginalRange: 0..<file.size, in: file.buffer)
        XCTAssertEqual(String(decoding: transformed, as: UTF8.self), "BAZ bar BAZ baz BAZ")
    }

    func testARuleMatchesAndReplacesInTheDocumentsEncoding() {
        // "café crème" in Windows-1252: é is the single byte 0xE9, è is 0xE8.
        let content: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x20, 0x63, 0x72, 0xE8, 0x6D, 0x65]
        let url = TestHelpers.writeTempFile(Data(content))
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let rule = ReplacementRule(pattern: "é", replacement: "€", encoding: .windows1252)!
        let model = EditModel()
        model.setRuleSynchronously(rule, file: file)

        let transformed = model.transformedBytes(forOriginalRange: 0..<file.size, in: file.buffer)
        XCTAssertEqual(transformed, [0x63, 0x61, 0x66, 0x80, 0x20, 0x63, 0x72, 0xE8, 0x6D, 0x65])
    }

    func testARuleTheEncodingCannotHoldIsRejected() {
        XCTAssertNil(ReplacementRule(pattern: "e", replacement: "🙂", encoding: .windows1252))
        XCTAssertNil(ReplacementRule(pattern: "€", replacement: "e", encoding: .latin1))
    }

    func testTransformedBytesWithNoRuleReturnsOriginal() {
        let content = "hello"
        let url = TestHelpers.writeTempFile(content)
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let model = EditModel()
        let result = model.transformedBytes(forOriginalRange: 0..<file.size, in: file.buffer)
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "hello")
    }
}
