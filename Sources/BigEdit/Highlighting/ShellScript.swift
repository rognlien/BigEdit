import Foundation

/// Tells shell scripts apart by name or by their `#!` line.
enum ShellScript {

    private static let extensions: Set<String> = ["sh", "bash", "zsh", "ksh", "command", "bats"]
    private static let fileNames: Set<String> = [
        ".profile", ".bashrc", ".bash_profile", ".bash_login", ".bash_logout",
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".kshrc"
    ]
    private static let interpreters: Set<String> = ["sh", "bash", "zsh", "ksh", "dash", "ash", "mksh"]
    private static let interpreterLineLimit = 128

    static func isShellScript(named fileName: String) -> Bool {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        return extensions.contains(fileExtension) || fileNames.contains(fileName)
    }

    /// True for a file whose first line is `#!/bin/sh`, `#!/usr/bin/env bash`
    /// or the like.
    static func startsWithShellInterpreter(_ file: MappedFile) -> Bool {
        let buffer = file.buffer
        let limit = min(buffer.count, interpreterLineLimit)
        let lineEnd = (0..<limit).first { buffer[$0] == 0x0A } ?? limit
        let line = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[0..<lineEnd]), as: UTF8.self)
        return isShellInterpreterLine(line)
    }

    static func isShellInterpreterLine(_ line: String) -> Bool {
        var result = false
        if line.hasPrefix("#!") {
            let words = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
            let program = words.first.map { ($0 as NSString).lastPathComponent }
            let interpreter = program == "env"
                ? words.dropFirst().first { !$0.hasPrefix("-") }
                : program
            result = interpreter.map(interpreters.contains) ?? false
        }
        return result
    }
}
