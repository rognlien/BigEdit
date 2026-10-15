import AppKit
import XCTest
@testable import BigEdit

/// CSV can be chosen for any file; when detection found no delimited data,
/// the prompt supplies the dialect.
final class CSVStructurePromptTests: XCTestCase {

    private final class RecordingDelegate: FormatBarDelegate {
        var selectedModes: [FormatBar.Mode] = []
        var dialects: [CSVDialect] = []

        func formatBar(_ bar: FormatBar, didSelect mode: FormatBar.Mode) {
            selectedModes.append(mode)
        }

        func formatBar(_ bar: FormatBar, didChange dialect: CSVDialect) {
            dialects.append(dialect)
        }
    }

    func testThePromptProposesTheGivenDialect() {
        let proposed = CSVDialect(delimiter: ";", quote: nil, hasHeaderRow: false)

        let prompt = CSVStructurePrompt(proposing: proposed)

        XCTAssertEqual(prompt.dialect, proposed)
    }

    func testANamedDelimiterIsTaken() {
        let prompt = CSVStructurePrompt(proposing: CSVDialect())

        prompt.chooseDelimiter(at: 2)

        XCTAssertEqual(prompt.dialect.delimiter, "\t")
    }

    func testACustomDelimiterIsTaken() {
        let prompt = CSVStructurePrompt(proposing: CSVDialect())

        prompt.chooseDelimiter(at: FormatBar.delimiterChoices.count - 1, custom: "~")

        XCTAssertEqual(prompt.dialect.delimiter, "~")
    }

    func testAnEmptyCustomDelimiterKeepsTheProposedOne() {
        let prompt = CSVStructurePrompt(proposing: CSVDialect(delimiter: "|"))

        prompt.chooseDelimiter(at: FormatBar.delimiterChoices.count - 1)

        XCTAssertEqual(prompt.dialect.delimiter, "|")
    }

    func testAChosenDialectShowsColumnsWithoutDetection() {
        let bar = FormatBar(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        let delegate = RecordingDelegate()
        bar.delegate = delegate
        bar.setDetectedDialect(nil)

        bar.useChosenDialect(CSVDialect(delimiter: "~"))

        XCTAssertEqual(bar.mode, .csv)
        XCTAssertEqual(bar.dialect.delimiter, "~")
        XCTAssertEqual(delegate.selectedModes, [.csv])
    }

    func testAChosenDialectSurvivesLeavingCSV() {
        let bar = FormatBar(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        bar.setDetectedDialect(nil)
        bar.useChosenDialect(CSVDialect(delimiter: "~"))
        bar.setMode(.text)

        bar.setMode(.csv)

        XCTAssertEqual(bar.mode, .csv)
    }
}
