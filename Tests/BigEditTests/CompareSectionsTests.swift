import XCTest
@testable import BigEdit

/// The compare window's sections are built from both engines, and the
/// Changes section exports as a unified diff.
final class CompareSectionsTests: XCTestCase {

    private func request() -> CompareRequest {
        CompareRequest(first: OtherLineList(name: "a.txt", byteCount: 0) { nil },
                       second: OtherLineList(name: "b.txt", byteCount: 0) { nil },
                       options: LineMatchOptions())
    }

    func testFourSectionsInOrder() throws {
        let sections = try XCTUnwrap(AppDelegate.compareSections(
            first: ["x", "y"], second: ["y", "z"], request: request(), isCancelled: { false }))
        XCTAssertEqual(sections.map(\.title), ["Only in a.txt", "Only in b.txt", "In both", "Changes"])
        XCTAssertEqual(sections[0].rows.map(\.text), ["x"])
        XCTAssertEqual(sections[1].rows.map(\.text), ["z"])
        XCTAssertEqual(sections[2].rows.map(\.text), ["y"])
    }

    func testChangesExportAsAUnifiedDiff() throws {
        let first = ["x", "y"]
        let second = ["y", "z"]
        let sections = try XCTUnwrap(AppDelegate.compareSections(
            first: first, second: second, request: request(), isCancelled: { false }))
        let changes = sections[3]
        let expected = LineDiff.unified(try XCTUnwrap(LineDiff.diff(first, second)),
                                        first: first, second: second,
                                        firstName: "a.txt", secondName: "b.txt")
        XCTAssertEqual(changes.exportText, expected)
        XCTAssertEqual(changes.suggestedFileName, "a to b.diff")
        XCTAssertEqual(changes.rows.map(\.kind), [.header, .header, .header, .removed, .context, .added])
    }

    func testCancellationGivesNoSections() throws {
        XCTAssertNil(try AppDelegate.compareSections(
            first: ["a"], second: ["b"], request: request(), isCancelled: { true }))
    }
}
