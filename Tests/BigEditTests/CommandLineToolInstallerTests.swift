import XCTest
@testable import BigEdit

/// The installer builds a shell command and wraps it in an AppleScript string
/// to run it with administrator rights. Two layers of quoting over a path the
/// user chose is exactly where this would break, so both are pinned down here —
/// and checked by actually running the result through `sh`.
final class CommandLineToolInstallerTests: XCTestCase {

    // MARK: - Shell quoting

    func testPlainPathIsQuoted() {
        XCTAssertEqual(CommandLineToolInstaller.shellQuoted("/usr/local/bin"),
                       "'/usr/local/bin'")
    }

    func testSpacesSurviveQuoting() {
        XCTAssertEqual(CommandLineToolInstaller.shellQuoted("/My Apps/BigEdit.app"),
                       "'/My Apps/BigEdit.app'")
    }

    func testSingleQuoteIsClosedEscapedAndReopened() {
        XCTAssertEqual(CommandLineToolInstaller.shellQuoted("/Users/o'brien/BigEdit.app"),
                       "'/Users/o'\\''brien/BigEdit.app'")
    }

    /// The real check: a quoted path must come back out of `sh` unchanged.
    func testQuotedPathsRoundTripThroughTheShell() throws {
        let awkward = [
            "/tmp/plain",
            "/tmp/with space",
            "/tmp/o'brien",
            "/tmp/quote\"double",
            "/tmp/dollar$HOME",
            "/tmp/back\\slash",
            "/tmp/semi;colon && rm -rf /",
            "/tmp/paren(s)"
        ]
        for path in awkward {
            let output = try runShell("printf '%s' \(CommandLineToolInstaller.shellQuoted(path))")
            XCTAssertEqual(output, path, "shell mangled \(path)")
        }
    }

    // MARK: - AppleScript quoting

    func testAppleScriptWrapsInDoubleQuotes() {
        XCTAssertEqual(CommandLineToolInstaller.appleScriptQuoted("ls -l"), "\"ls -l\"")
    }

    func testAppleScriptEscapesQuotesAndBackslashes() {
        XCTAssertEqual(CommandLineToolInstaller.appleScriptQuoted("say \"hi\""),
                       "\"say \\\"hi\\\"\"")
        XCTAssertEqual(CommandLineToolInstaller.appleScriptQuoted("a\\b"), "\"a\\\\b\"")
    }

    /// A path with a single quote goes through both layers; the AppleScript
    /// layer must not disturb the shell layer's escaping.
    func testBothLayersComposeForAnAwkwardPath() {
        let quoted = CommandLineToolInstaller.shellQuoted("/Users/o'brien/BigEdit.app")
        let script = CommandLineToolInstaller.appleScriptQuoted("ln -sf \(quoted) /usr/local/bin")
        XCTAssertTrue(script.hasPrefix("\""))
        XCTAssertTrue(script.hasSuffix("\""))
        XCTAssertFalse(script.dropFirst().dropLast().contains("\""),
                       "an unescaped quote would end the AppleScript string early")
    }

    // MARK: - Destination

    func testDestinationIsTheToolNameOnThePath() {
        XCTAssertEqual(CommandLineToolInstaller.destinationURL.path, "/usr/local/bin/bigedit")
    }

    // MARK: - Helper

    private func runShell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
