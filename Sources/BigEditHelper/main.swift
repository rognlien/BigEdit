import BigEditHelperKit
import Foundation
import Security

/// The privileged helper: a launchd daemon running as root whose entire job is
/// to create one symlink on behalf of BigEdit.
///
/// It is deliberately tiny and deliberately narrow. It accepts one verb, on a
/// fixed list of destination directories, and only from a client that is
/// BigEdit itself — checked against the code-signing requirement below rather
/// than taken on trust, because anything that can talk to this process is
/// talking to root.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate,
                                    CommandLineToolHelperProtocol {

    /// Only a copy of BigEdit signed by this team may connect.
    private static let clientRequirement =
        "identifier \"io.maendeleo.BigEdit\" and anchor apple generic and "
        + "certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Baked in at build time by make-app.sh; the placeholder is what a local
    /// unsigned build gets, and it rejects every client.
    private static let teamIdentifier = "TEAM_ID_PLACEHOLDER"

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var accepted = false
        if isTrusted(connection) {
            connection.exportedInterface =
                NSXPCInterface(with: CommandLineToolHelperProtocol.self)
            connection.exportedObject = self
            connection.resume()
            accepted = true
        }
        return accepted
    }

    /// Checks the connecting process against the requirement.
    ///
    /// Identified by process id, which is what `NSXPCConnection` exposes
    /// publicly. An audit token would be stronger — a pid can in principle be
    /// reused between the check and the call — but reading one from an
    /// `NSXPCConnection` needs private API, and a privileged helper is the last
    /// place to depend on that. The narrow verb and the fixed destination list
    /// are what keep the blast radius small either way.
    private func isTrusted(_ connection: NSXPCConnection) -> Bool {
        var trusted = false
        let processIdentifier = connection.processIdentifier
        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary

        var code: SecCode?
        var requirement: SecRequirement?
        if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
           SecRequirementCreateWithString(HelperListenerDelegate.clientRequirement as CFString,
                                          [], &requirement) == errSecSuccess,
           let code, let requirement {
            trusted = SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        }
        return trusted
    }

    // MARK: - The service

    func fetchVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperService.version)
    }

    func installLink(atDestination destinationPath: String,
                     pointingTo toolPath: String,
                     withReply reply: @escaping (String?) -> Void) {
        var failure: String?
        do {
            try LinkInstallation.install(toolPath: toolPath, destinationPath: destinationPath)
        } catch {
            failure = "\(error)"
        }
        reply(failure)
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperService.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
