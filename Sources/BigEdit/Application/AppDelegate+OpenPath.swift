import AppKit

/// File ▸ Open Path…: opens a file by a typed or pasted path. A relative
/// path starts from the active document's folder, or the home folder.
extension AppDelegate {

    @objc func showOpenPath() {
        let alert = NSAlert()
        alert.messageText = "Open Path"
        alert.informativeText = "Type or paste the path of a file or folder."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "~/Documents/file.txt"
        field.stringValue = openPathBase.path + "/"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.openEnteredPath(field.stringValue)
            }
        }
    }

    private var openPathBase: URL {
        let folder = activeDocument.flatMap { $0.isUntitled ? nil : $0.url.deletingLastPathComponent() }
        return folder ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func openEnteredPath(_ text: String) {
        var isDirectory: ObjCBool = false
        if let url = EnteredPath.url(from: text, relativeTo: openPathBase),
           FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                chooseDocument(in: url)
            } else {
                openDocuments(at: [url])
            }
        } else {
            presentMissingPath(text)
        }
    }

    private func chooseDocument(in folder: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            if response == .OK {
                self?.openDocuments(at: panel.urls)
            }
        }
    }

    private func presentMissingPath(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot Open File"
        alert.informativeText = "There is no file at “\(text.trimmingCharacters(in: .whitespaces))”."
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { _ in }
    }
}
