import AppKit
import Sparkle

/// Owns the window, the menu, and the set of open documents. Several documents
/// can be open at once; a left-side sidebar switches between them, and the
/// active document is mounted in the content area on the right.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
                         NSMenuDelegate, NSSplitViewDelegate, SPUUpdaterDelegate {

    private var window: NSWindow!

    /// Drives Sparkle auto-updates (Check for Updates… + scheduled checks).
    /// Lazy so `self` can be the updater delegate (to flush state before a
    /// relaunch). Started on first access (menu build / launch check).
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    private let splitView = NSSplitView()
    private let sidebar = DocumentListView(frame: NSRect(x: 0, y: 0, width: 220, height: 640))
    private let contentContainer = ContentContainerView(frame: NSRect(x: 0, y: 0, width: 680, height: 640))
    private let titleLabel = NSTextField(labelWithString: "")

    private var documents: [Document] = []
    private var activeIndex: Int?
    private var saveProgressSheet: SaveProgressSheet?

    /// Held while the Process Lines sheet is up, so it is not deallocated
    /// before the user answers it.
    private var processLinesSheet: ProcessLinesSheet?

    private let openRecentMenu = NSMenu(title: "Open Recent")
    private var didOpenFromURL = false
    private static let lastFilePathDefaultsKey = "BigEditLastFilePath"
    private static let openDocumentsDefaultsKey = "BigEditOpenDocuments"
    private static let scrollRowsDefaultsKey = "BigEditScrollRows"
    private static let activeIndexDefaultsKey = "BigEditActiveIndex"
    private static let recentDocumentsDefaultsKey = "BigEditRecentDocuments"
    private static let maxRecentDocuments = 15
    private static let fontSizeDefaultsKey = "BigEditFontSize"

    /// The editor font size shared by all open documents, persisted across launches.
    private lazy var editorFontSize: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: AppDelegate.fontSizeDefaultsKey)
        return stored > 0 ? CGFloat(stored) : ViewportView.defaultFontSize
    }()

    private static let infoPaneWidthDefaultsKey = "BigEditInfoPaneWidth"

    /// The info-pane width shared by all open documents, persisted across launches.
    private lazy var infoPaneWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: AppDelegate.infoPaneWidthDefaultsKey)
        return stored > 0 ? CGFloat(stored) : InfoPane.preferredWidth
    }()

    private static let minSidebarWidth: CGFloat = 190
    private static let minContentWidth: CGFloat = 360

    // MARK: - Active document accessors

    private var activeDocument: Document? {
        guard let activeIndex, documents.indices.contains(activeIndex) else {
            return nil
        }
        return documents[activeIndex]
    }

    private var activeView: DocumentView? {
        activeDocument?.view
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Build the menu and window here, not in didFinishLaunching: a launch
        // that opens a document (e.g. dropping a file on the Dock icon) delivers
        // application(_:open:) before didFinishLaunching, and that path touches
        // the window — which must already exist.
        buildMenu()
        buildWindow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If the launch didn't come with a file (via `application(_:open:)`),
        // restore the previous session. Scheduled on the next run loop tick so
        // any pending open-URL event has a chance to fire first.
        DispatchQueue.main.async { [weak self] in
            self?.restoreSessionIfNeeded()
        }

        // Check for updates on every launch (silent — only surfaces UI if an
        // update is available), in addition to Sparkle's scheduled checks.
        updaterController.updater.checkForUpdatesInBackground()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BigEdit"
        // We do our own multi-document switching in one window — opt out of the
        // system tab bar AppKit would otherwise show when "Prefer tabs" is on.
        window.tabbingMode = .disallowed
        // Keep the window object alive after the user closes it, so a Dock
        // click can reopen the same documents instead of relaunching the app.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BigEditMainWindow")

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(contentContainer)
        splitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)
        splitView.autosaveName = "BigEditSplit"

        sidebar.onSelect = { [weak self] index in
            self?.selectDocument(at: index)
        }
        sidebar.onClose = { [weak self] index in
            self?.closeDocument(at: index)
        }
        contentContainer.onOpenFiles = { [weak self] urls in
            self?.openDocuments(at: urls)
        }
        sidebar.onOpenFiles = { [weak self] urls in
            self?.openDocuments(at: urls)
        }

        window.contentView = splitView
        installCenteredTitle()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hides the native (leading) title and draws a centered label in the title
    /// bar instead, so the file name sits in the middle of the window.
    private func installCenteredTitle() {
        window.titleVisibility = .hidden
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else {
            return
        }
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.font = NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        // ⌘-click the title to see the file's path, like a native proxy title.
        titleLabel.toolTip = "⌘-click to show the file path"
        let click = NSClickGestureRecognizer(target: self, action: #selector(titleClicked(_:)))
        titleLabel.addGestureRecognizer(click)
        titlebar.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titlebar.centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: titlebar.widthAnchor, multiplier: 0.6)
        ])
    }

    /// On ⌘-click, shows the file's path as a menu of folders (file at top down
    /// to the volume); choosing one reveals it in Finder — mirroring the native
    /// title-bar path popup.
    @objc private func titleClicked(_ sender: NSClickGestureRecognizer) {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true,
              let url = activeDocument?.url else {
            return
        }
        let menu = NSMenu()
        var current = url
        var safety = 0
        while safety < 256 {
            safety += 1
            let name = current.lastPathComponent.isEmpty ? "/" : current.lastPathComponent
            let item = NSMenuItem(title: name, action: #selector(revealPathComponent(_:)),
                                  keyEquivalent: "")
            let icon = NSWorkspace.shared.icon(forFile: current.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.representedObject = current
            item.target = self
            menu.addItem(item)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        // Show the menu after this event finishes: popping a modal menu
        // synchronously from inside the title bar's click handling deadlocks.
        let label = titleLabel
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: label.bounds.maxY), in: label)
        }
    }

    @objc private func revealPathComponent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive after the window is closed; a Dock click brings it back.
        // The user quits with ⌘Q.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var reply = NSApplication.TerminateReply.terminateNow
        let dirtyNames = documents.filter(\.isEdited).map(\.fileName)
        if !dirtyNames.isEmpty {
            let alert = NSAlert()
            let description = dirtyNames.count == 1
                ? dirtyNames[0]
                : "\(dirtyNames.count) documents"
            alert.messageText = "You have unsaved changes in \(description)."
            alert.informativeText = "Quitting now will discard those changes."
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() != .alertFirstButtonReturn {
                reply = .terminateCancel
            }
        }
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Capture final scroll positions for next launch.
        persistSession()
    }

    /// Sparkle relaunches the app after installing an update without a normal
    /// quit, so persist (and flush) the open-document session here — otherwise
    /// it's lost across the upgrade.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        persistSession()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows {
            window.makeKeyAndOrderFront(nil)
            // If nothing is open (rare — only if the window was closed before a
            // file was opened), try to restore the previous session.
            if documents.isEmpty {
                restoreSessionIfNeeded()
            }
        }
        return true
    }

    // MARK: - URL opens (Finder double-click, drag-to-Dock, Open Recent)

    func application(_ sender: NSApplication, open urls: [URL]) {
        if !urls.isEmpty {
            didOpenFromURL = true
            openDocuments(at: urls)
        }
    }

    /// Reopens the set of documents from the last session, selecting the one
    /// that was active. Falls back to the single legacy last-file key.
    private func restoreSessionIfNeeded() {
        if didOpenFromURL || !documents.isEmpty {
            return
        }
        let defaults = UserDefaults.standard
        var paths = defaults.stringArray(forKey: AppDelegate.openDocumentsDefaultsKey) ?? []
        if paths.isEmpty, let legacy = defaults.string(forKey: AppDelegate.lastFilePathDefaultsKey) {
            paths = [legacy]
        }
        let scrolls = defaults.array(forKey: AppDelegate.scrollRowsDefaultsKey) as? [Double] ?? []
        let savedActive = defaults.integer(forKey: AppDelegate.activeIndexDefaultsKey)
        let activePath = paths.indices.contains(savedActive) ? paths[savedActive] : nil

        // Keep each surviving path with its saved scroll position.
        var restorable: [(path: String, scroll: Double)] = []
        for (i, path) in paths.enumerated() where FileManager.default.fileExists(atPath: path) {
            restorable.append((path, i < scrolls.count ? scrolls[i] : 0))
        }
        if restorable.isEmpty {
            return
        }

        openDocuments(at: restorable.map { URL(fileURLWithPath: $0.path) })
        for (i, item) in restorable.enumerated() where documents.indices.contains(i) {
            if item.scroll > 0 {
                documents[i].pendingScrollRow = item.scroll
            }
        }
        if let activePath, let index = restorable.firstIndex(where: { $0.path == activePath }) {
            selectDocument(at: index)
        }
    }

    /// Persists the open document paths, scroll positions, and active index.
    private func persistSession() {
        let defaults = UserDefaults.standard
        defaults.set(documents.map { $0.url.path }, forKey: AppDelegate.openDocumentsDefaultsKey)
        defaults.set(documents.map { $0.view.viewport.scrollRow },
                     forKey: AppDelegate.scrollRowsDefaultsKey)
        defaults.set(activeIndex ?? 0, forKey: AppDelegate.activeIndexDefaultsKey)
        defaults.set(documents.last?.url.path, forKey: AppDelegate.lastFilePathDefaultsKey)
        // Flush so an abrupt termination (e.g. Sparkle's update relaunch) keeps it.
        defaults.synchronize()
    }

    // MARK: - Recent documents (own list — noteNewRecentDocumentURL doesn't
    // persist for a non-document app)

    private func addRecentDocument(_ url: URL) {
        let defaults = UserDefaults.standard
        var paths = defaults.stringArray(forKey: AppDelegate.recentDocumentsDefaultsKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > AppDelegate.maxRecentDocuments {
            paths = Array(paths.prefix(AppDelegate.maxRecentDocuments))
        }
        defaults.set(paths, forKey: AppDelegate.recentDocumentsDefaultsKey)
        defaults.synchronize()
        // Also feed the system list (Dock menu / Recent Items), best-effort.
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    private func recentDocumentURLs() -> [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: AppDelegate.recentDocumentsDefaultsKey) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Open Recent menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === openRecentMenu {
            populateOpenRecentMenu()
        }
    }

    private func populateOpenRecentMenu() {
        openRecentMenu.removeAllItems()
        let urls = recentDocumentURLs()
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
            openDocuments(at: [url])
        }
    }

    @objc private func clearRecentDocuments(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: AppDelegate.recentDocumentsDefaultsKey)
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About BigEdit",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())
        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = updaterController
        appMenu.addItem(updatesItem)

        appMenu.addItem(NSMenuItem.separator())
        let installToolItem = NSMenuItem(
            title: "Install Command Line Tool…",
            action: #selector(installCommandLineTool),
            keyEquivalent: ""
        )
        installToolItem.target = self
        appMenu.addItem(installToolItem)

        appMenu.addItem(NSMenuItem.separator())
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

        let newItem = NSMenuItem(
            title: "New",
            action: #selector(newDocument),
            keyEquivalent: "n"
        )
        newItem.target = self
        fileMenu.addItem(newItem)
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

        let reloadItem = NSMenuItem(
            title: "Reload from Disk",
            action: #selector(reloadActiveFromDisk),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        fileMenu.addItem(reloadItem)

        let revealItem = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(revealInFinder),
            keyEquivalent: ""
        )
        revealItem.target = self
        fileMenu.addItem(revealItem)

        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(closeActiveDocument),
            keyEquivalent: "w"
        )
        closeItem.target = self
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Undo",
            action: #selector(ViewportView.undo(_:)),
            keyEquivalent: "z"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Redo",
            action: #selector(ViewportView.redo(_:)),
            keyEquivalent: "Z"
        ))
        editMenu.addItem(NSMenuItem.separator())
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
        let processLinesItem = NSMenuItem(
            title: "Process Lines…",
            action: #selector(showProcessLines),
            keyEquivalent: "l"
        )
        processLinesItem.keyEquivalentModifierMask = [.command, .shift]
        processLinesItem.target = self
        editMenu.addItem(processLinesItem)

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
            keyEquivalent: "i"            // ⌘I, the standard "Get Info" shortcut
        )
        infoItem.target = self
        viewMenu.addItem(infoItem)

        viewMenu.addItem(NSMenuItem.separator())

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)

        let actualSizeItem = NSMenuItem(title: "Actual Size", action: #selector(actualSize), keyEquivalent: "0")
        actualSizeItem.target = self
        viewMenu.addItem(actualSizeItem)

        viewMenu.addItem(NSMenuItem.separator())
        let followItem = NSMenuItem(
            title: "Follow File",
            action: #selector(toggleFollowing),
            keyEquivalent: "t"
        )
        followItem.keyEquivalentModifierMask = [.command, .shift]
        followItem.target = self
        viewMenu.addItem(followItem)

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

        let resultsItem = NSMenuItem(title: "Search Results", action: #selector(toggleSearchResults),
                                     keyEquivalent: "l")
        resultsItem.keyEquivalentModifierMask = [.command, .option]
        resultsItem.target = self
        findMenu.addItem(resultsItem)

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
        activeView?.showFindBar(replace: false)
    }

    /// Lists every match of the current search below the viewport.
    @objc private func toggleSearchResults() {
        activeView?.toggleSearchResults()
    }

    @objc private func performFindReplace() {
        activeView?.showFindBar(replace: true)
    }

    @objc private func toggleInfoPane() {
        activeView?.toggleInfoPane()
    }

    @objc private func zoomIn() {
        setEditorFontSize(editorFontSize + 1)
    }

    @objc private func zoomOut() {
        setEditorFontSize(editorFontSize - 1)
    }

    @objc private func actualSize() {
        setEditorFontSize(ViewportView.defaultFontSize)
    }

    /// Applies a new editor font size to every open document and persists it.
    private func setEditorFontSize(_ size: CGFloat) {
        let clamped = min(max(size, ViewportView.minFontSize), ViewportView.maxFontSize)
        editorFontSize = clamped
        UserDefaults.standard.set(Double(clamped), forKey: AppDelegate.fontSizeDefaultsKey)
        for document in documents {
            document.view.viewport.setFontSize(clamped)
        }
    }

    /// Applies a new info-pane width to every open document and persists it.
    private func setInfoPaneWidth(_ width: CGFloat) {
        infoPaneWidth = width
        UserDefaults.standard.set(Double(width), forKey: AppDelegate.infoPaneWidthDefaultsKey)
        for document in documents {
            document.view.setInfoPaneWidth(width)
        }
    }

    /// Shows the standard About panel (icon, name, version, copyright from the
    /// Info.plist) with a clickable link to the website in its credits.
    /// Puts `bigedit` on the user's PATH, reporting what happened either way.
    /// The symlink points into this bundle, so updating BigEdit updates the
    /// command with it.
    @objc private func installCommandLineTool() {
        if CommandLineToolInstaller.isInstalled {
            presentInstallResult(
                title: "Already Installed",
                message: "The bigedit command is already linked to this copy of "
                    + "BigEdit at \(CommandLineToolInstaller.destinationURL.path)."
            )
            return
        }
        do {
            try CommandLineToolInstaller.install()
            presentInstallResult(
                title: "Command Line Tool Installed",
                message: "You can now run `bigedit file.txt` in a terminal. "
                    + "It opens the file in BigEdit, creating it if it does not exist.\n\n"
                    + "If your shell cannot find it, add "
                    + "\(CommandLineToolInstaller.destinationDirectory) to your PATH."
            )
        } catch PrivilegedHelperInstaller.HelperFailure.authorisationRefused {
            // The user dismissed the password prompt; that is an answer, not
            // an error worth an alarming dialog.
            return
        } catch {
            presentInstallResult(
                title: "Could Not Install the Command Line Tool",
                message: "\(error)",
                isError: true
            )
        }
    }

    private func presentInstallResult(title: String, message: String, isError: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = isError ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "maendeleo.io/bigedit",
            attributes: [
                .link: URL(string: "https://maendeleo.io/bigedit/") as Any,
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func performGoToLine() {
        activeView?.showGoToLineSheet()
    }

    @objc private func findNext() {
        activeView?.findNext()
    }

    @objc private func findPrevious() {
        activeView?.findPrevious()
    }

    // MARK: - Opening files

    /// Creates an empty file and opens it.
    ///
    /// BigEdit reads through `mmap`, so a document is always a real file —
    /// there is no untitled-and-unsaved state to fall back on. Asking where
    /// the file goes up front keeps every other part of the app (the file
    /// watcher, Open Recent, session restore, Save) working exactly as it does
    /// for a file that was already there.
    @objc private func newDocument() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.txt"
        panel.canCreateDirectories = true
        panel.message = "Choose where to create the new file."
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.createAndOpenDocument(at: url)
            }
        }
    }

    /// Writes an empty file at `url` and opens it, replacing anything already
    /// there — the save panel has already asked about overwriting.
    private func createAndOpenDocument(at url: URL) {
        if FileManager.default.createFile(atPath: url.path, contents: Data()) {
            openDocuments(at: [url])
        } else {
            presentError("Could not create \(url.lastPathComponent).")
        }
    }

    /// Asks which line operation to run, then runs it over the whole document.
    @objc private func showProcessLines() {
        guard let view = activeView, view.canProcessLines else {
            return
        }
        let sheet = ProcessLinesSheet()
        processLinesSheet = sheet
        sheet.present(in: window) { [weak self, weak view] operation in
            self?.processLinesSheet = nil
            if let operation, let view {
                self?.runProcessLines(operation, in: view)
            }
        }
    }

    private func runProcessLines(_ operation: LineOperation, in view: DocumentView) {
        view.processLines(operation) { [weak self] result in
            switch result {
            case .success:
                self?.updateTitle()
            case .failure(let error):
                self?.presentProcessLinesFailure(error)
            }
        }
    }

    private func presentProcessLinesFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        switch error {
        case DocumentView.ProcessLinesRefusal.tooLarge(let size, let limit):
            let formatter = ByteCountFormatter()
            alert.messageText = "This document is too large to process"
            alert.informativeText = "Processing lines holds the whole document in memory, so it "
                + "is limited to \(formatter.string(fromByteCount: Int64(limit))). "
                + "This one is \(formatter.string(fromByteCount: Int64(size)))."
        case DocumentView.ProcessLinesRefusal.notEditable:
            alert.messageText = "This document cannot be edited"
            alert.informativeText = "Processing lines rewrites the document, which is not "
                + "possible while a replacement rule or CSV view is active, or for a file that "
                + "is not UTF-8 text."
        case LineProcessor.ProcessingError.invalidPattern(let pattern):
            alert.messageText = "That pattern is not a valid regular expression"
            alert.informativeText = "“\(pattern)” could not be understood."
        default:
            alert.messageText = "Could not process the lines"
            alert.informativeText = "\(error)"
        }
        alert.beginSheetModal(for: window) { _ in }
    }

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            if response == .OK {
                self?.openDocuments(at: panel.urls)
            }
        }
    }

    /// Opens each URL as a new document and selects the last one.
    private func openDocuments(at urls: [URL]) {
        var lastOpened: Int?
        for url in urls {
            if let document = makeDocument(at: url) {
                documents.append(document)
                lastOpened = documents.count - 1
                addRecentDocument(url)
            } else {
                presentError("Could not open \(url.lastPathComponent).")
            }
        }
        if let lastOpened {
            sidebar.reload(documents: documents, selectedIndex: lastOpened)
            selectDocument(at: lastOpened)
        }
        persistSession()
    }

    /// Maps the file, builds a view + index, and kicks off background indexing.
    private func makeDocument(at url: URL) -> Document? {
        guard let file = MappedFile(path: url.path) else {
            return nil
        }
        let index = LineIndex()
        let view = DocumentView(frame: contentContainer.bounds)
        let document = Document(url: url, file: file, index: index, view: view)

        view.load(file: file, index: index)
        view.viewport.setFontSize(editorFontSize)
        view.setInfoPaneWidth(infoPaneWidth)
        view.onInfoPaneWidthChange = { [weak self] width in
            self?.setInfoPaneWidth(width)
        }
        view.setFileFormat(document.format)
        document.watcher = FileWatcher(path: url.path) { [weak self, weak document] in
            if let self, let document {
                self.fileDidChangeOnDisk(document)
            }
        }
        index.build(from: file) { [weak self, weak document] in
            if let self, let document {
                self.documentDidUpdate(document)
            }
        }
        return document
    }

    /// Marks a document as changed on disk and surfaces it (sidebar + title).
    private func fileDidChangeOnDisk(_ document: Document) {
        guard let index = documents.firstIndex(where: { $0 === document }) else {
            return
        }
        if document.isFollowing && document.view.canFollow {
            absorbGrowth(of: document)
        } else {
            document.hasDiskChanges = true
            sidebar.reloadRow(index)
            if index == activeIndex {
                updateTitle()
            }
        }
    }

    // MARK: - Following a growing file

    /// Toggles `tail -f` behaviour for the active document: appends on disk
    /// are indexed incrementally and shown as they arrive, and the view stays
    /// pinned to the end if it was there.
    @objc private func toggleFollowing() {
        if let document = activeDocument {
            document.isFollowing.toggle()
            document.view.isFollowing = document.isFollowing
            if document.isFollowing && document.hasDiskChanges {
                absorbGrowth(of: document)       // catch up on what we missed
            }
        }
    }

    /// Absorbs an append to `document`'s file. Anything that is not a plain
    /// append — a smaller file, a new inode, or old bytes that changed — is a
    /// replacement, and gets the full reload instead.
    private func absorbGrowth(of document: Document) {
        let path = document.url.path
        switch FileGrowth.detect(path: path, previous: document.file) {
        case .unchanged:
            break
        case .replaced:
            reload(document, from: document.url, preserveScroll: true)
        case .appended:
            let previous = document.file
            if let grown = MappedFile(path: path), FileGrowth.isAppend(previous: previous, grown: grown) {
                document.index.extend(with: grown, previousSize: previous.size) { [weak self, weak document] apply in
                    // Skipped if the document was reloaded or closed meanwhile:
                    // the extension belongs to a mapping nobody shows any more.
                    if let self, let document, document.file === previous {
                        let wasAtEnd = document.view.viewport.isScrolledToEnd
                        apply()
                        document.adoptGrownFile(grown)
                        document.hasDiskChanges = false
                        document.view.adoptGrownFile(grown, index: document.index, pinToEnd: wasAtEnd)
                        self.documentDidUpdate(document)
                    }
                }
            } else {
                reload(document, from: document.url, preserveScroll: true)
            }
        }
    }

    /// Mounts the document at `index` and refreshes window chrome from it.
    private func selectDocument(at index: Int) {
        guard documents.indices.contains(index) else {
            return
        }
        activeIndex = index
        let document = documents[index]
        contentContainer.setActiveView(document.view)
        window?.makeFirstResponder(document.view.viewport)
        window?.isDocumentEdited = document.isEdited
        sidebar.applySelection(index)
        updateTitle()
        persistSession()
    }

    @objc private func closeActiveDocument() {
        if let activeIndex {
            closeDocument(at: activeIndex)
        }
    }

    /// Prompts about unsaved changes if needed, then tears down the document.
    private func closeDocument(at index: Int) {
        guard documents.indices.contains(index) else {
            return
        }
        let document = documents[index]
        if document.isEdited {
            presentClosePrompt(for: document) { [weak self] shouldClose in
                if shouldClose, let self,
                   let position = self.documents.firstIndex(where: { $0 === document }) {
                    self.tearDownDocument(at: position)
                }
            }
        } else {
            tearDownDocument(at: index)
        }
    }

    /// The standard Save / Don't Save / Cancel sheet for a dirty document.
    private func presentClosePrompt(for document: Document,
                                    completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(document.fileName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                if document.hasDiskChanges {
                    self?.presentDiskChangeConflict(for: document)
                    completion(false)
                } else {
                    self?.performSave(of: document, to: document.url) { saved in
                        completion(saved)
                    }
                }
            case .alertSecondButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    /// Removes the document at `index`, then selects a neighbour (or shows
    /// the empty state when the last one closes).
    private func tearDownDocument(at index: Int) {
        guard documents.indices.contains(index) else {
            return
        }
        let document = documents[index]
        document.watcher?.cancel()
        document.view.close()
        document.index.cancel()
        documents.remove(at: index)

        if documents.isEmpty {
            activeIndex = nil
            contentContainer.setActiveView(nil)
            window.isDocumentEdited = false
            sidebar.reload(documents: documents, selectedIndex: nil)
            updateTitle()
            persistSession()
        } else {
            let next = min(index, documents.count - 1)
            sidebar.reload(documents: documents, selectedIndex: next)
            selectDocument(at: next)
        }
    }

    /// Called as a document's index reports progress / completes. Refreshes its
    /// view and sidebar row, and the window title when it's the active document.
    private func documentDidUpdate(_ document: Document) {
        guard let index = documents.firstIndex(where: { $0 === document }) else {
            return
        }
        // Re-apply a restored scroll position as the row count grows; clear it
        // once indexing is done and the target is final.
        if let pending = document.pendingScrollRow {
            document.view.viewport.setScrollRow(pending)
            if document.index.isComplete {
                document.pendingScrollRow = nil
            }
        }
        document.view.refresh()
        sidebar.reloadRow(index)
        if index == activeIndex {
            updateTitle()
        }
    }

    private func updateTitle() {
        // Just the file name, drawn by the centered title label. Size, line
        // count, encoding, and disk-change state live in the info pane / status
        // bar / sidebar instead.
        let name = activeDocument?.fileName ?? "BigEdit"
        window?.title = name          // keeps the Window menu / app switcher correct
        titleLabel.stringValue = name
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

    // MARK: - Split view sizing

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, AppDelegate.minSidebarWidth)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - AppDelegate.minContentWidth)
    }

    // MARK: - Saving

    @objc private func save() {
        if let document = activeDocument, document.isEdited {
            if document.hasDiskChanges {
                presentDiskChangeConflict(for: document)
            } else {
                performSave(of: document, to: document.url)
            }
        }
    }

    @objc private func saveAs() {
        if let document = activeDocument, document.isEdited {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = document.fileName
            panel.directoryURL = document.url.deletingLastPathComponent()
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.performSave(of: document, to: url)
                }
            }
        }
    }

    /// The file changed on disk while it has unsaved edits: the mmap gives no
    /// guarantee the edits are based on what is there now, so saving over it
    /// is unsafe. Offer Save As or discarding the edits.
    private func presentDiskChangeConflict(for document: Document) {
        let alert = NSAlert()
        alert.messageText = "\(document.fileName) changed on disk"
        alert.informativeText = "The file was modified by another program while you had "
            + "unsaved changes. Save to a different file, or reload the file and lose "
            + "your changes."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Reload and Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.saveAs()
            case .alertSecondButtonReturn:
                self?.reload(document, from: document.url, preserveScroll: true)
            default:
                break
            }
        }
    }

    /// Runs the streaming write under a progress sheet, picking the piece
    /// save for positional edits or the rule save for a deferred rule. On
    /// success re-loads the document so it reflects what is now on disk.
    private func performSave(of document: Document, to destination: URL,
                             completion: ((Bool) -> Void)? = nil) {
        let sheet = SaveProgressSheet(fileName: destination.lastPathComponent)
        let cancelToken = CancelToken()
        sheet.onCancel = { cancelToken.cancel() }
        saveProgressSheet = sheet
        window.beginSheet(sheet.window) { _ in }

        let finish: (Result<Void, FileWriter.WriteError>) -> Void = { [weak self] result in
            self?.window.endSheet(sheet.window)
            self?.saveProgressSheet = nil
            self?.handleSaveResult(result, document: document, destination: destination,
                                   completion: completion)
        }

        if let rule = document.view.currentRule {
            FileWriter.save(
                file: document.file,
                rule: rule,
                to: destination,
                cancelToken: cancelToken,
                onProgress: { sheet.setProgress($0) },
                completion: finish
            )
        } else if let editedDocument = document.view.editedDocument {
            FileWriter.save(
                document: editedDocument,
                to: destination,
                cancelToken: cancelToken,
                onProgress: { sheet.setProgress($0) },
                completion: finish
            )
        } else {
            window.endSheet(sheet.window)
            saveProgressSheet = nil
            completion?(false)
        }
    }

    private func handleSaveResult(
        _ result: Result<Void, FileWriter.WriteError>,
        document: Document,
        destination: URL,
        completion: ((Bool) -> Void)? = nil
    ) {
        switch result {
        case .success:
            reloadDocument(document, from: destination)
            completion?(true)
        case .failure(let error):
            if case .cancelled = error {
                completion?(false)
                return  // Silent on cancel; original file untouched.
            }
            presentSaveError(error.localizedDescription)
            completion?(false)
        }
    }

    /// Re-points a document at the freshly written file and restarts indexing.
    private func reloadDocument(_ document: Document, from destination: URL) {
        reload(document, from: destination, preserveScroll: false)
        addRecentDocument(destination)
    }

    /// Reloads the active document from its file on disk (the ⌘R command),
    /// keeping the scroll position so log tailing isn't jarring.
    @objc private func revealInFinder() {
        if let url = activeDocument?.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func reloadActiveFromDisk() {
        if let document = activeDocument {
            if document.isEdited {
                let alert = NSAlert()
                alert.messageText = "Reload \(document.fileName)?"
                alert.informativeText = "Reloading from disk will discard your unsaved changes."
                alert.addButton(withTitle: "Reload")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertFirstButtonReturn {
                        self?.reload(document, from: document.url, preserveScroll: true)
                    }
                }
            } else {
                reload(document, from: document.url, preserveScroll: true)
            }
        }
    }

    /// Swaps a document's contents for a fresh map of `url` and restarts
    /// indexing, optionally keeping the current scroll position.
    private func reload(_ document: Document, from url: URL, preserveScroll: Bool) {
        guard let file = MappedFile(path: url.path) else {
            presentSaveError("Could not reopen \(url.lastPathComponent).")
            return
        }
        let previousRow = document.view.viewport.scrollRow
        let index = LineIndex()
        document.watcher?.cancel()
        document.view.close()
        document.reload(url: url, file: file, index: index)
        document.hasDiskChanges = false
        document.view.load(file: file, index: index)
        document.view.viewport.setFontSize(editorFontSize)
        document.view.setInfoPaneWidth(infoPaneWidth)
        document.view.setFileFormat(document.format)
        if preserveScroll {
            document.view.viewport.setScrollRow(previousRow)
        }
        document.watcher = FileWatcher(path: url.path) { [weak self, weak document] in
            if let self, let document {
                self.fileDidChangeOnDisk(document)
            }
        }
        index.build(from: file) { [weak self, weak document] in
            if let self, let document {
                self.documentDidUpdate(document)
            }
        }
        persistSession()

        if let position = documents.firstIndex(where: { $0 === document }) {
            sidebar.reloadRow(position)
            if position == activeIndex {
                selectDocument(at: position)
            }
        }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        var enabled = true
        switch menuItem.action {
        case #selector(newDocument):
            enabled = true
        case #selector(toggleFollowing):
            menuItem.state = (activeDocument?.isFollowing ?? false) ? .on : .off
            enabled = activeDocument != nil && activeView?.canFollow == true
        case #selector(showProcessLines):
            enabled = activeView?.canProcessLines == true
        case #selector(save), #selector(saveAs):
            enabled = activeDocument?.isEdited == true
        case #selector(closeActiveDocument), #selector(reloadActiveFromDisk),
             #selector(revealInFinder):
            enabled = activeDocument != nil
        case #selector(toggleInfoPane):
            menuItem.state = (activeView?.isInfoPaneVisible ?? false) ? .on : .off
            enabled = activeDocument != nil
        case #selector(toggleSearchResults):
            enabled = activeDocument != nil
        case #selector(performGoToLine), #selector(performFind),
             #selector(performFindReplace), #selector(findNext), #selector(findPrevious),
             #selector(zoomIn), #selector(zoomOut), #selector(actualSize):
            enabled = activeDocument != nil
        default:
            break
        }
        return enabled
    }
}
