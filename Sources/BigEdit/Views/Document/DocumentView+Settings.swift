import AppKit

extension DocumentView {

    /// Applies the editor font and Markdown preferences from Settings.
    func apply(_ settings: AppSettings) {
        viewport.setEditorFont(family: settings.fontFamily, size: settings.fontSize)
        updateMarkdownZoom()
        if loadsRemoteImages != settings.loadsRemoteImages {
            loadsRemoteImages = settings.loadsRemoteImages
            rerenderMarkdown()
        }
    }
}
