import AppKit
import WebKit

/// Shows a Markdown document rendered as HTML.
///
/// The page is static: its own scripts are switched off, and the renderer's
/// content security policy limits it to styles and pictures. A clicked link
/// opens in the default app rather than taking the view away from the
/// document; links to a place on the page itself, such as footnotes, still
/// scroll there.
///
/// The scripts below are the app's own, used to keep the reader's place when
/// switching between the text and the rendered page. They match the line
/// numbers in each block's `data-sourcepos` attribute.
final class MarkdownPreview: NSView, WKNavigationDelegate {

    let webView: WKWebView

    /// The source line to scroll to once the page being loaded has finished.
    private var pendingSourceLine: Int?

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(origin: .zero, size: frameRect.size),
                            configuration: configuration)
        super.init(frame: frameRect)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("MarkdownPreview is created programmatically")
    }

    /// Scales the page, following the editor's zoom.
    var zoom: CGFloat {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    /// Loads `page`, resolving relative image paths against `baseURL`, and
    /// scrolls to the block that holds 1-based `sourceLine` once it is shown.
    func show(page: String, baseURL: URL?, sourceLine: Int) {
        pendingSourceLine = sourceLine
        webView.loadHTMLString(page, baseURL: baseURL)
    }

    /// Empties the view, so a large page does not stay in memory while hidden.
    func clear() {
        pendingSourceLine = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// The 1-based source line of the block at the top of the view, or nil
    /// while the reader has not scrolled since the page was shown.
    func topSourceLine(completion: @escaping (Int?) -> Void) {
        webView.evaluateJavaScript(MarkdownPreview.topSourceLineScript) { result, _ in
            completion((result as? NSNumber)?.intValue)
        }
    }

    private func scroll(toSourceLine line: Int) {
        webView.evaluateJavaScript("(\(MarkdownPreview.scrollScript))(\(line))")
    }

    /// Scrolls to the last block that starts at or before the line, and notes
    /// where that left the page so an unscrolled page can be recognised.
    private static let scrollScript = """
        function (line) {
            let target = null;
            for (const block of document.querySelectorAll('[data-sourcepos]')) {
                if (parseInt(block.dataset.sourcepos) > line) { break; }
                target = block;
            }
            if (target) { target.scrollIntoView(); } else { window.scrollTo(0, 0); }
            document.documentElement.dataset.shownAt = window.scrollY;
        }
        """

    /// The start line of the last block whose top is at or above the top of
    /// the view, or null when the page is where it was shown.
    private static let topSourceLineScript = """
        (function () {
            if (String(window.scrollY) === document.documentElement.dataset.shownAt) { return null; }
            let line = 1;
            for (const block of document.querySelectorAll('[data-sourcepos]')) {
                if (block.getBoundingClientRect().top > 1) { break; }
                line = parseInt(block.dataset.sourcepos);
            }
            return line;
        })()
        """

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let line = pendingSourceLine {
            scroll(toSourceLine: line)
        }
        pendingSourceLine = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        var policy = WKNavigationActionPolicy.allow
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, !isOnThisPage(url) {
            policy = .cancel
            NSWorkspace.shared.open(url)
        }
        decisionHandler(policy)
    }

    private func isOnThisPage(_ url: URL) -> Bool {
        let pageAddress = webView.url?.absoluteString.split(separator: "#").first
        return url.fragment != nil && url.absoluteString.split(separator: "#").first == pageAddress
    }
}
