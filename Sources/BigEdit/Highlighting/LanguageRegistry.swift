import Foundation

/// Every language the viewport can colour, and how a file is matched to one:
/// first by its name, then by sniffing the head of its contents.
enum LanguageRegistry {

    static let xml = Language(
        XMLHighlighter.self,
        identifier: "xml",
        displayName: "XML",
        fileExtensions: [
            "xml", "svg", "xhtml", "html", "htm", "plist",
            "rss", "atom", "xsd", "xsl", "xslt", "pom"
        ],
        sniff: { firstNonWhitespaceByte($0) == UInt8(ascii: "<") })

    static let json = Language(
        JSONHighlighter.self,
        identifier: "json",
        displayName: "JSON",
        fileExtensions: ["json", "jsonl", "ndjson", "geojson", "har", "jsonc"],
        sniff: { [UInt8(ascii: "{"), UInt8(ascii: "[")].contains(firstNonWhitespaceByte($0)) })

    static let markdown = Language(
        MarkdownHighlighter.self,
        identifier: "markdown",
        displayName: "Markdown",
        fileExtensions: ["md", "markdown", "mdown", "mkd", "mdx"])

    static let yaml = Language(
        YAMLHighlighter.self,
        identifier: "yaml",
        displayName: "YAML",
        fileExtensions: ["yaml", "yml"])

    static let shell = Language(
        ShellHighlighter.self,
        identifier: "shell",
        displayName: "Shell Script",
        fileExtensions: ShellScript.extensions,
        fileNames: ShellScript.fileNames,
        sniff: ShellScript.startsWithShellInterpreter)

    static let sql = Language(
        SQLHighlighter.self,
        identifier: "sql",
        displayName: "SQL",
        fileExtensions: ["sql", "ddl", "pgsql", "mysql"])

    /// In the order a file's head is sniffed: the `#!` line before the
    /// leading-byte guesses.
    static let all: [Language] = [shell, xml, json, markdown, yaml, sql]

    private static let sniffLimit = 256

    static func language(identifier: String) -> Language? {
        return all.first { $0.identifier == identifier }
    }

    /// The language a file is written in, by name and then by content;
    /// `.plain` when nothing matches.
    static func language(for file: MappedFile) -> Language {
        let fileName = (file.path as NSString).lastPathComponent
        return all.first { $0.matches(fileName: fileName) }
            ?? all.first { $0.matches(head: file.buffer) }
            ?? .plain
    }

    /// The first byte of the head that is not whitespace or a UTF-8 BOM.
    private static func firstNonWhitespaceByte(_ buffer: UnsafeRawBufferPointer) -> UInt8? {
        let skippable: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF]
        let head = buffer.prefix(sniffLimit)
        return head.first { !skippable.contains($0) }
    }
}
