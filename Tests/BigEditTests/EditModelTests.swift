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
