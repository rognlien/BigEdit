import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A pattern the on-device model proposed, with its reasoning.
struct PatternSuggestion: Equatable {
    let pattern: String
    let explanation: String
}

/// Apple Intelligence, used for the one job it fits here: turning a
/// sentence into a regular expression, and a regular expression back into
/// a sentence.
///
/// The on-device Foundation Models framework arrived with macOS 26, so
/// everything is behind an availability check and the app still builds and
/// runs on macOS 13. The model's context is a few thousand tokens, which
/// rules out anything about the document as a whole — the files BigEdit
/// exists for are gigabytes — but a pattern and a few sample lines fit
/// easily, and that is what the assistant sees. Nothing leaves the Mac.
enum PatternAssistant {

    enum AssistantError: LocalizedError {
        case unavailable(String)
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .emptyAnswer: return "Apple Intelligence did not suggest a pattern."
            }
        }
    }

    /// Whether the model can be asked on this Mac right now.
    static var isAvailable: Bool {
        unavailableReason == nil
    }

    /// Why the model cannot be asked, in words, or `nil` when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This Mac cannot run Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Apple Intelligence is turned off in System Settings."
                case .modelNotReady:
                    return "Apple Intelligence is still downloading its model."
                @unknown default:
                    return "Apple Intelligence is not available."
                }
            }
        }
        return "Apple Intelligence needs macOS 26 or later."
        #else
        return "This build of BigEdit was made without Apple Intelligence support."
        #endif
    }

    /// The instructions every session starts from.
    private static let instructions = """
        You write ICU regular expressions, the dialect used by NSRegularExpression on Apple \
        platforms. ^ and $ match at line boundaries. Prefer a pattern that is simple and \
        readable over one that is clever. Use capture groups only when the user asks for \
        parts of the match. Never wrap the pattern in slashes or quotes.
        """

    /// A pattern for what `description` asks for. `sample` is a few lines
    /// of the document, so the model can see what the text looks like.
    static func suggestPattern(for description: String, sample: String?) async throws -> PatternSuggestion {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard isAvailable else {
                throw AssistantError.unavailable(unavailableReason ?? "")
            }
            var prompt = "Write a regular expression that matches: \(description)"
            if let sample, !sample.isEmpty {
                prompt += "\n\nThe text it will run over looks like this:\n\(sample)"
            }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: GeneratedPattern.self)
            let pattern = response.content.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else {
                throw AssistantError.emptyAnswer
            }
            return PatternSuggestion(pattern: pattern,
                                     explanation: response.content.explanation
                                        .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #endif
        throw AssistantError.unavailable(unavailableReason ?? "")
    }

    /// What `pattern` matches, in a sentence or two.
    static func explain(pattern: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard isAvailable else {
                throw AssistantError.unavailable(unavailableReason ?? "")
            }
            let session = LanguageModelSession(instructions: instructions)
            let prompt = "Explain, in two or three plain sentences for someone who does not know "
                + "regular expressions, what this ICU regular expression matches: \(pattern)"
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw AssistantError.emptyAnswer
            }
            return text
        }
        #endif
        throw AssistantError.unavailable(unavailableReason ?? "")
    }
}

#if canImport(FoundationModels)
/// The shape the model fills in, so the pattern comes back as a field
/// rather than prose to be parsed.
@available(macOS 26.0, *)
@Generable
struct GeneratedPattern {
    @Guide(description: "The ICU regular expression, with no surrounding slashes or quotes.")
    var pattern: String

    @Guide(description: "One or two sentences on how the pattern works.")
    var explanation: String
}
#endif
