import AppKit
import Sparkle

/// Owns the window, the menu, and the set of open documents. Several documents
/// can be open at once; a left-side sidebar switches between them, and the
/// active document is mounted in the content area on the right.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
                         NSMenuDelegate, NSSplitViewDelegate, SPUUpdaterDelegate {

    var window: NSWindow!

    /// Drives Sparkle auto-updates (Check for Updates… + scheduled checks).
    /// Lazy so `self` can be the updater delegate (to flush state before a
    /// relaunch). Started on first access (menu build / launch check).
    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    let splitView = SidebarSplitView()
    let sidebar = DocumentListView(frame: NSRect(x: 0, y: 0, width: AppDelegate.defaultSidebarWidth, height: 640))
    let contentContainer = ContentContainerView(frame: NSRect(x: 0, y: 0, width: 680, height: 640))
    let titleLabel = NSTextField(labelWithString: "")

    var documents: [Document] = []
    var activeIndex: Int?
    var saveProgressSheet: SaveProgressSheet?

    /// Held while the Process Lines sheet is up, so it is not deallocated
    /// before the user answers it.
    var processLinesSheet: ProcessLinesSheet?

    /// Held while the Compare Documents sheet is up, for the same reason.
    var compareSheet: CompareDocumentsSheet?

    /// Every open compare result, released when its window closes.
    var compareWindows: [CompareResultsWindow] = []

    /// The Saved Patterns editor, made on first use and kept.
    var patternLibraryWindow: PatternLibraryWindow?

    /// The Saved Patterns submenu of the Find menu, filled when opened.
    let savedPatternsMenu = NSMenu(title: "Saved Patterns")
    let syntaxColoringMenu = NSMenu(title: "Syntax Coloring")

    /// Where new documents are created before they are first saved.
    var untitledDocuments = UntitledDocuments.shared

    let openRecentMenu = NSMenu(title: "Open Recent")
    var didOpenFromURL = false
    static let lastFilePathDefaultsKey = "BigEditLastFilePath"
    static let openDocumentsDefaultsKey = "BigEditOpenDocuments"
    static let scrollRowsDefaultsKey = "BigEditScrollRows"
    static let activeIndexDefaultsKey = "BigEditActiveIndex"
    static let recentDocumentsDefaultsKey = "BigEditRecentDocuments"
    static let maxRecentDocuments = 15

    /// The preferences from the Settings window, applied to every document.
    let settings = AppSettings()
    var settingsWindowController: SettingsWindowController?

    static let infoPaneWidthDefaultsKey = "BigEditInfoPaneWidth"

    /// The info-pane width shared by all open documents, persisted across launches.
    lazy var infoPaneWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: AppDelegate.infoPaneWidthDefaultsKey)
        return stored > 0 ? CGFloat(stored) : InfoPane.preferredWidth
    }()

    let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// The sidebar width the user last dragged to, persisted across launches.
    lazy var sidebarWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: AppDelegate.sidebarWidthDefaultsKey)
        return stored > 0 ? CGFloat(stored) : AppDelegate.defaultSidebarWidth
    }()

    static let minSidebarWidth: CGFloat = 190
    static let minContentWidth: CGFloat = 360

    // MARK: - Active document accessors

    var activeDocument: Document? {
        guard let activeIndex, documents.indices.contains(activeIndex) else {
            return nil
        }
        return documents[activeIndex]
    }

    var activeView: DocumentView? {
        activeDocument?.view
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Build the menu and window here, not in didFinishLaunching: a launch
        // that opens a document (e.g. dropping a file on the Dock icon) delivers
        // application(_:open:) before didFinishLaunching, and that path touches
        // the window — which must already exist.
        NSApp.appearance = settings.appearance.appearance
        settings.onChange = { [weak self] in
            self?.applySettings()
        }
        PatternLibrary.shared.adoptRememberedLocation()
        buildMenu()
        buildWindow()
        // Another Mac may have written the library through iCloud Drive
        // while this one was in the background.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationDidBecomeActiveForPatterns),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If the launch didn't come with a file (via `application(_:open:)`),
        // restore the previous session. Scheduled on the next run loop tick so
        // any pending open-URL event has a chance to fire first.
        DispatchQueue.main.async { [weak self] in
            self?.restoreSessionIfNeeded()
            self?.reopenUntitledDocumentsLeftOut()
            self?.removeUnusedPlaceholders()
            self?.removeStaleJournals()
        }

        // Check for updates on every launch (silent — only surfaces UI if an
        // update is available), in addition to Sparkle's scheduled checks,
        // unless automatic checks are turned off in Settings.
        if updaterController.updater.automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    /// Runs after the session is restored, so the placeholders of the
    /// untitled documents it reopened are kept; the journals of the rest are
    /// then removed with the stale ones, their files being gone.
    private func removeUnusedPlaceholders() {
        untitledDocuments.removeUnusedPlaceholders(keeping: documents.map(\.url))
    }

    /// Runs after the session is restored, so the journals of the documents
    /// it reopened are in use and kept.
    private func removeStaleJournals() {
        DispatchQueue.global(qos: .utility).async {
            EditJournal.removeStaleJournals()
        }
    }

    @objc private func applicationDidBecomeActiveForPatterns() {
        PatternLibrary.shared.reloadIfChangedOnDisk()
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

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.onDividerDragged = { [weak self] in
            self?.rememberSidebarWidth()
        }
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(contentContainer)
        splitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 0)

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
        installToolbar()
        restoreWindowFrame()
        window.makeKeyAndOrderFront(nil)
        restoreSidebarWidth()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive after the window is closed; a Dock click brings it back.
        // The user quits with ⌘Q.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var reply = NSApplication.TerminateReply.terminateNow
        let unsaved = documents.filter { $0.isEdited && !$0.survivesQuit }
        let dirtyNames = unsaved.map(\.fileName)
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
            } else {
                // Quit Anyway is an explicit choice to lose them.
                unsaved.forEach { $0.view.discardJournal() }
            }
        }
        if reply == .terminateNow {
            // Clean documents leave nothing worth keeping on disk.
            documents.filter { !$0.isEdited }.forEach { $0.view.discardJournal() }
        }
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Capture final scroll positions for next launch.
        persistSession()
        documents.forEach { $0.view.flushJournal() }
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
}
