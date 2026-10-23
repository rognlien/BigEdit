import AppKit

extension DocumentView {

    /// Applies the editor font, invisibles and Markdown preferences from
    /// Settings.
    func apply(_ settings: AppSettings) {
        viewport.setEditorFont(family: settings.fontFamily, size: settings.fontSize)
        viewport.showsInvisibles = settings.showsInvisibles
        updateMarkdownZoom()
        if loadsRemoteImages != settings.loadsRemoteImages {
            loadsRemoteImages = settings.loadsRemoteImages
            rerenderMarkdown()
        }
    }
}
