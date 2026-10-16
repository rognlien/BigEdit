import Foundation

/// Names and the contract shared by BigEdit and its privileged helper.
///
/// The helper exists for one reason: creating a symlink in a root-owned
/// directory such as `/usr/local/bin`. An app cannot do that itself — macOS has
/// no supported way to run a command as root from an app process — so the work
/// is handed to a launchd daemon that already runs as root.
///
/// The daemon ships inside the app bundle and is registered with
/// `SMAppService`; the user allows it once under Login Items in System
/// Settings. After that, later installs and updates of the command need no
/// prompt at all.
public enum HelperService {

    /// The launchd label and Mach service name. Must match the helper's
    /// launchd plist, which the bundle carries in `Contents/Library/LaunchDaemons`.
    ///
    /// Deliberately not the label of the helper that earlier versions blessed
    /// with `SMJobBless` (`io.maendeleo.BigEdit.helper`): launchd allows one job
    /// per label in the system domain, so reusing it would collide with that
    /// helper wherever it is still installed.
    public static let machServiceName = "io.maendeleo.BigEdit.daemon"

    /// The launchd plist's file name inside `Contents/Library/LaunchDaemons`.
    public static let launchdPlistName = "\(machServiceName).plist"

    /// Bumped whenever the helper's behaviour changes, so a running helper can
    /// be told apart from the one this app ships.
    public static let version = "2.0"

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
