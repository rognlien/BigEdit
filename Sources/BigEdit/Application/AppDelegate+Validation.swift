import AppKit

/// Which menu items are enabled for the active document.
extension AppDelegate {

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
        case #selector(formatPrettyPrint), #selector(formatCompact):
            enabled = activeView?.canFormat == true
        case #selector(showCompareDocuments):
            enabled = canCompareDocuments
        case #selector(save), #selector(saveAs):
            enabled = activeDocument.map { $0.isEdited || $0.isUntitled } ?? false
        case #selector(convertToUTF8):
            enabled = activeView?.canConvertToUTF8 == true
        case #selector(closeActiveDocument), #selector(reloadActiveFromDisk):
            enabled = activeDocument != nil
        case #selector(revealInFinder):
            enabled = activeDocument.map { !$0.isUntitled } ?? false
        case #selector(toggleInfoPane):
            menuItem.state = (activeView?.isInfoPaneVisible ?? false) ? .on : .off
            enabled = activeDocument != nil
        case #selector(toggleInvisibles):
            menuItem.state = settings.showsInvisibles ? .on : .off
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
