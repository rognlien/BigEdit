import XCTest
@testable import BigEdit

/// Keyboard caret movement must step over whole UTF-8 characters, not single
/// bytes, so Shift+Arrow selections never split a multi-byte character.
final class CaretMovementTests: XCTestCase {

    private let view = ViewportView(frame: .zero)

    private func withFile(_ string: String, _ body: (MappedFile) -> Void) {
        let url = TestHelpers.writeTempFile(string)
        defer { TestHelpers.remove(url) }
        guard let file = MappedFile(path: url.path) else {
            return XCTFail("could not map temp file")
        }
        body(file)
    }

    func testForwardStepsOverMultiByteCharacters() {
        // "a€b": 'a'=1 byte, '€'=3 bytes (E2 82 AC), 'b'=1 byte.
        withFile("a€b") { file in
            XCTAssertEqual(view.nextCharOffset(after: 0, in: file), 1) // past 'a'
            XCTAssertEqual(view.nextCharOffset(after: 1, in: file), 4) // past '€'
            XCTAssertEqual(view.nextCharOffset(after: 4, in: file), 5) // past 'b'
        }
    }

    func testBackwardStepsOverMultiByteCharacters() {
        withFile("a€b") { file in
            XCTAssertEqual(view.prevCharOffset(before: 5, in: file), 4) // back over 'b'
            XCTAssertEqual(view.prevCharOffset(before: 4, in: file), 1) // back over '€'
            XCTAssertEqual(view.prevCharOffset(before: 1, in: file), 0) // back over 'a'
        }
    }

    func testClampsAtBothEnds() {
        withFile("a€b") { file in
            XCTAssertEqual(view.nextCharOffset(after: 5, in: file), 5)   // at EOF
            XCTAssertEqual(view.nextCharOffset(after: 99, in: file), 5)  // beyond EOF
            XCTAssertEqual(view.prevCharOffset(before: 0, in: file), 0)  // at start
        }
    }

    func testFromInsideAMultiByteSequenceLandsOnABoundary() {
        // Defensive: starting mid-'€' should still resolve to character bounds.
        withFile("a€b") { file in
            XCTAssertEqual(view.nextCharOffset(after: 2, in: file), 4) // skip to past '€'
            XCTAssertEqual(view.prevCharOffset(before: 3, in: file), 1) // back to start of '€'
        }
    }
}
