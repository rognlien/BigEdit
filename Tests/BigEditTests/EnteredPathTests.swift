import XCTest
@testable import BigEdit

/// File ▸ Open Path turns what was typed or pasted into a file URL.
final class EnteredPathTests: XCTestCase {

    private let base = URL(fileURLWithPath: "/Users/someone/Projects")

    private func path(_ text: String) -> String? {
        EnteredPath.url(from: text, relativeTo: base)?.path
    }

    func testAnAbsolutePathIsTakenAsItIs() {
        XCTAssertEqual(path("/var/log/system.log"), "/var/log/system.log")
    }

    func testARelativePathStartsFromTheBase() {
        XCTAssertEqual(path("notes/todo.txt"), "/Users/someone/Projects/notes/todo.txt")
        XCTAssertEqual(path("../other.txt"), "/Users/someone/other.txt")
    }

    func testATildeIsTheHomeFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(path("~/file.txt"), home + "/file.txt")
    }

    func testSurroundingWhitespaceAndQuotesAreDropped() {
        XCTAssertEqual(path("  \"/tmp/a b.txt\"\n"), "/tmp/a b.txt")
        XCTAssertEqual(path("'/tmp/a b.txt'"), "/tmp/a b.txt")
    }

    func testSpacesEscapedAsInTerminalAreUnescaped() {
        XCTAssertEqual(path("/tmp/a\\ b.txt"), "/tmp/a b.txt")
    }

    func testAFileURLIsAccepted() {
        XCTAssertEqual(path("file:///tmp/a%20b.txt"), "/tmp/a b.txt")
    }

    func testNothingEnteredIsNoPath() {
        XCTAssertNil(path("   "))
    }
}
