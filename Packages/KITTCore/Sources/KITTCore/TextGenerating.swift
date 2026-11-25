import Foundation

public struct ChatTurn: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String
    public init(_ role: Role, _ content: String) { self.role = role; self.content = content }
}

/// Everything the engine needs for one reply. Built from the saved record, never from
/// model state, so any device can resume a conversation with its own model.
public struct ModelPrompt: Equatable, Sendable {
    public var turns: [ChatTurn]
    public var maxNewTokens: Int
    /// Stop after this many sentences (0 = no limit). Short answers suit the wrist and
    /// give a small model less room to drift.
    public var maxSentences: Int
    /// Greedy decoding: the same prompt always gives the same reply. Used for grounded
    /// answers and for evaluation.
    public var deterministic: Bool

    public init(turns: [ChatTurn], maxNewTokens: Int = 96, maxSentences: Int = 3, deterministic: Bool = true) {
        self.turns = turns
        self.maxNewTokens = maxNewTokens
        self.maxSentences = maxSentences
        self.deterministic = deterministic
    }
}

/// Measurements from one generation.
public struct GenerationStats: Codable, Equatable, Sendable {
    public enum Stop: String, Codable, Sendable { case endOfTurn, maxTokens, maxSentences, contextFull, cancelled }
    public var promptTokens: Int
    /// Prompt tokens already in the engine's cache from the previous call (not re-evaluated).
    public var reusedTokens: Int
    public var generatedTokens: Int
    public var prefillMilliseconds: Double
    /// From the start of inference to the first visible token.
    public var timeToFirstTokenMilliseconds: Double?
    public var generationMilliseconds: Double
    public var stop: Stop

    public init(promptTokens: Int, reusedTokens: Int = 0, generatedTokens: Int, prefillMilliseconds: Double,
                timeToFirstTokenMilliseconds: Double?, generationMilliseconds: Double, stop: Stop) {
        self.promptTokens = promptTokens
        self.reusedTokens = reusedTokens
        self.generatedTokens = generatedTokens
        self.prefillMilliseconds = prefillMilliseconds
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.generationMilliseconds = generationMilliseconds
        self.stop = stop
    }

    public var tokensPerSecond: Double {
        generationMilliseconds > 0 ? Double(generatedTokens) / (generationMilliseconds / 1000) : 0
    }
    public var prefillTokensPerSecond: Double {
        let evaluated = promptTokens - reusedTokens
        return prefillMilliseconds > 0 ? Double(evaluated) / (prefillMilliseconds / 1000) : 0
    }
}

/// A local model. The watch uses llama.cpp with a small model; the Mac can plug in a
/// larger one behind the same interface and rebuild prompts from the same event record.
public protocol TextGenerating: AnyObject {
    /// File name plus checksum prefix, saved with every model reply.
    var modelID: String { get }
    /// Blocking. Call off the main thread. `onText` receives display-ready text pieces.
    func generate(_ prompt: ModelPrompt, onText: (String) -> Void) throws -> GenerationStats
    /// Evaluate the fixed start of the prompt (the system text) ahead of time so the
    /// first question does not pay for it. Blocking; safe to skip.
    func prewarm(_ prompt: ModelPrompt) throws
    /// Thread-safe. Stops prefill or generation at the next opportunity.
    func cancel()
}

/// Turns streamed token bytes into displayable text without splitting a multi-byte
/// UTF-8 character across tokens (emoji, "×", accented names).
public struct UTF8Accumulator: Sendable {
    private var pending: [UInt8] = []
    public init() {}

    /// Append bytes and return whatever is now complete.
    public mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        let cut = completePrefixLength(pending)
        guard cut > 0 else { return "" }
        let out = String(decoding: pending[0..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return out
    }

    /// Flush anything left (invalid sequences become U+FFFD).
    public mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    private func completePrefixLength(_ b: [UInt8]) -> Int {
        // Look back at most 3 bytes for an unfinished multi-byte sequence.
        var i = b.count - 1
        var back = 0
        while i >= 0 && back < 4 {
            let byte = b[i]
            if byte & 0xC0 != 0x80 {  // lead byte or ASCII
                let need: Int
                if byte & 0x80 == 0 { need = 1 }
                else if byte & 0xE0 == 0xC0 { need = 2 }
                else if byte & 0xF0 == 0xE0 { need = 3 }
                else if byte & 0xF8 == 0xF0 { need = 4 }
                else { need = 1 }  // invalid lead; let the decoder replace it
                return (b.count - i) >= need ? b.count : i
            }
            i -= 1
            back += 1
        }
        return b.count
    }
}

/// Counts sentence ends in streamed text so generation can stop after a few.
/// A terminator counts only when whitespace or the end of the stream follows it, and
/// never after a digit or a single letter, so "1.5 gal", "2. Boil", "U.S." and "e.g."
/// do not end a sentence.
public struct SentenceCounter: Sendable {
    public private(set) var count = 0
    private var pendingTerminator = false
    private var wordLength = 0
    private var lastWasDigit = false
    public init() {}

    public mutating func append(_ text: String) {
        for ch in text {
            if pendingTerminator {
                if ch == " " || ch == "\n" { count += 1 }
                pendingTerminator = false
            }
            if ch == "." || ch == "!" || ch == "?" {
                pendingTerminator = ch != "." || (!lastWasDigit && wordLength > 1)
                wordLength = 0
                lastWasDigit = false
            } else if ch.isLetter {
                wordLength += 1
                lastWasDigit = false
            } else {
                lastWasDigit = ch.isNumber
                wordLength = 0
            }
        }
    }

    /// A terminator at the very end of the stream also ends a sentence.
    public var countIncludingTrailing: Int { count + (pendingTerminator ? 1 : 0) }
}
