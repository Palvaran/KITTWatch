import XCTest
import KITTCore
@testable import KITTEngine

/// These run the real model, so they need it on disk:
///   KITT_MODEL=Models/SmolLM2-135M-Instruct-Q4_0.gguf scripts/kitt test
/// Without KITT_MODEL they are skipped.
final class LlamaEngineTests: XCTestCase {
    static var engine: LlamaEngine?

    func engine() throws -> LlamaEngine {
        if let e = Self.engine { return e }
        guard let path = ProcessInfo.processInfo.environment["KITT_MODEL"], !path.isEmpty else {
            throw XCTSkip("set KITT_MODEL to a .gguf file to run engine tests")
        }
        let url = URL(fileURLWithPath: path)
        let e = try LlamaEngine(modelURL: url, modelID: url.deletingPathExtension().lastPathComponent)
        Self.engine = e
        return e
    }

    let passage = "Store at least 1 US gallon of water per person per day, for several days."

    func testGreedyRepliesAreRepeatable() throws {
        let e = try engine()
        let prompt = PromptBuilder.grounded(question: "How much water per person?", passages: [passage])
        var first = "", second = ""
        let s1 = try e.generate(prompt) { first += $0 }
        let s2 = try e.generate(prompt) { second += $0 }
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second, "greedy decoding must not depend on what the cache held")
        XCTAssertGreaterThan(s1.generatedTokens, 0)
        XCTAssertEqual(s2.reusedTokens, s2.promptTokens - 1, "an identical prompt re-evaluates only its last token")
    }

    func testSystemTextIsNotEvaluatedTwice() throws {
        let e = try engine()
        let system = try e.countTokens(ModelPrompt(turns: [ChatTurn(.system, PromptBuilder.groundedSystem)]))
        try e.prewarm(PromptBuilder.grounded(question: "", passages: []))
        var text = ""
        let stats = try e.generate(PromptBuilder.grounded(question: "Does that include washing?", passages: [passage])) { text += $0 }
        // The cached prefix is the system turn, give or take the template's turn boundary.
        XCTAssertGreaterThan(stats.reusedTokens, system - 12)
        XCTAssertLessThan(stats.reusedTokens, stats.promptTokens)
    }

    func testReuseMatchesAColdEngine() throws {
        let e = try engine()
        let a = PromptBuilder.grounded(question: "Why per person?", passages: [passage])
        let b = PromptBuilder.grounded(question: "Does hot weather change it?", passages: [passage])
        var warm = ""
        _ = try e.generate(a) { _ in }
        _ = try e.generate(b) { warm += $0 }

        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KITT_MODEL"]!)
        let cold = try LlamaEngine(modelURL: url, modelID: "cold")
        var fresh = ""
        _ = try cold.generate(b) { fresh += $0 }
        XCTAssertEqual(warm, fresh, "a reply after cache reuse must equal a reply from a fresh context")
    }

    func testCancelLeavesTheEngineUsable() throws {
        let e = try engine()
        let prompt = PromptBuilder.open(question: "List ten things to keep in an emergency kit.")
        var pieces = 0
        let stats = try e.generate(ModelPrompt(turns: prompt.turns, maxNewTokens: 96, maxSentences: 0)) { _ in
            pieces += 1
            if pieces == 3 { e.cancel() }
        }
        XCTAssertEqual(stats.stop, .cancelled)
        var again = ""
        let after = try e.generate(PromptBuilder.grounded(question: "How much water per person?", passages: [passage])) { again += $0 }
        XCTAssertNotEqual(after.stop, .cancelled)
        XCTAssertFalse(again.isEmpty)
    }

    func testSentenceLimitStopsGeneration() throws {
        let e = try engine()
        var text = ""
        let stats = try e.generate(ModelPrompt(turns: [ChatTurn(.user, "Describe rain in five sentences.")], maxNewTokens: 120, maxSentences: 1)) { text += $0 }
        XCTAssertEqual(stats.stop, .maxSentences)
    }
}
