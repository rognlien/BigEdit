import Foundation

/// Installs the bundled `bigedit` tool onto the user's `PATH` as a symlink.
///
/// A symlink rather than a copy, so the tool is whatever version the app is —
/// an update to BigEdit updates the command with it, and there is no second
/// binary to go stale.
enum CommandLineToolInstaller {

    static let toolName = "bigedit"
    static let destinationDirectory = "/usr/local/bin"

    enum InstallationFailure: Error {
        case toolMissingFromBundle
        case authorisationRefused
        case failed(String)
    }

    /// Where the tool lives inside the running app.
    static var bundledToolURL: URL? {
        Bundle.main.sharedSupportURL?
            .appendingPathComponent("bin")
            .appendingPathComponent(toolName)
    }

    /// Where the symlink goes.
    static var destinationURL: URL {
        URL(fileURLWithPath: destinationDirectory).appendingPathComponent(toolName)
    }

    /// Whether the command already points at this copy of the app.
    static var isInstalled: Bool {
        var result = false
        if let bundledToolURL,
           let target = try? FileManager.default.destinationOfSymbolicLink(
            atPath: destinationURL.path) {
            result = URL(fileURLWithPath: target).standardizedFileURL
                == bundledToolURL.standardizedFileURL
        }
        return result
    }

    /// Creates the symlink, asking for an administrator password only if the
    /// destination cannot be written directly.
    static func install() throws {
        guard let bundledToolURL,
              FileManager.default.isExecutableFile(atPath: bundledToolURL.path) else {
            throw InstallationFailure.toolMissingFromBundle
        }
        if !linkDirectly(from: bundledToolURL) {
            try linkWithAdministratorRights(from: bundledToolURL)
        }
    }

    /// Replaces the link without a password, when the directory allows it.
    /// Returns false if anything at all is in the way, so the privileged path
    /// gets its turn.
    private static func linkDirectly(from toolURL: URL) -> Bool {
        var succeeded = false
        let manager = FileManager.default
        if manager.isWritableFile(atPath: destinationDirectory) {
            do {
                // Remove first: createSymbolicLink will not overwrite, and a
                // stale link from an older install is the common case.
                if manager.fileExists(atPath: destinationURL.path)
                    || (try? manager.destinationOfSymbolicLink(atPath: destinationURL.path)) != nil {
                    try manager.removeItem(at: destinationURL)
                }
                try manager.createSymbolicLink(at: destinationURL, withDestinationURL: toolURL)
                succeeded = true
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    /// Falls back to an authenticated shell, which is what a stock macOS needs:
    /// /usr/local/bin is root-owned, and on a clean install may not exist.
    private static func linkWithAdministratorRights(from toolURL: URL) throws {
        let command = "/bin/mkdir -p \(shellQuoted(destinationDirectory)) && "
            + "/bin/ln -sf \(shellQuoted(toolURL.path)) \(shellQuoted(destinationURL.path))"
        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"

        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 {                     // the user cancelled the prompt
                throw InstallationFailure.authorisationRefused
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            throw InstallationFailure.failed(message)
        }
    }

    // MARK: - Quoting

    /// A path as a single shell word. Wrapping in single quotes protects every
    /// character except a single quote, which has to be closed, escaped, and
    /// reopened.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A shell command as an AppleScript string literal.
    static func appleScriptQuoted(_ command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
