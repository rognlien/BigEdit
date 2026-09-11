import AppKit
import Sparkle

/// The main menu, the Open Recent submenu, and the actions that only
/// forward to the active document.
extension AppDelegate {

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

    // MARK: - Building the menu bar

    func buildMenu() {
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

    @objc func performFind() {
        activeView?.showFindBar(replace: false)
    }

    /// Lists every match of the current search below the viewport.
    @objc func toggleSearchResults() {
        activeView?.toggleSearchResults()
    }

    @objc func performFindReplace() {
        activeView?.showFindBar(replace: true)
    }

    @objc func toggleInfoPane() {
        activeView?.toggleInfoPane()
    }

    @objc func zoomIn() {
        setEditorFontSize(editorFontSize + 1)
    }

    @objc func zoomOut() {
        setEditorFontSize(editorFontSize - 1)
    }

    @objc func actualSize() {
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
    func setInfoPaneWidth(_ width: CGFloat) {
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

    @objc func performGoToLine() {
        activeView?.showGoToLineSheet()
    }

    @objc func findNext() {
        activeView?.findNext()
    }

    @objc func findPrevious() {
        activeView?.findPrevious()
    }
}
