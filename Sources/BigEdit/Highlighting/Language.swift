import Foundation

/// A language the viewport can colour: its highlighter behind an opaque state,
/// and how a file is recognised as written in it.
struct Language {

    let identifier: String
    let displayName: String
    let fileExtensions: Set<String>
    let fileNames: Set<String>
    private let sniffer: (UnsafeRawBufferPointer) -> Bool
    private let tokenizer: (String, HighlightState) -> ([Token], HighlightState)
    private let endStateFinder: (String, HighlightState) -> HighlightState

    static let plain = Language(
        identifier: "plain",
        displayName: "Plain Text",
        fileExtensions: [],
        fileNames: [],
        sniffer: { _ in false },
        tokenizer: { _, _ in ([], .normal) },
        endStateFinder: { _, _ in .normal })

    private init(
        identifier: String,
        displayName: String,
        fileExtensions: Set<String>,
        fileNames: Set<String>,
        sniffer: @escaping (UnsafeRawBufferPointer) -> Bool,
        tokenizer: @escaping (String, HighlightState) -> ([Token], HighlightState),
        endStateFinder: @escaping (String, HighlightState) -> HighlightState
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.fileExtensions = fileExtensions
        self.fileNames = fileNames
        self.sniffer = sniffer
        self.tokenizer = tokenizer
        self.endStateFinder = endStateFinder
    }

    /// A language coloured by `highlighter`. `sniff` looks at the head of a
    /// file whose name did not match, and says whether it is in this language.
    init<H: Highlighter>(
        _ highlighter: H.Type,
        identifier: String,
        displayName: String,
        fileExtensions: Set<String>,
        fileNames: Set<String> = [],
        sniff: @escaping (UnsafeRawBufferPointer) -> Bool = { _ in false }
    ) {
        self.init(
            identifier: identifier,
            displayName: displayName,
            fileExtensions: fileExtensions,
            fileNames: fileNames,
            sniffer: sniff,
            tokenizer: { text, start in
                let (tokens, end) = H.tokens(text, startState: start.state(for: H.self))
                return (tokens, HighlightState(end, of: H.self))
            },
            endStateFinder: { text, start in
                HighlightState(H.endState(text, start: start.state(for: H.self)), of: H.self)
            })
    }

    var isPlain: Bool {
        return identifier == Language.plain.identifier
    }

    func matches(fileName: String) -> Bool {
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        return fileExtensions.contains(fileExtension) || fileNames.contains(fileName)
    }

    func matches(head: UnsafeRawBufferPointer) -> Bool {
        return sniffer(head)
    }

    /// The row's tokens and the state at its end.
    func tokens(_ text: String, startState: HighlightState) -> ([Token], HighlightState) {
        return tokenizer(text, startState)
    }

    /// The state at the row's end, without building its tokens.
    func endState(_ text: String, start: HighlightState) -> HighlightState {
        return endStateFinder(text, start)
    }
}

extension Language: Equatable {
    static func == (lhs: Language, rhs: Language) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}
