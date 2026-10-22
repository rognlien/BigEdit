import AppKit
import XCTest
@testable import BigEdit

/// The assistant is honest about where it cannot run, and the sheet that
/// fronts it hands a pattern on only when there is one.
final class PatternAssistantTests: XCTestCase {

    func testAvailabilityComesWithAReason() {
        if PatternAssistant.isAvailable {
            XCTAssertNil(PatternAssistant.unavailableReason)
        } else {
            XCTAssertFalse(PatternAssistant.unavailableReason?.isEmpty ?? true)
        }
    }

    func testAskingWhereUnavailableThrowsTheReason() async {
        guard !PatternAssistant.isAvailable else {
            return
        }
        do {
            _ = try await PatternAssistant.suggestPattern(for: "numbers", sample: nil)
            XCTFail("an unavailable model cannot answer")
        } catch {
            XCTAssertEqual(error.localizedDescription, PatternAssistant.unavailableReason)
        }
    }

    func testTheSheetOffersASuggestedPattern() {
        let sheet = PatternAssistantSheet(mode: .describe(sample: nil))
        XCTAssertFalse(sheet.canUsePattern)
        sheet.show(pattern: "\\d+", explanation: "One or more digits.")
        XCTAssertEqual(sheet.shownPattern, "\\d+")
        XCTAssertTrue(sheet.canUsePattern)
        sheet.show(failure: "No model.")
        XCTAssertFalse(sheet.canUsePattern)
    }

    func testSampleTextIsAFewWholeLines() {
        let url = TestHelpers.writeTempFile((0..<100).map { "line \($0) with text" }.joined(separator: "\n") + "\n")
        defer { TestHelpers.remove(url) }
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let view = TestHelpers.isolatedDocumentView()
        view.load(file: file, index: index)

        let sample = view.sampleText(maxBytes: 200, maxLines: 5)!
        let lines = sample.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.first, "line 0 with text")
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix("with text") }, "no line is cut short")
    }
}
