import AppKit
import XCTest
@testable import BigEdit

/// The peak memory of pasting a huge text, measured by hand and skipped
/// otherwise. `BIGEDIT_PASTE_MEGABYTES` sets the size, 1024 by default.
///
/// The system pasteboard refuses a few hundred megabytes, so the paste
/// itself is measured up to that, with the text put on a private pasteboard
/// in one process and pasted in another, so the peak is the paste's alone:
///
///     BIGEDIT_PASTE_MEASUREMENT=fill swift test --filter PasteMemoryMeasurement
///     BIGEDIT_PASTE_MEASUREMENT=pasteboard swift test --filter PasteMemoryMeasurement
///
/// Beyond it, `BIGEDIT_PASTE_MEASUREMENT=text` hands the text to the paste's
/// insertion directly, as the pasteboard would return it.
final class PasteMemoryMeasurement: XCTestCase {

    private static let pasteboardName = NSPasteboard.Name("io.maendeleo.BigEdit.PasteMeasurement")
    private static let lineLength = 100
    private static let prefix = "start\n"

    private var temporaryURLs: [URL] = []

    override func tearDown() {
        temporaryURLs.forEach(TestHelpers.remove)
        temporaryURLs = []
        super.tearDown()
    }

    private var mode: String? {
        ProcessInfo.processInfo.environment["BIGEDIT_PASTE_MEASUREMENT"]
    }

    private var lineCount: Int {
        let megabytes = Int(ProcessInfo.processInfo.environment["BIGEDIT_PASTE_MEGABYTES"] ?? "") ?? 1024
        return megabytes * 1024 * 1024 / PasteMemoryMeasurement.lineLength
    }

    private func makeText() -> String {
        let line = String(repeating: "x", count: PasteMemoryMeasurement.lineLength - 1) + "\n"
        return String(repeating: line, count: lineCount)
    }

    func testFillThePasteboard() throws {
        try XCTSkipUnless(mode == "fill")
        let pasteboard = NSPasteboard(name: PasteMemoryMeasurement.pasteboardName)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(makeText(), forType: .string))
    }

    func testPasteFromThePasteboard() throws {
        try XCTSkipUnless(mode == "pasteboard")
        let pasteboard = NSPasteboard(name: PasteMemoryMeasurement.pasteboardName)
        measure("Pasted") { viewport in
            viewport.paste(from: pasteboard)
        }
        pasteboard.releaseGlobally()
    }

    func testInsertText() throws {
        try XCTSkipUnless(mode == "text")
        var text: String? = makeText()
        measure("Inserted") { viewport in
            viewport.insertTextAtSelection(text!)
            text = nil
        }
    }

    private func measure(_ verb: String, _ paste: (ViewportView) -> Void) {
        let (viewport, document) = makeViewport()
        let before = PasteMemoryMeasurement.residentBytes()
        let start = Date()
        autoreleasepool {
            paste(viewport)
        }
        let seconds = Date().timeIntervalSince(start)
        let peak = PasteMemoryMeasurement.peakResidentBytes()
        let after = PasteMemoryMeasurement.residentBytes()
        let pasted = lineCount * PasteMemoryMeasurement.lineLength
        print(String(format: "%@ %d MB in %.1f s: resident %d MB before, %d MB after, peak %d MB (%d MB above before)",
                     verb, pasted >> 20, seconds, before >> 20, after >> 20, peak >> 20, (peak - before) >> 20))
        XCTAssertEqual(document.length, PasteMemoryMeasurement.prefix.utf8.count + pasted)
    }

    private func makeViewport() -> (ViewportView, EditedDocument) {
        let url = TestHelpers.writeTempFile(PasteMemoryMeasurement.prefix)
        let journalRoot = TestHelpers.isolatedJournalRoot()
        temporaryURLs += [url, journalRoot]
        let file = MappedFile(path: url.path)!
        let index = LineIndex()
        index.buildSynchronously(from: file)
        let document = EditedDocument(file: file, editModel: EditModel(), lineIndex: index)
        document.isEditable = true
        document.journal = EditJournal.open(for: url.path, in: journalRoot)
        document.journal?.setBaseline(file)
        let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        viewport.load(document: document)
        viewport.selection = TextSelection(anchorOffset: document.length, activeOffset: document.length)
        return (viewport, document)
    }

    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    private static func peakResidentBytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }
}
