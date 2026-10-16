import XCTest
@testable import BigEdit

final class ShellScriptTests: XCTestCase {

    func testRecognisedByExtensionOrDotfileName() {
        XCTAssertTrue(LanguageRegistry.shell.matches(fileName: "make-app.sh"))
        XCTAssertTrue(LanguageRegistry.shell.matches(fileName: "setup.ZSH"))
        XCTAssertTrue(LanguageRegistry.shell.matches(fileName: ".zshrc"))
        XCTAssertTrue(LanguageRegistry.shell.matches(fileName: ".bash_profile"))
        XCTAssertFalse(LanguageRegistry.shell.matches(fileName: "notes.txt"))
        XCTAssertFalse(LanguageRegistry.shell.matches(fileName: "zshrc"))
    }

    func testRecognisedByInterpreterLine() {
        XCTAssertTrue(ShellScript.isShellInterpreterLine("#!/bin/sh"))
        XCTAssertTrue(ShellScript.isShellInterpreterLine("#!/bin/bash -e"))
        XCTAssertTrue(ShellScript.isShellInterpreterLine("#! /usr/bin/env zsh"))
        XCTAssertTrue(ShellScript.isShellInterpreterLine("#!/usr/bin/env -S bash -x"))
        XCTAssertFalse(ShellScript.isShellInterpreterLine("#!/usr/bin/env python3"))
        XCTAssertFalse(ShellScript.isShellInterpreterLine("# not a shebang /bin/sh"))
        XCTAssertFalse(ShellScript.isShellInterpreterLine("#!"))
    }
}
