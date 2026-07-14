import XCTest
@testable import BigEdit

/// Keyboard caret movement must step over whole UTF-8 characters, not single
/// bytes, so Shift+Arrow selections never split a multi-byte character.
final class CaretMovementTests: XCTestCase {

    private func withDocument(_ string: String, _ body: (EditedDocument) -> Void) {
        let url = TestHelpers.writeTempFile(string)
        defer { TestHelpers.remove(url) }
        guard let file = MappedFile(path: url.path) else {
            return XCTFail("could not map temp file")
        }
        body(EditedDocument(file: file, editModel: EditModel()))
    }

    func testForwardStepsOverMultiByteCharacters() {
        // "a€b": 'a'=1 byte, '€'=3 bytes (E2 82 AC), 'b'=1 byte.
        withDocument("a€b") { document in
            XCTAssertEqual(document.nextCharacterOffset(after: 0), 1) // past 'a'
            XCTAssertEqual(document.nextCharacterOffset(after: 1), 4) // past '€'
            XCTAssertEqual(document.nextCharacterOffset(after: 4), 5) // past 'b'
        }
    }

    func testBackwardStepsOverMultiByteCharacters() {
        withDocument("a€b") { document in
            XCTAssertEqual(document.previousCharacterOffset(before: 5), 4) // back over 'b'
            XCTAssertEqual(document.previousCharacterOffset(before: 4), 1) // back over '€'
            XCTAssertEqual(document.previousCharacterOffset(before: 1), 0) // back over 'a'
        }
    }

    func testClampsAtBothEnds() {
        withDocument("a€b") { document in
            XCTAssertEqual(document.nextCharacterOffset(after: 5), 5)   // at EOF
            XCTAssertEqual(document.nextCharacterOffset(after: 99), 5)  // beyond EOF
            XCTAssertEqual(document.previousCharacterOffset(before: 0), 0)  // at start
        }
    }

    func testFromInsideAMultiByteSequenceLandsOnABoundary() {
        // Defensive: starting mid-'€' should still resolve to character bounds.
        withDocument("a€b") { document in
            XCTAssertEqual(document.nextCharacterOffset(after: 2), 4) // skip to past '€'
            XCTAssertEqual(document.previousCharacterOffset(before: 3), 1) // back to start of '€'
        }
    }
}
