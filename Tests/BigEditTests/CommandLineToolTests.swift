import XCTest
@testable import BigEditCLI

/// The `bigedit` tool is the one part of BigEdit a user meets without a window,
/// so its argument handling and file creation are worth pinning down.
final class CommandLineToolTests: XCTestCase {

    private var workingDirectory: URL!

    override func setUp() {
        super.setUp()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BigEditCLITest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workingDirectory)
        super.tearDown()
    }

    // MARK: - Arguments

    func testNoArgumentsOpensNothing() throws {
        XCTAssertEqual(try CommandLineTool.parse([]), .open(paths: []))
    }

    func testFilesAreCollectedInOrder() throws {
        XCTAssertEqual(try CommandLineTool.parse(["a.txt", "b.txt"]),
                       .open(paths: ["a.txt", "b.txt"]))
    }

    func testHelpFlags() throws {
        XCTAssertEqual(try CommandLineTool.parse(["-h"]), .showHelp)
        XCTAssertEqual(try CommandLineTool.parse(["--help"]), .showHelp)
    }

    func testVersionFlags() throws {
        XCTAssertEqual(try CommandLineTool.parse(["-v"]), .showVersion)
        XCTAssertEqual(try CommandLineTool.parse(["--version"]), .showVersion)
    }

    func testUnknownOptionIsRejected() {
        XCTAssertThrowsError(try CommandLineTool.parse(["--wat"])) { error in
            XCTAssertEqual(error as? CommandLineTool.Failure, .unreadableOption("--wat"))
        }
    }

    func testTerminatorLetsAFilenameLookLikeAnOption() throws {
        XCTAssertEqual(try CommandLineTool.parse(["--", "--odd-name.txt"]),
                       .open(paths: ["--odd-name.txt"]))
    }

    func testASingleDashIsTreatedAsAName() throws {
        XCTAssertEqual(try CommandLineTool.parse(["-"]), .open(paths: ["-"]))
    }

    // MARK: - Files

    func testExistingFileIsLeftAlone() throws {
        let url = workingDirectory.appendingPathComponent("kept.txt")
        try Data("hello".utf8).write(to: url)
        let prepared = try CommandLineTool.prepareFile(at: url.path)
        XCTAssertEqual(prepared.path, url.path)
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
    }

    func testMissingFileIsCreatedEmpty() throws {
        let url = workingDirectory.appendingPathComponent("fresh.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let prepared = try CommandLineTool.prepareFile(at: url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path))
        XCTAssertEqual(try Data(contentsOf: prepared), Data())
    }

    func testRelativePathBecomesAbsolute() throws {
        let prepared = try CommandLineTool.prepareFile(
            at: workingDirectory.appendingPathComponent("./nested.txt").path)
        XCTAssertTrue(prepared.path.hasPrefix("/"))
        XCTAssertFalse(prepared.path.contains("/./"))
    }

    func testDirectoryIsRejected() {
        XCTAssertThrowsError(try CommandLineTool.prepareFile(at: workingDirectory.path)) { error in
            XCTAssertEqual(error as? CommandLineTool.Failure,
                           .isDirectory(path: workingDirectory.standardizedFileURL.path))
        }
    }

    func testMissingParentDirectoryIsReported() {
        let url = workingDirectory
            .appendingPathComponent("no-such-folder")
            .appendingPathComponent("file.txt")
        XCTAssertThrowsError(try CommandLineTool.prepareFile(at: url.path)) { error in
            guard case .cannotCreate = error as? CommandLineTool.Failure else {
                return XCTFail("expected cannotCreate, got \(error)")
            }
        }
    }

    // MARK: - Locating the application

    func testFindsTheEnclosingApplicationBundle() throws {
        let app = workingDirectory.appendingPathComponent("BigEdit.app")
        let binaryDirectory = app.appendingPathComponent("Contents/SharedSupport/bin")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let tool = binaryDirectory.appendingPathComponent("bigedit")
        FileManager.default.createFile(atPath: tool.path, contents: Data())

        let found = try CommandLineTool.applicationURL(forExecutableAt: tool.path)
        XCTAssertEqual(found?.standardizedFileURL, app.standardizedFileURL)
    }

    func testFollowsASymlinkOnThePathBackIntoTheBundle() throws {
        let app = workingDirectory.appendingPathComponent("BigEdit.app")
        let binaryDirectory = app.appendingPathComponent("Contents/SharedSupport/bin")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let tool = binaryDirectory.appendingPathComponent("bigedit")
        FileManager.default.createFile(atPath: tool.path, contents: Data())

        // This is what installing on the PATH actually creates.
        let link = workingDirectory.appendingPathComponent("bin-bigedit")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        let found = try CommandLineTool.applicationURL(forExecutableAt: link.path)
        XCTAssertEqual(found?.standardizedFileURL, app.standardizedFileURL)
    }

    func testABuildDirectoryBinaryHasNoBundle() throws {
        let loose = workingDirectory.appendingPathComponent("BigEditTool")
        FileManager.default.createFile(atPath: loose.path, contents: Data())
        XCTAssertNil(try CommandLineTool.applicationURL(forExecutableAt: loose.path))
    }
}
