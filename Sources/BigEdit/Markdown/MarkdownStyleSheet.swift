/// The look of rendered Markdown: the system font for prose, the system
/// monospaced font for code, and colours that follow light and dark mode.
enum MarkdownStyleSheet {

    static let css = """
        :root {
            color-scheme: light dark;
            --text: #1f2328;
            --secondary: #59636e;
            --border: #d1d9e0;
            --code-background: rgba(129, 139, 152, 0.12);
            --link: #0969da;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --text: #e6edf3;
                --secondary: #9198a1;
                --border: #3d444d;
                --code-background: rgba(101, 108, 118, 0.2);
                --link: #4493f8;
            }
        }
        html { background: Canvas; }
        body {
            font: 15px/1.6 -apple-system, system-ui, sans-serif;
            color: var(--text);
            max-width: 52em;
            margin: 0 auto;
            padding: 24px 32px 48px;
            overflow-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 { margin: 1.5em 0 0.6em; line-height: 1.25; font-weight: 600; }
        h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
        h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--border); }
        h3 { font-size: 1.25em; }
        h4 { font-size: 1em; }
        h5 { font-size: 0.875em; }
        h6 { font-size: 0.85em; color: var(--secondary); }
        body > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        ul, ol { padding-left: 2em; }
        li + li { margin-top: 0.25em; }
        li > input[type="checkbox"] { margin: 0 0.4em 0 -1.4em; vertical-align: middle; }
        ul:has(> li > input[type="checkbox"]) { list-style: none; }
        blockquote { margin-left: 0; padding: 0 1em; color: var(--secondary); border-left: 0.25em solid var(--border); }
        code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.875em; }
        code { padding: 0.2em 0.4em; border-radius: 6px; background: var(--code-background); }
        pre { padding: 1em; overflow: auto; line-height: 1.45; border-radius: 6px; background: var(--code-background); }
        pre code { padding: 0; font-size: 1em; background: none; }
        table { border-collapse: collapse; display: block; overflow: auto; }
        th, td { padding: 6px 13px; border: 1px solid var(--border); }
        th { font-weight: 600; }
        tr:nth-child(2n) td { background: var(--code-background); }
        hr { height: 0.25em; margin: 1.5em 0; border: 0; background: var(--border); }
        img { max-width: 100%; }
        .footnotes { font-size: 0.875em; color: var(--secondary); border-top: 1px solid var(--border); }
        """
}
