import AppKit

/// Owns the window, the menu, and the open-file flow.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {

    private var window: NSWindow!
    private let documentView = DocumentView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))

    private var openFile: MappedFile?
    private var lineIndex: LineIndex?
    private var fileName = ""
    private var saveProgressSheet: SaveProgressSheet?

    private let openRecentMenu = NSMenu(title: "Open Recent")
    private var didOpenFromURL = false
    private static let lastFilePathDefaultsKey = "BigEditLastFilePath"

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BigEdit"
        window.contentView = documentView
        // BigEdit has only one document per process — opt out of the system
        // tab bar AppKit would otherwise show when "Prefer tabs" is on.
        window.tabbingMode = .disallowed
        // Keep the window object alive after the user closes it, so a Dock
        // click can reopen the same document instead of relaunching the app.
        window.isReleasedWhenClosed = false
        // AppKit will remember the window's size and position between launches.
        window.setFrameAutosaveName("BigEditMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // If the launch didn't come with a file (via `application(_:open:)`),
        // restore the last one viewed. Scheduled on the next run loop tick so
        // any pending open-URL event has a chance to fire first.
        DispatchQueue.main.async { [weak self] in
            self?.restoreLastFileIfNeeded()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive after the window is closed; a Dock click brings it back.
        // The user quits with ⌘Q.
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            window.makeKeyAndOrderFront(nil)
            // If we never opened anything (rare — only if the user closed the
            // window before opening a file), try to restore the last one.
            if openFile == nil {
                restoreLastFileIfNeeded()
            }
        }
        return true
    }

    // MARK: - URL opens (Finder double-click, drag-to-Dock, Open Recent)

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            didOpenFromURL = true
            loadFile(at: url)
        }
    }

    private func restoreLastFileIfNeeded() {
        if didOpenFromURL || openFile != nil {
            return
        }
        guard let path = UserDefaults.standard.string(forKey: AppDelegate.lastFilePathDefaultsKey),
              FileManager.default.fileExists(atPath: path) else {
            return
        }
        loadFile(at: URL(fileURLWithPath: path))
    }

    // MARK: - Open Recent menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === openRecentMenu {
            populateOpenRecentMenu()
        }
    }

    private func populateOpenRecentMenu() {
        openRecentMenu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            openRecentMenu.addItem(empty)
        } else {
            for url in urls {
                let item = NSMenuItem(
                    title: url.lastPathComponent,
                    action: #selector(openRecentDocument(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.toolTip = url.path
                item.representedObject = url
                openRecentMenu.addItem(item)
            }
        }
        openRecentMenu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(
            title: "Clear Menu",
            action: #selector(clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = !urls.isEmpty
        openRecentMenu.addItem(clearItem)
    }

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            loadFile(at: url)
        }
    }

    @objc private func clearRecentDocuments(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit BigEdit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(
            title: "Open…",
            action: #selector(openDocument),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)

        let openRecentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentMenu.delegate = self
        openRecentMenu.autoenablesItems = false
        openRecentItem.submenu = openRecentMenu
        fileMenu.addItem(openRecentItem)

        fileMenu.addItem(NSMenuItem.separator())

        let saveItem = NSMenuItem(title: "Save", action: #selector(save), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: "Save As…", action: #selector(saveAs), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)

        fileMenu.addItem(NSMenuItem.separator())

        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSResponder.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let infoItem = NSMenuItem(
            title: "Info Inspector",
            action: #selector(toggleInfoPane),
            keyEquivalent: "i"
        )
        infoItem.keyEquivalentModifierMask = [.command, .option]
        infoItem.target = self
        viewMenu.addItem(infoItem)
        viewMenuItem.submenu = viewMenu

        let findMenuItem = NSMenuItem()
        mainMenu.addItem(findMenuItem)
        findMenuItem.submenu = buildFindMenu()

        NSApp.mainMenu = mainMenu
    }

    private func buildFindMenu() -> NSMenu {
        let findMenu = NSMenu(title: "Find")

        let findItem = NSMenuItem(title: "Find…", action: #selector(performFind), keyEquivalent: "f")
        findItem.target = self
        findMenu.addItem(findItem)

        let replaceItem = NSMenuItem(title: "Find & Replace…", action: #selector(performFindReplace), keyEquivalent: "f")
        replaceItem.keyEquivalentModifierMask = [.command, .option]
        replaceItem.target = self
        findMenu.addItem(replaceItem)

        let nextItem = NSMenuItem(title: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        nextItem.target = self
        findMenu.addItem(nextItem)

        let previousItem = NSMenuItem(title: "Find Previous", action: #selector(findPrevious), keyEquivalent: "g")
        previousItem.keyEquivalentModifierMask = [.command, .shift]
        previousItem.target = self
        findMenu.addItem(previousItem)

        findMenu.addItem(NSMenuItem.separator())

        let goToLineItem = NSMenuItem(
            title: "Go to Line…",
            action: #selector(performGoToLine),
            keyEquivalent: "l"
        )
        goToLineItem.target = self
        findMenu.addItem(goToLineItem)

        return findMenu
    }

    @objc private func performFind() {
        documentView.showFindBar(replace: false)
    }

    @objc private func performFindReplace() {
        documentView.showFindBar(replace: true)
    }

    @objc private func toggleInfoPane() {
        documentView.toggleInfoPane()
    }

    @objc private func performGoToLine() {
        documentView.showGoToLineSheet()
    }

    @objc private func findNext() {
        documentView.findNext()
    }

    @objc private func findPrevious() {
        documentView.findPrevious()
    }

    // MARK: - Opening files

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.loadFile(at: url)
            }
        }
    }

    private func loadFile(at url: URL) {
        if let file = MappedFile(path: url.path) {
            beginViewing(file: file, name: url.lastPathComponent)
        } else {
            presentError("Could not open \(url.lastPathComponent).")
        }
    }

    /// Shows the file immediately and kicks off background indexing.
    private func beginViewing(file: MappedFile, name: String) {
        // Stop the previous file's indexer so we don't keep churning on a
        // document the user has already moved on from.
        lineIndex?.cancel()

        let index = LineIndex()
        openFile = file
        lineIndex = index
        fileName = name

        let url = URL(fileURLWithPath: file.path)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        UserDefaults.standard.set(file.path, forKey: AppDelegate.lastFilePathDefaultsKey)

        documentView.load(file: file, index: index)
        window.makeFirstResponder(documentView.viewport)
        updateTitle()

        index.build(from: file) { [weak self] in
            self?.documentView.refresh()
            self?.updateTitle()
        }
    }

    private func updateTitle() {
        var title = "BigEdit"
        if let index = lineIndex, let file = openFile {
            let lines = numberFormatter.string(from: NSNumber(value: index.count)) ?? "\(index.count)"
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
            let status = index.isComplete ? "" : "  (indexing…)"
            title = "BigEdit — \(fileName) — \(bytes) — \(lines) lines\(status)"
        }
        window.title = title
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot Open File"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func presentSaveError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Save Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Saving

    @objc private func save() {
        if let file = openFile, let rule = documentView.currentRule {
            performSave(of: file, rule: rule, to: URL(fileURLWithPath: file.path))
        }
    }

    @objc private func saveAs() {
        if let file = openFile, let rule = documentView.currentRule {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = fileName
            panel.directoryURL = URL(fileURLWithPath: file.path).deletingLastPathComponent()
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.performSave(of: file, rule: rule, to: url)
                }
            }
        }
    }

    /// Runs the streaming write under a progress sheet; on success re-loads
    /// the saved file so the document reflects what is now on disk.
    private func performSave(of file: MappedFile, rule: ReplacementRule, to destination: URL) {
        let sheet = SaveProgressSheet(fileName: destination.lastPathComponent)
        let cancelToken = CancelToken()
        sheet.onCancel = { cancelToken.cancel() }
        saveProgressSheet = sheet
        window.beginSheet(sheet.window) { _ in }

        FileWriter.save(
            file: file,
            rule: rule,
            to: destination,
            cancelToken: cancelToken,
            onProgress: { fraction in
                sheet.setProgress(fraction)
            },
            completion: { [weak self] result in
                self?.window.endSheet(sheet.window)
                self?.saveProgressSheet = nil
                self?.handleSaveResult(result, destination: destination)
            }
        )
    }

    private func handleSaveResult(
        _ result: Result<Void, FileWriter.WriteError>,
        destination: URL
    ) {
        switch result {
        case .success:
            loadFile(at: destination)
        case .failure(let error):
            if case .cancelled = error {
                return  // Silent on cancel; original file untouched.
            }
            presentSaveError(error.localizedDescription)
        }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        var enabled = true
        switch menuItem.action {
        case #selector(save), #selector(saveAs):
            enabled = openFile != nil && documentView.currentRule != nil
        case #selector(toggleInfoPane):
            menuItem.state = documentView.isInfoPaneVisible ? .on : .off
            enabled = openFile != nil
        case #selector(performGoToLine):
            enabled = openFile != nil
        default:
            break
        }
        return enabled
    }
}
