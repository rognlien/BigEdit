import Foundation

/// Names and the contract shared by BigEdit and its privileged helper.
///
/// The helper exists for one reason: creating a symlink in a root-owned
/// directory such as `/usr/local/bin`. An app cannot do that itself — macOS has
/// no supported way to run a command as root from an app process — so the work
/// is handed to a launchd daemon that already runs as root.
///
/// Installing that daemon is what the user authorises, and the system's
/// authorisation dialog supports Touch ID. Once installed, later installs and
/// updates of the command need no prompt at all.
public enum HelperService {

    /// The launchd label and Mach service name. Must match the helper's
    /// embedded launchd plist and the app's `SMPrivilegedExecutables` key.
    public static let machServiceName = "io.maendeleo.BigEdit.helper"

    /// Bumped whenever the helper's behaviour changes, so the app can notice an
    /// older helper left behind by a previous version and replace it.
    public static let version = "1.0"

    /// Where the helper is willing to create links. Anything outside these is
    /// refused, so a compromised client cannot ask root to write anywhere it
    /// likes.
    public static let permittedDestinationDirectories = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/local/sbin"
    ]

    /// Whether `path` is a link the helper will agree to create: directly
    /// inside a permitted directory, with no traversal.
    public static func isPermittedDestination(_ path: String) -> Bool {
        var result = false
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        let directory = standardized.deletingLastPathComponent().path
        let name = standardized.lastPathComponent
        if permittedDestinationDirectories.contains(directory)
            && !name.isEmpty && name != "." && name != ".."
            && !path.contains("..") {
            result = true
        }
        return result
    }
}

/// What the app may ask the helper to do. Kept deliberately narrow: one verb,
/// no general file access, no shell.
@objc public protocol CommandLineToolHelperProtocol {

    /// Replies with the running helper's version, so the app can tell whether
    /// it needs replacing.
    func fetchVersion(withReply reply: @escaping (String) -> Void)

    /// Creates (or replaces) a symlink at `destinationPath` pointing at
    /// `toolPath`. Replies with `nil` on success, or a message describing the
    /// refusal or failure.
    func installLink(atDestination destinationPath: String,
                     pointingTo toolPath: String,
                     withReply reply: @escaping (String?) -> Void)
}
