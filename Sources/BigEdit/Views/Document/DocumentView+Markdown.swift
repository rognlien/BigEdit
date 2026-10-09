import AppKit

/// The rendered Markdown mode: the text is parsed as a whole and shown as a
/// page in place of the viewport. Editing always happens in the text.
extension DocumentView {

    /// Rendering reads the whole document into memory, unlike everything else
    /// the viewport does, so it is offered only for files up to this size.
    static let markdownRenderingLimit = 16 * 1024 * 1024

    var isMarkdownRenderingActive: Bool {
        markdownPreview?.isHidden == false
    }

    /// Why `file` cannot be rendered as Markdown, or nil when it can.
    static func markdownUnavailableReason(for file: MappedFile) -> String? {
        var reason: String?
        if syntaxMode(for: file) != .markdown {
            reason = "This file is not Markdown"
        } else if file.size > markdownRenderingLimit {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(markdownRenderingLimit),
                                                  countStyle: .file)
            reason = "Markdown files larger than \(limit) are shown as text only"
        }
        return reason
    }

    func applyMarkdownRendering(enabled: Bool) {
        if enabled && !isMarkdownRenderingActive {
            showRenderedMarkdown()
        } else if !enabled && isMarkdownRenderingActive {
            hideRenderedMarkdown(keepingPlace: true)
        }
    }

    /// Returns to the text, keeping the reader's place, before a command that
    /// works on the text: find, go to line, process lines.
    func leaveRenderedMarkdown() {
        if isMarkdownRenderingActive {
            formatBar.setMode(.text)
            hideRenderedMarkdown(keepingPlace: true)
        }
    }

    /// Follows the editor's zoom, so both modes grow and shrink together.
    func setEditorFontSize(_ size: CGFloat) {
        viewport.setFontSize(size)
        markdownPreview?.zoom = viewport.editorFontSize / ViewportView.defaultFontSize
    }

    /// Renders the document as it stands, edits included, off the main
    /// thread, and opens the page at the line at the top of the viewport.
    private func showRenderedMarkdown() {
        guard let document = viewport.document else {
            return
        }
        if findBarVisible {
            hideFindBar()
        }
        setResultsVisible(false)
        markdownRenderGeneration += 1
        let generation = markdownRenderGeneration
        let sourceLine = topDocumentLine() + 1
        let bytes = document.bytes(in: 0..<document.length)
        let encoding = textEncoding
        let baseURL = URL(fileURLWithPath: document.file.path).deletingLastPathComponent()
        let preview = markdownPreview ?? makeMarkdownPreview()
        preview.zoom = viewport.editorFontSize / ViewportView.defaultFontSize
        setMarkdownPreviewVisible(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let utf8 = encoding == .utf8 ? bytes : Array(encoding.decode(bytes).utf8)
            let page = MarkdownRenderer.page(from: utf8)
            DispatchQueue.main.async {
                guard let self, generation == self.markdownRenderGeneration else {
                    return
                }
                preview.show(page: page, baseURL: baseURL, sourceLine: sourceLine)
            }
        }
    }

    /// Shows the text again. With `keepingPlace`, the viewport scrolls to the
    /// block at the top of the page, if the reader scrolled the page.
    func hideRenderedMarkdown(keepingPlace: Bool) {
        markdownRenderGeneration += 1
        let generation = markdownRenderGeneration
        if let preview = markdownPreview, isMarkdownRenderingActive {
            preview.topSourceLine { [weak self] line in
                guard let self, generation == self.markdownRenderGeneration else {
                    return
                }
                if keepingPlace, let line {
                    self.scrollToDocumentLine(line - 1)
                }
                preview.clear()
            }
            setMarkdownPreviewVisible(false)
        }
    }

    private func makeMarkdownPreview() -> MarkdownPreview {
        let preview = MarkdownPreview(frame: .zero)
        preview.isHidden = true
        addSubview(preview, positioned: .below, relativeTo: formatBar)
        markdownPreview = preview
        layoutComponents()
        return preview
    }

    private func setMarkdownPreviewVisible(_ visible: Bool) {
        markdownPreview?.isHidden = !visible
        viewport.isHidden = visible
        scroller.isHidden = visible
        let responder: NSResponder? = visible ? markdownPreview?.webView : viewport
        window?.makeFirstResponder(responder)
    }

    /// The 0-based document line of the row at the top of the viewport.
    private func topDocumentLine() -> Int {
        let row = Int(viewport.scrollRow)
        return viewport.layout?.visualLines(forRows: row..<(row + 1)).first?.documentLine ?? 0
    }

    private func scrollToDocumentLine(_ line: Int) {
        if let layout = viewport.layout {
            viewport.setScrollRow(Double(layout.visualRow(forDocumentLine: line)))
        }
    }
}
