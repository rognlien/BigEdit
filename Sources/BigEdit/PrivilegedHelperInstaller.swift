import BigEditHelperKit
import Foundation
import Security
import ServiceManagement

/// Installs and talks to BigEdit's privileged helper.
///
/// Creating a symlink in a root-owned directory needs root, and macOS gives an
/// app no supported way to run a command as root itself. The supported route is
/// a launchd daemon blessed once by the user; the system's authorisation dialog
/// for that supports **Touch ID**, which is why the command install asks for a
/// fingerprint rather than a typed password.
///
/// After the one-time blessing, installing or re-pointing the command needs no
/// prompt at all.
enum PrivilegedHelperInstaller {

    enum HelperFailure: Error {
        case authorisationRefused
        case blessingFailed(String)
        case notReachable
        case refused(String)
    }

    /// Shown in the authorisation dialog above the password / Touch ID prompt.
    /// The system prefixes it with the app name, so this says what and where.
    static let authorisationPrompt =
        "BigEdit needs your permission once to install a small helper, "
        + "so it can add the “bigedit” command to \(CommandLineToolInstaller.destinationDirectory). "
        + "You will not be asked again."

    // MARK: - Installing the command

    /// Points the command at `toolURL`, blessing the helper first if it is
    /// missing or out of date.
    static func installCommandLineTool(toolURL: URL, destination: URL) throws {
        if try !isHelperCurrent() {
            try blessHelper()
        }
        try withHelper { helper, finish in
            helper.installLink(atDestination: destination.path,
                               pointingTo: toolURL.path) { refusal in
                finish(refusal.map { HelperFailure.refused($0) })
            }
        }
    }

    // MARK: - The blessing

    /// Asks the user to authorise installing the helper, then installs it.
    private static func blessHelper() throws {
        var rightName = kSMRightBlessPrivilegedHelper.utf8CString
        var promptText = authorisationPrompt.utf8CString

        let authorization = try rightName.withUnsafeMutableBufferPointer { rightBuffer in
            try promptText.withUnsafeMutableBufferPointer { promptBuffer in
                try createAuthorization(rightName: rightBuffer.baseAddress!,
                                        prompt: promptBuffer.baseAddress!)
            }
        }
        defer { AuthorizationFree(authorization, []) }

        var blessError: Unmanaged<CFError>?
        let blessed = SMJobBless(kSMDomainSystemLaunchd,
                                 HelperService.machServiceName as CFString,
                                 authorization,
                                 &blessError)
        if !blessed {
            let message = blessError?.takeRetainedValue().localizedDescription
                ?? "the helper could not be installed"
            throw HelperFailure.blessingFailed(message)
        }
    }

    /// Builds an authorisation for the bless right, with our own prompt text.
    /// `kAuthorizationFlagInteractionAllowed` is what lets the system show the
    /// dialog — and therefore what allows Touch ID.
    private static func createAuthorization(
        rightName: UnsafeMutablePointer<CChar>,
        prompt: UnsafeMutablePointer<CChar>
    ) throws -> AuthorizationRef {
        var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        var rights = withUnsafeMutablePointer(to: &item) {
            AuthorizationRights(count: 1, items: $0)
        }
        var promptItem = AuthorizationItem(
            name: kAuthorizationEnvironmentPrompt,
            valueLength: strlen(prompt),
            value: UnsafeMutableRawPointer(prompt),
            flags: 0
        )
        var environment = withUnsafeMutablePointer(to: &promptItem) {
            AuthorizationEnvironment(count: 1, items: $0)
        }

        var authorization: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .preAuthorize, .extendRights]
        let status = AuthorizationCreate(&rights, &environment, flags, &authorization)

        guard status == errAuthorizationSuccess, let authorization else {
            throw status == errAuthorizationCanceled
                ? HelperFailure.authorisationRefused
                : HelperFailure.blessingFailed("authorisation failed (\(status))")
        }
        return authorization
    }

    // MARK: - Talking to the helper

    /// Whether a helper is installed and matches the version this app expects.
    private static func isHelperCurrent() throws -> Bool {
        var current = false
        do {
            try withHelper { helper, finish in
                helper.fetchVersion { version in
                    current = version == HelperService.version
                    finish(nil)
                }
            }
        } catch {
            current = false          // nothing listening: it needs installing
        }
        return current
    }

    /// Runs one call against the helper and waits for its reply.
    private static func withHelper(
        _ body: (CommandLineToolHelperProtocol, @escaping (Error?) -> Void) -> Void
    ) throws {
        let connection = NSXPCConnection(machServiceName: HelperService.machServiceName,
                                         options: .privileged)
        connection.remoteObjectInterface =
            NSXPCInterface(with: CommandLineToolHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let waiter = DispatchSemaphore(value: 0)
        var failure: Error?
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            failure = HelperFailure.notReachable
            _ = error
            waiter.signal()
        }
        guard let helper = proxy as? CommandLineToolHelperProtocol else {
            throw HelperFailure.notReachable
        }
        body(helper) { error in
            failure = error ?? failure
            waiter.signal()
        }

        if waiter.wait(timeout: .now() + 30) == .timedOut {
            throw HelperFailure.notReachable
        }
        if let failure {
            throw failure
        }
    }
}
