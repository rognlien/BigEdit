import XCTest
@testable import BigEdit

final class ShellScriptTests: XCTestCase {

    func testRecognisedByExtensionOrDotfileName() {
        XCTAssertTrue(ShellScript.isShellScript(named: "make-app.sh"))
        XCTAssertTrue(ShellScript.isShellScript(named: "setup.ZSH"))
        XCTAssertTrue(ShellScript.isShellScript(named: ".zshrc"))
        XCTAssertTrue(ShellScript.isShellScript(named: ".bash_profile"))
        XCTAssertFalse(ShellScript.isShellScript(named: "notes.txt"))
        XCTAssertFalse(ShellScript.isShellScript(named: "zshrc"))
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
