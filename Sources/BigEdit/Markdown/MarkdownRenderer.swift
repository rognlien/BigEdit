import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Turns Markdown into an HTML page with cmark-gfm, the parser GitHub uses, so
/// tables, task lists, strikethrough and autolinks come out as they do there.
///
/// Raw HTML in the source is left out of the output, which is cmark's default.
/// Every block carries a `data-sourcepos` attribute naming the lines it came
/// from; that is how the rendered view keeps the reader's place in the text.
enum MarkdownRenderer {

    private static let extensionNames = ["table", "strikethrough", "autolink", "tasklist"]

    private static let options = CMARK_OPT_SOURCEPOS | CMARK_OPT_FOOTNOTES

    private static let extensionsRegistered: Void = {
        cmark_gfm_core_extensions_ensure_registered()
    }()

    /// A complete page — styles, security policy and body — for `markdown`,
    /// which must be UTF-8.
    static func page(from markdown: [UInt8]) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>\(MarkdownStyleSheet.css)</style>
        </head>
        <body>
        \(html(from: markdown))
        </body>
        </html>
        """
    }

    /// The page may style itself and show pictures, local or remote, and
    /// nothing else: no scripts, frames, fonts or other fetches.
    private static let contentSecurityPolicy =
        "default-src 'none'; img-src file: data: https:; style-src 'unsafe-inline'"

    /// The HTML body for `markdown`, which must be UTF-8.
    static func html(from markdown: [UInt8]) -> String {
        _ = extensionsRegistered
        let parser = cmark_parser_new(options)
        defer { cmark_parser_free(parser) }
        for name in extensionNames {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }
        markdown.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: CChar.self) { characters in
                cmark_parser_feed(parser, characters.baseAddress, characters.count)
            }
        }
        let document = cmark_parser_finish(parser)
        defer { cmark_node_free(document) }
        let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser))
        defer { free(rendered) }
        return rendered.map { String(cString: $0) } ?? ""
    }
}
