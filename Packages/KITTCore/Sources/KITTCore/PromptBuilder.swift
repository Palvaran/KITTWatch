import Foundation

/// Size limits for a prompt, in characters. The engine checks real token counts; these
/// keep prompts small on purpose, because every prompt token costs about 40 ms of
/// waiting on the Series 5 before the first word appears.
public struct PromptBudget: Equatable, Sendable {
    public var maxNewTokens = 96
    public var maxSentences = 3
    /// Guide text handed to the model, all passages together.
    public var passageCharacters = 700
    public var questionCharacters = 300
    public init() {}
}

/// Builds model prompts from the saved record (not from model state), so any device
/// can resume a conversation with its own model.
///
/// The system text is identical for every grounded question. The engine keeps it
/// evaluated between calls, so only the passage and the question are paid for.
public enum PromptBuilder {
    /// Sentence the model is told to use when the passage has no answer. The session
    /// recognises it and offers the topic list instead of showing it as an answer.
    public static let notCovered = "The guide does not cover that."

    public static let groundedSystem = """
    You are KITT, an offline preparedness guide. Answer the question using only the GUIDE text. \
    Use one or two short sentences. Do not add numbers or steps that are not in the GUIDE. \
    If the GUIDE does not answer the question, reply exactly: \(notCovered)
    """

    public static let openSystem = """
    You are KITT, an offline preparedness assistant. Answer in one or two short sentences. \
    If you are not sure, say you are not sure.
    """

    /// A question answered from guide passages. `warnings` are passages of active
    /// hazards and come first.
    public static func grounded(question: String, passages: [String], warnings: [String] = [],
                                budget: PromptBudget = PromptBudget()) -> ModelPrompt {
        var guide = ""
        for w in warnings { guide += "WARNING: " + w + "\n" }
        guide += passages.joined(separator: "\n")
        let user = "GUIDE: " + clip(guide, budget.passageCharacters) + "\n\nQUESTION: " + clip(question, budget.questionCharacters)
        return ModelPrompt(turns: [ChatTurn(.system, groundedSystem), ChatTurn(.user, user)],
                           maxNewTokens: budget.maxNewTokens, maxSentences: budget.maxSentences, deterministic: true)
    }

    /// A question with no guide text behind it. Only used when the user asks for it.
    public static func open(question: String, budget: PromptBudget = PromptBudget()) -> ModelPrompt {
        ModelPrompt(turns: [ChatTurn(.system, openSystem), ChatTurn(.user, clip(question, budget.questionCharacters))],
                    maxNewTokens: budget.maxNewTokens, maxSentences: budget.maxSentences, deterministic: true)
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit))
    }
}

/// Finds numbers in a model reply that appear nowhere in the text the model was given.
/// A small model that writes "boil for 10 minutes" when the guide says 1 is the failure
/// that matters most here, and it is cheap to catch.
public enum NumberCheck {
    static let words: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "fifteen": "15",
        "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50", "hundred": "100",
        "half": "0.5",
    ]

    /// Numbers in `text`, digits and common number words alike, in a canonical form.
    public static func numbers(in text: String) -> Set<String> {
        var out = Set<String>()
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            var n = current
            while n.hasSuffix(".") { n.removeLast() }
            if n.contains(".") { while n.hasSuffix("0") { n.removeLast() }; if n.hasSuffix(".") { n.removeLast() } }
            if !n.isEmpty { out.insert(n) }
            current = ""
        }
        for ch in text {
            if ch.isASCII, ch.isNumber { current.append(ch) }
            else if ch == ".", !current.isEmpty, !current.contains(".") { current.append(ch) }
            else if ch == ",", !current.isEmpty { continue }
            else { flush() }
        }
        flush()
        for w in Text.tokens(Text.normalize(text)) { if let n = words[w] { out.insert(n) } }
        if text.contains("½") { out.insert("0.5") }
        return out
    }

    /// Numbers in the reply that are not in any of the sources, sorted.
    public static func unsupported(in reply: String, sources: [String]) -> [String] {
        let known = sources.reduce(into: Set<String>()) { $0.formUnion(numbers(in: $1)) }
        return numbers(in: reply).subtracting(known).sorted()
    }
}
