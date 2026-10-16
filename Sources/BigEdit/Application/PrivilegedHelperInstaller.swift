import BigEditHelperKit
import Foundation
import ServiceManagement

/// Registers and talks to BigEdit's privileged helper.
///
/// Creating a symlink in a root-owned directory needs root, and macOS gives an
/// app no supported way to run a command as root itself. The supported route is
/// a launch daemon shipped inside the app bundle and registered with
/// `SMAppService`. The system then asks the user to allow it once, under Login
/// Items in System Settings.
///
/// After that one approval, installing or re-pointing the command needs no
/// prompt at all.
enum PrivilegedHelperInstaller {

    enum HelperFailure: Error {
        case requiresApproval
        case registrationFailed(String)
        case daemonMissingFromBundle
        case notReachable
        case refused(String)
    }

    private static var daemon: SMAppService {
        SMAppService.daemon(plistName: HelperService.launchdPlistName)
    }

    // MARK: - Installing the command

    /// Points the command at `toolURL`, registering the helper first if it has
    /// not been registered yet.
    static func installCommandLineTool(toolURL: URL, destination: URL) throws {
        try ensureDaemonEnabled()
        try withHelper { helper, finish in
            helper.installLink(atDestination: destination.path,
                               pointingTo: toolURL.path) { refusal in
                finish(refusal.map { HelperFailure.refused($0) })
            }
        }
    }

    /// Opens Login Items in System Settings, where the user allows the helper.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Registration

    /// Registers the daemon when it is not registered yet, then insists that it
    /// is enabled.
    private static func ensureDaemonEnabled() throws {
        let service = daemon
        if service.status == .notRegistered {
            try register(service)
        }
        try requireEnabled(service.status)
    }

    /// Registering a daemon for the first time fails until the user has
    /// approved it, so a failure that leaves it awaiting approval is expected.
    private static func register(_ service: SMAppService) throws {
        do {
            try service.register()
        } catch {
            if service.status != .requiresApproval {
                throw HelperFailure.registrationFailed(error.localizedDescription)
            }
        }
    }

    private static func requireEnabled(_ status: SMAppService.Status) throws {
        switch status {
        case .enabled:
            break
        case .requiresApproval:
            throw HelperFailure.requiresApproval
        case .notRegistered:
            throw HelperFailure.registrationFailed("the helper is not registered")
        case .notFound:
            throw HelperFailure.daemonMissingFromBundle
        @unknown default:
            throw HelperFailure.registrationFailed("unknown helper status (\(status.rawValue))")
        }
    }

    // MARK: - Talking to the helper

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
