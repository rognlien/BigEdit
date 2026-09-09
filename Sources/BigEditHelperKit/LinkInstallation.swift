import Foundation

/// The work the helper does once it has agreed to do it.
///
/// Separated from the XPC plumbing so it can be tested as an ordinary function,
/// against real directories, without anything privileged happening.
public enum LinkInstallation {

    public enum Refusal: Error, Equatable {
        case destinationNotPermitted(String)
        case toolMissing(String)
        case failed(String)
    }

    /// Creates a symlink at `destinationPath` pointing at `toolPath`, replacing
    /// whatever is already there.
    ///
    /// `permittedDirectories` is injectable only so tests can point it at a
    /// temporary directory; the helper always passes the real list.
    public static func install(
        toolPath: String,
        destinationPath: String,
        permittedDirectories: [String] = HelperService.permittedDestinationDirectories
    ) throws {
        guard isPermitted(destinationPath, within: permittedDirectories) else {
            throw Refusal.destinationNotPermitted(destinationPath)
        }
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: toolPath) else {
            throw Refusal.toolMissing(toolPath)
        }

        let destination = URL(fileURLWithPath: destinationPath)
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            // createSymbolicLink refuses to overwrite, and replacing a link
            // from an earlier install is the ordinary case.
            if manager.fileExists(atPath: destinationPath)
                || (try? manager.destinationOfSymbolicLink(atPath: destinationPath)) != nil {
                try manager.removeItem(at: destination)
            }
            try manager.createSymbolicLink(at: destination,
                                           withDestinationURL: URL(fileURLWithPath: toolPath))
        } catch {
            throw Refusal.failed("\(error.localizedDescription)")
        }
    }

    /// Whether the destination sits directly inside one of `directories`.
    static func isPermitted(_ path: String, within directories: [String]) -> Bool {
        var result = false
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let directory = standardized.deletingLastPathComponent().path
        let name = standardized.lastPathComponent
        if directories.contains(directory), !name.isEmpty, name != ".", name != "..",
           !path.contains("..") {
            result = true
        }
        return result
    }
}
