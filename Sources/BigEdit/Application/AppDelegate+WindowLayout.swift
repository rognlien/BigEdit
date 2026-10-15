import AppKit

/// Keeps the main window's frame and the sidebar's width across launches.
extension AppDelegate {

    static let mainWindowAutosaveName = "BigEditMainWindow"
    static let sidebarWidthDefaultsKey = "BigEditSidebarWidth"
    static let defaultSidebarWidth: CGFloat = 220

    /// Puts the window where it was last time, or centres it on first launch.
    /// Called once the toolbar is installed, so the saved frame is not
    /// changed afterwards by the toolbar's height.
    func restoreWindowFrame() {
        if !window.setFrameUsingName(AppDelegate.mainWindowAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(AppDelegate.mainWindowAutosaveName)
    }

    func restoreSidebarWidth() {
        splitView.setSidebarWidth(fittingSidebarWidth)
    }

    /// The remembered width, narrowed to leave the content its minimum width.
    private var fittingSidebarWidth: CGFloat {
        let widest = splitView.bounds.width - splitView.dividerThickness - AppDelegate.minContentWidth
        return max(AppDelegate.minSidebarWidth, min(sidebarWidth, widest))
    }

    func persistSidebarWidth() {
        UserDefaults.standard.set(Double(sidebarWidth), forKey: AppDelegate.sidebarWidthDefaultsKey)
    }

    func rememberSidebarWidth() {
        sidebarWidth = sidebar.frame.width
    }

    /// Only a drag of the divider changes the remembered width. Any other
    /// resize that moved it — such as the window's first layout pass, which
    /// briefly collapses the split view — is undone.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        let movedByLayout = !splitView.isDraggingDivider && splitView.frame.width > 0
        if movedByLayout && abs(sidebar.frame.width - fittingSidebarWidth) >= 1 {
            restoreSidebarWidth()
        }
    }
}
