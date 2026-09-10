import XCTest
@testable import BigEdit

/// Extending an index after an append must leave it indistinguishable from an
/// index built fresh over the whole file — including when the append finishes
/// a line the old file left open, lengthens it past the long-line threshold,
/// or carries the line count across a checkpoint.
final class LineIndexExtensionTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    /// Writes `initial`, indexes it, appends each piece in turn extending the
    /// index after each, and compares against a fresh index at every step.
    private func assertExtensionMatchesFreshBuild(initial: [UInt8], appends: [[UInt8]],
                                                  context: String) {
        let url = TestHelpers.writeTempFile(Data(initial))
        temporaryFiles.append(url)
        var file = MappedFile(path: url.path)!
        let extended = LineIndex()
        extended.buildSynchronously(from: file)

        var content = initial
        for (step, piece) in appends.enumerated() {
            content.append(contentsOf: piece)
            let handle = try! FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(Data(piece))
            try! handle.close()

            let previousSize = file.size
            file = MappedFile(path: url.path)!
            XCTAssertEqual(file.size, content.count)
            extended.extendSynchronously(with: file, previousSize: previousSize)

            let fresh = LineIndex()
            fresh.buildSynchronously(from: file)
            compare(extended, fresh, file: file, context: "\(context) step \(step)")
        }
    }

    private func compare(_ extended: LineIndex, _ fresh: LineIndex, file: MappedFile,
                         context: String) {
        XCTAssertTrue(extended.isComplete, context)
        XCTAssertEqual(extended.count, fresh.count, "line count \(context)")
        for wrap in [LineIndex.minimumWrapBytes, 200, LineIndex.defaultWrapBytes] {
            extended.setWrapBytes(wrap)
            fresh.setWrapBytes(wrap)
            XCTAssertEqual(extended.visualRowCount, fresh.visualRowCount,
                           "rows at wrap \(wrap) \(context)")
            let rows = fresh.visualRowCount
            if rows > 0 {
                let tail = max(0, rows - 30)..<rows
                XCTAssertEqual(extended.visualLines(forRows: tail, file: file).map(\.byteRange),
                               fresh.visualLines(forRows: tail, file: file).map(\.byteRange),
                               "tail rows at wrap \(wrap) \(context)")
                let head = 0..<min(rows, 30)
                XCTAssertEqual(extended.visualLines(forRows: head, file: file).map(\.byteRange),
                               fresh.visualLines(forRows: head, file: file).map(\.byteRange),
                               "head rows at wrap \(wrap) \(context)")
            }
            for line in stride(from: 0, to: fresh.count, by: max(1, fresh.count / 7)) {
                XCTAssertEqual(extended.visualRow(forDocumentLine: line, file: file),
                               fresh.visualRow(forDocumentLine: line, file: file),
                               "row for line \(line) wrap \(wrap) \(context)")
            }
            if file.size > 0 {
                XCTAssertEqual(extended.visualRow(forByteOffset: file.size - 1, file: file),
                               fresh.visualRow(forByteOffset: file.size - 1, file: file),
                               "row for last byte wrap \(wrap) \(context)")
            }
        }
    }

    private func line(_ text: String) -> [UInt8] { Array((text + "\n").utf8) }

    // MARK: - Shapes of append

    func testAppendingWholeLinesToATerminatedFile() {
        assertExtensionMatchesFreshBuild(
            initial: line("one") + line("two"),
            appends: [line("three"), line("four") + line("five")],
            context: "terminated")
    }

    func testAppendFinishesAnOpenLine() {
        // The old file ends mid-line; the append completes it and adds more.
        assertExtensionMatchesFreshBuild(
            initial: line("one") + Array("two".utf8),
            appends: [Array(" and a half\n".utf8), line("three")],
            context: "open line")
    }

    func testAppendWithNoNewlineLeavesTheLineOpen() {
        assertExtensionMatchesFreshBuild(
            initial: line("one") + Array("par".utf8),
            appends: [Array("tial".utf8), Array(" still".utf8), line(" done")],
            context: "no newline")
    }

    func testAppendLengthensAnOpenLinePastTheLongLineThreshold() {
        let short = Array(repeatElement(UInt8(ascii: "x"), count: LineIndex.longLineThreshold - 10))
        let rest = Array(repeatElement(UInt8(ascii: "y"), count: 3000)) + [0x0A]
        assertExtensionMatchesFreshBuild(
            initial: line("one") + short,
            appends: [rest, line("after")],
            context: "becomes long")
    }

    func testAppendToAnOpenLongLine() {
        let long = Array(repeatElement(UInt8(ascii: "x"), count: 2000))
        assertExtensionMatchesFreshBuild(
            initial: line("one") + long,
            appends: [Array(repeatElement(UInt8(ascii: "z"), count: 500)) + [0x0A], line("end")],
            context: "open long line")
    }

    func testAppendCrossesACheckpoint() {
        let stride = LineIndex.checkpointStride
        var initial: [UInt8] = []
        for number in 0..<(stride - 3) { initial += line("\(number)") }
        var appended: [UInt8] = []
        for number in 0..<(stride + 5) { appended += line("more \(number)") }
        assertExtensionMatchesFreshBuild(initial: initial, appends: [appended, line("last")],
                                         context: "across checkpoint")
    }

    func testAppendToAnEmptyFile() {
        assertExtensionMatchesFreshBuild(initial: [], appends: [line("first"), Array("open".utf8)],
                                         context: "from empty")
    }

    func testManySmallAppends() {
        var generator = SeededGenerator(seed: 31)
        var appends: [[UInt8]] = []
        for _ in 0..<40 {
            let length = Int.random(in: 1...20, using: &generator)
            var piece: [UInt8] = []
            for _ in 0..<length {
                piece.append(Int.random(in: 0..<5, using: &generator) == 0 ? 0x0A : UInt8(ascii: "a"))
            }
            appends.append(piece)
        }
        assertExtensionMatchesFreshBuild(initial: line("start"), appends: appends,
                                         context: "many small")
    }

    // MARK: - Growth detection

    func testAppendIsDetectedAndVerified() {
        let url = TestHelpers.writeTempFile("hello\n")
        temporaryFiles.append(url)
        let before = MappedFile(path: url.path)!
        XCTAssertEqual(FileGrowth.detect(path: url.path, previous: before), .unchanged)

        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("world\n".utf8))
        try! handle.close()
        XCTAssertEqual(FileGrowth.detect(path: url.path, previous: before), .appended(newSize: 12))
        let after = MappedFile(path: url.path)!
        XCTAssertTrue(FileGrowth.isAppend(previous: before, grown: after))
    }

    func testARewriteThatGrewIsNotTakenForAnAppend() {
        let url = TestHelpers.writeTempFile("hello\n")
        temporaryFiles.append(url)
        let before = MappedFile(path: url.path)!
        // Same inode, larger, but the old bytes changed.
        let handle = try! FileHandle(forWritingTo: url)
        handle.write(Data("HELLO and more\n".utf8))
        try! handle.close()
        if case .appended = FileGrowth.detect(path: url.path, previous: before) {
            let grown = MappedFile(path: url.path)!
            XCTAssertFalse(FileGrowth.isAppend(previous: before, grown: grown))
        }
    }

    func testAnAtomicReplacementIsAReplacement() {
        let url = TestHelpers.writeTempFile("hello\n")
        temporaryFiles.append(url)
        let before = MappedFile(path: url.path)!
        let replacement = TestHelpers.writeTempFile("hello\nworld\n")
        _ = try! FileManager.default.replaceItemAt(url, withItemAt: replacement)
        XCTAssertEqual(FileGrowth.detect(path: url.path, previous: before), .replaced)
    }

    func testTruncationIsAReplacement() {
        let url = TestHelpers.writeTempFile("hello world\n")
        temporaryFiles.append(url)
        let before = MappedFile(path: url.path)!
        try! Data("hi\n".utf8).write(to: url)     // same inode, smaller
        XCTAssertEqual(FileGrowth.detect(path: url.path, previous: before), .replaced)
    }
}
