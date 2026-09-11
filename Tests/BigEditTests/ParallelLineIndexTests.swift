import XCTest
@testable import BigEdit

/// The parallel scan must be indistinguishable from the serial one. These
/// tests build both over the same bytes and compare everything the rest of
/// the app can observe, using chunk sizes small enough that boundaries land
/// inside lines, between lines, on newlines, and inside long lines.
final class ParallelLineIndexTests: XCTestCase {

    private var temporaryFiles: [URL] = []

    override func tearDown() {
        temporaryFiles.forEach(TestHelpers.remove)
        temporaryFiles = []
        super.tearDown()
    }

    private func mapped(_ bytes: [UInt8]) -> MappedFile {
        let url = TestHelpers.writeTempFile(Data(bytes))
        temporaryFiles.append(url)
        guard let file = MappedFile(path: url.path) else {
            fatalError("could not map temp file")
        }
        return file
    }

    /// Random text: mostly short lines, some at or past the long-line
    /// threshold, occasionally far past it, and sometimes no trailing newline.
    private func randomContent(lines: Int, using generator: inout SeededGenerator) -> [UInt8] {
        var bytes: [UInt8] = []
        for _ in 0..<lines {
            let roll = Int.random(in: 0..<100, using: &generator)
            let length: Int
            if roll < 85 {
                length = Int.random(in: 0...12, using: &generator)
            } else if roll < 97 {
                length = Int.random(in: (LineIndex.longLineThreshold - 2)...(LineIndex.longLineThreshold + 2),
                                    using: &generator)
            } else {
                length = Int.random(in: 3000...9000, using: &generator)
            }
            bytes.append(contentsOf: repeatElement(UInt8(ascii: "x"), count: length))
            bytes.append(0x0A)
        }
        if Bool.random(using: &generator) {
            bytes.append(contentsOf: Array("tail without newline".utf8))
        }
        return bytes
    }

    private func assertEquivalent(_ bytes: [UInt8], chunkSize: Int,
                                  probesUsing generator: inout SeededGenerator,
                                  context: String) {
        let file = mapped(bytes)
        let serial = LineIndex()
        serial.buildSynchronously(from: file)
        let parallel = LineIndex()
        parallel.buildSynchronously(from: file, forcingParallelChunkSize: chunkSize)

        XCTAssertTrue(parallel.isComplete, context)
        XCTAssertEqual(parallel.count, serial.count, "line count \(context)")

        for wrap in [LineIndex.minimumWrapBytes, 300, LineIndex.defaultWrapBytes] {
            serial.setWrapBytes(wrap)
            parallel.setWrapBytes(wrap)
            XCTAssertEqual(parallel.visualRowCount, serial.visualRowCount,
                           "rows at wrap \(wrap) \(context)")

            let rows = serial.visualRowCount
            if rows > 0 {
                // A window of rows from the start, the end, and a random middle.
                let starts = [0, max(0, rows - 40), Int.random(in: 0..<rows, using: &generator)]
                for start in starts {
                    let range = start..<min(rows, start + 40)
                    let expected = serial.visualLines(forRows: range, file: file)
                    let actual = parallel.visualLines(forRows: range, file: file)
                    XCTAssertEqual(actual.map(\.byteRange), expected.map(\.byteRange),
                                   "byte ranges rows \(range) wrap \(wrap) \(context)")
                    XCTAssertEqual(actual.map(\.documentLine), expected.map(\.documentLine),
                                   "line numbers rows \(range) wrap \(wrap) \(context)")
                }
            }

            for _ in 0..<20 where serial.count > 0 {
                let line = Int.random(in: 0..<serial.count, using: &generator)
                XCTAssertEqual(parallel.visualRow(forDocumentLine: line, file: file),
                               serial.visualRow(forDocumentLine: line, file: file),
                               "row for line \(line) wrap \(wrap) \(context)")
            }
            for _ in 0..<20 where !bytes.isEmpty {
                let offset = Int.random(in: 0..<bytes.count, using: &generator)
                XCTAssertEqual(parallel.visualRow(forByteOffset: offset, file: file),
                               serial.visualRow(forByteOffset: offset, file: file),
                               "row for byte \(offset) wrap \(wrap) \(context)")
            }
        }
    }

    // MARK: - Equivalence

    func testParallelMatchesSerialAcrossChunkSizes() {
        for seed: UInt64 in [1, 23, 456] {
            var generator = SeededGenerator(seed: seed)
            let bytes = randomContent(lines: 600, using: &generator)
            for chunkSize in [7, 64, 1000, 4096, 1 << 20] {
                assertEquivalent(bytes, chunkSize: chunkSize, probesUsing: &generator,
                                 context: "seed \(seed) chunk \(chunkSize)")
            }
        }
    }

    /// More lines than a checkpoint stride, so checkpoints have to land on
    /// exactly the right newline — including ones inside a chunk other than
    /// the first, where alignment depends on the running count.
    func testCheckpointsAlignAcrossChunks() {
        var generator = SeededGenerator(seed: 99)
        var bytes: [UInt8] = []
        for line in 0..<(LineIndex.checkpointStride * 3 + 17) {
            bytes.append(contentsOf: Array("\(line)".utf8))
            bytes.append(0x0A)
        }
        for chunkSize in [13, 257, 5000, 1 << 16] {
            assertEquivalent(bytes, chunkSize: chunkSize, probesUsing: &generator,
                             context: "chunk \(chunkSize)")
        }
    }

    // MARK: - Boundaries

    func testLongLineSpanningManyChunks() {
        var generator = SeededGenerator(seed: 7)
        var bytes = Array("short\n".utf8)
        bytes.append(contentsOf: repeatElement(UInt8(ascii: "y"), count: 5000))
        bytes.append(0x0A)
        bytes.append(contentsOf: Array("after\n".utf8))
        // Chunks of 100 bytes: the long line crosses ~50 boundaries.
        assertEquivalent(bytes, chunkSize: 100, probesUsing: &generator, context: "spanning")
    }

    func testChunkBoundaryExactlyOnANewline() {
        var generator = SeededGenerator(seed: 8)
        // "abc\n" is four bytes; a chunk size of 4 puts every boundary right
        // after a newline, and 3 puts it right before one.
        let bytes = Array(String(repeating: "abc\n", count: 50).utf8)
        for chunkSize in [3, 4, 5] {
            assertEquivalent(bytes, chunkSize: chunkSize, probesUsing: &generator,
                             context: "chunk \(chunkSize)")
        }
    }

    func testFileWithNoNewlineAtAll() {
        var generator = SeededGenerator(seed: 9)
        let bytes = Array(repeatElement(UInt8(ascii: "z"), count: 3000))
        assertEquivalent(bytes, chunkSize: 128, probesUsing: &generator, context: "no newline")
    }

    func testEmptyFile() {
        let file = mapped([])
        let parallel = LineIndex()
        parallel.buildSynchronously(from: file, forcingParallelChunkSize: 64)
        XCTAssertEqual(parallel.count, 0)
        XCTAssertTrue(parallel.isComplete)
    }

    func testOnlyNewlines() {
        var generator = SeededGenerator(seed: 10)
        let bytes = [UInt8](repeating: 0x0A, count: 9000)
        assertEquivalent(bytes, chunkSize: 1000, probesUsing: &generator, context: "only newlines")
    }
}
