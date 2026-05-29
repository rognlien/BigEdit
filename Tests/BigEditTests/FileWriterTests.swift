import XCTest
@testable import BigEdit

final class FileWriterTests: XCTestCase {

    func testRoundTripMatchesSedSemantics() {
        let content = "foo bar foo\nbaz foo\nno match here\nfoofoo\n"
        let inputURL = TestHelpers.writeTempFile(content)
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("BigEditTestOut-\(UUID().uuidString)")
        defer {
            TestHelpers.remove(inputURL)
            TestHelpers.remove(outputURL)
        }
        let file = MappedFile(path: inputURL.path)!
        let rule = ReplacementRule(pattern: "foo", replacement: "XX")!

        let result = FileWriter.saveSynchronously(file: file, rule: rule, to: outputURL)
        switch result {
        case .success:
            let written = try? String(contentsOf: outputURL, encoding: .utf8)
            XCTAssertEqual(written, "XX bar XX\nbaz XX\nno match here\nXXXX\n")
        case .failure(let error):
            XCTFail("Save failed: \(error.localizedDescription)")
        }
    }

    func testEmptyReplacementDeletesAllOccurrences() {
        let content = "abc-abc-abc"
        let inputURL = TestHelpers.writeTempFile(content)
        let outputURL = inputURL.deletingLastPathComponent()
            .appendingPathComponent("BigEditTestOut-\(UUID().uuidString)")
        defer {
            TestHelpers.remove(inputURL)
            TestHelpers.remove(outputURL)
        }
        let file = MappedFile(path: inputURL.path)!
        let rule = ReplacementRule(pattern: "abc", replacement: "")!

        let result = FileWriter.saveSynchronously(file: file, rule: rule, to: outputURL)
        switch result {
        case .success:
            let written = try? String(contentsOf: outputURL, encoding: .utf8)
            XCTAssertEqual(written, "--")
        case .failure(let error):
            XCTFail("Save failed: \(error.localizedDescription)")
        }
    }
}
