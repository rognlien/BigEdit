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
            // Root-owned destination: hand it to the privileged helper, whose
            // one-time authorisation dialog supports Touch ID.
            try PrivilegedHelperInstaller.installCommandLineTool(
                toolURL: bundledToolURL, destination: destinationURL)
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
}
