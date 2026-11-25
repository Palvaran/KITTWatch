import Foundation

// Scenario-based evaluation (brief, section 4). Scenarios live in Eval/scenarios.json,
// grouped into families. A family is either "dev" (used while tuning search and prompts)
// or "heldout" (written once and only reported), so near-duplicate phrasings cannot
// inflate the score.

public struct EvalSuite: Codable, Sendable {
    public var families: [EvalFamily]
}

public struct EvalFamily: Codable, Sendable {
    public var id: String
    /// "dev" or "heldout".
    public var split: String
    /// A wrong answer here is a safety failure, not just a miss.
    public var critical: Bool
    public var scenarios: [EvalScenario]
}

public struct EvalScenario: Codable, Sendable {
    public var id: String
    /// Household size set before the first turn, as the watch's stepper would.
    public var people: Int?
    public var turns: [EvalTurn]
}

public struct EvalTurn: Codable, Sendable {
    public var say: String
    public var expect: EvalExpectation?
}

public struct EvalExpectation: Codable, Sendable {
    /// The reply must cite one of these guide entries.
    public var entries: [String]?
    /// The right outcome is "the guide doesn't cover that".
    public var notCovered: Bool?
    /// Each inner list is a set of alternatives; one of them must appear (case-insensitive).
    public var mustSay: [[String]]?
    /// None of these may appear (case-insensitive).
    public var mustNotSay: [String]?
    /// Required opening sentence for replies where delaying the action changes its meaning.
    public var firstSentence: String?
    /// The conversation's flagged hazards after this turn must be exactly these.
    /// Only judged for builds that run the KITT session.
    public var activeHazards: [String]?
    /// Hazards answered but not flagged after this turn, and how: "ruledOut" (not in use)
    /// or "unknown" (not sure). Must be exactly these. Judged and counted with the flags.
    public var hazardAnswers: [String: ConditionChange.State]?
}

public struct EvalTurnResult: Codable, Sendable {
    public var say: String
    public var reply: String
    public var origin: String
    public var citations: [String]
    /// nil when the turn has no routing expectation, or the build cannot be judged on routing.
    public var routedCorrectly: Bool?
    /// KITT did not answer outright, but the right entry was one of the buttons it offered.
    public var offeredAsButton: Bool
    /// nil when the turn has no content expectation.
    public var contentCorrect: Bool?
    public var problems: [String]
    public var unsupportedNumbers: [String]
    /// Flagged hazards after this turn (KITT session builds only).
    public var activeHazardsAfter: [String]? = nil
    /// nil when the turn has no flag expectation or the build has no session.
    public var flagsCorrect: Bool? = nil
}

public enum EvalScorer {
    static let hedges = ["i'm not sure", "i am not sure", "not sure", "not certain", "i don't know", "i do not know",
                         "don't know", "do not know", "can't say", "cannot say"]

    static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    static func removingHedges(_ text: String) -> String {
        hedges.reduce(fold(text)) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    /// Case-insensitive, and the phrase must start and end on a word boundary, so
    /// "not" does not match "nothing" and "no" does not match "know".
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let haystack = fold(text), needle = fold(phrase)
        guard !needle.isEmpty else { return false }
        var from = haystack.startIndex
        while let r = haystack.range(of: needle, range: from..<haystack.endIndex) {
            let before = r.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: r.lowerBound)]
            let after = r.upperBound == haystack.endIndex ? nil : haystack[r.upperBound]
            let startsClean = !(needle.first!.isLetter || needle.first!.isNumber) || before.map { !($0.isLetter || $0.isNumber) } ?? true
            let endsClean = !(needle.last!.isLetter || needle.last!.isNumber) || after.map { !($0.isLetter || $0.isNumber) } ?? true
            if startsClean && endsClean { return true }
            from = haystack.index(after: r.lowerBound)
        }
        return false
    }

    /// Judge one reply against an expectation. `judgeRouting` is false for builds that
    /// have no guide (a bare model cannot cite an entry).
    public static func score(say: String, reply: AssistantMessage, expect: EvalExpectation?, judgeRouting: Bool) -> EvalTurnResult {
        var problems: [String] = []
        var routed: Bool?
        var content: Bool?
        var offered = false
        if let expect {
            if judgeRouting {
                if let entries = expect.entries {
                    let cited = reply.citations.map { $0.split(separator: "@").first.map(String.init) ?? $0 }
                    routed = cited.contains(where: entries.contains)
                    if routed == false {
                        offered = reply.suggestions.contains(where: entries.contains)
                        problems.append("expected \(entries.joined(separator: " or ")), got \(cited.isEmpty ? (offered ? "buttons that include it" : "no entry") : cited.joined(separator: ", "))")
                    }
                } else if expect.notCovered == true {
                    routed = reply.offersModel && reply.origin == .app
                    if routed == false { problems.append("expected \"not covered\", got an answer") }
                }
            }
            if expect.mustSay != nil || expect.mustNotSay != nil || expect.firstSentence != nil {
                content = true
                // "I'm not sure" is not a "not". Hedges are removed before required phrases
                // are looked for, and phrases only match on word boundaries.
                let positive = Self.removingHedges(reply.text)
                if judgeRouting, reply.origin == .app, reply.offersModel, expect.mustSay != nil {
                    // KITT said it had no answer. That cannot satisfy a required phrase.
                    content = false
                    problems.append("no answer given")
                } else {
                    for alternatives in expect.mustSay ?? [] where !alternatives.contains(where: { Self.containsPhrase(positive, $0) }) {
                        content = false
                        problems.append("missing: " + alternatives.joined(separator: " / "))
                    }
                }
                if let first = expect.firstSentence {
                    let actual = Self.fold(reply.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    let required = Self.fold(first)
                    if required.isEmpty || !actual.hasPrefix(required) {
                        content = false
                        problems.append("opening sentence should be: " + first)
                    }
                }
                for bad in expect.mustNotSay ?? [] where Self.containsPhrase(reply.text, bad) {
                    content = false
                    problems.append("said: " + bad)
                }
            }
        }
        return EvalTurnResult(say: say, reply: reply.text, origin: reply.origin.rawValue, citations: reply.citations,
                              routedCorrectly: routed, offeredAsButton: offered, contentCorrect: content, problems: problems,
                              unsupportedNumbers: reply.unsupportedNumbers)
    }
}

// MARK: - Running a suite

/// What is being measured.
public enum EvalBuild: String, Codable, Sendable, CaseIterable {
    /// The model alone: no guide, no calculator. The baseline.
    case model
    /// The model given the best-matching guide passage and asked to answer from it.
    case rag
    /// KITT as shipped: hazards, calculator and reviewed text first; the model is not consulted.
    case pipeline
    /// KITT as shipped, and every "Ask the model anyway" button is pressed.
    case pipelineWithModel = "pipeline+model"
}

public struct EvalScenarioResult: Codable, Sendable {
    public var family: String
    public var scenario: String
    public var split: String
    public var critical: Bool
    public var turns: [EvalTurnResult]
}

public struct EvalTally: Codable, Sendable, Equatable {
    public var routingJudged = 0, routingCorrect = 0
    /// Not answered outright, but the right entry was among the buttons offered.
    public var routingOffered = 0
    public var contentJudged = 0, contentCorrect = 0
    /// Turns in families marked critical that failed in any way: a wrong or missing
    /// answer, or the expected warning not shown outright.
    public var criticalFailures = 0
    /// The part of `criticalFailures` where the expected entry was not shown outright
    /// (a missed warning), whatever the reply said instead.
    public var criticalNotShown = 0
    public var repliesWithUnsupportedNumbers = 0
    public var flagsJudged = 0
    /// Turns after which the flagged hazards were not the expected ones.
    public var wrongFlags = 0
}

public struct EvalReport: Codable, Sendable {
    public var build: EvalBuild
    public var modelID: String?
    public var packVersion: String
    public var results: [EvalScenarioResult]

    public func tally(split: String? = nil) -> EvalTally {
        var t = EvalTally()
        for r in results where split == nil || r.split == split {
            for turn in r.turns {
                if let ok = turn.routedCorrectly {
                    t.routingJudged += 1
                    if ok { t.routingCorrect += 1 } else if turn.offeredAsButton { t.routingOffered += 1 }
                }
                if let ok = turn.contentCorrect {
                    t.contentJudged += 1
                    if ok { t.contentCorrect += 1 }
                }
                if r.critical, turn.routedCorrectly == false || turn.contentCorrect == false {
                    t.criticalFailures += 1
                    if turn.routedCorrectly == false { t.criticalNotShown += 1 }
                }
                if !turn.unsupportedNumbers.isEmpty { t.repliesWithUnsupportedNumbers += 1 }
                if let ok = turn.flagsCorrect { t.flagsJudged += 1; if !ok { t.wrongFlags += 1 } }
            }
        }
        return t
    }
}

public enum EvalRunner {
    public enum RunError: Error { case modelRequired }

    public static func run(_ build: EvalBuild, suite: EvalSuite, pack: ContentPack, generator: TextGenerating?,
                           only family: String? = nil, progress: (String) -> Void = { _ in }) throws -> EvalReport {
        if build != .pipeline, generator == nil { throw RunError.modelRequired }
        let search = GuideSearch(pack: pack)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("kitt-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var results: [EvalScenarioResult] = []
        for fam in suite.families where family == nil || fam.id == family {
            for scenario in fam.scenarios {
                progress("\(build.rawValue): \(fam.id)/\(scenario.id)")
                var turns: [EvalTurnResult] = []
                switch build {
                case .pipeline, .pipelineWithModel:
                    let log = try EventLog(fileURL: scratch.appendingPathComponent("\(UUID().uuidString).jsonl"), device: DeviceID("eval"))
                    let session = KITTSession(log: log, pack: pack)
                    if let people = scenario.people { try session.setFact(.people, Double(people)) }
                    for turn in scenario.turns {
                        var message: AssistantMessage
                        switch try session.send(turn.say) {
                        case .answered(let m): message = m
                        case .needsModel(let request): message = try runModel(request, session: session, generator: generator)
                        }
                        var result = EvalScorer.score(say: turn.say, reply: message, expect: turn.expect, judgeRouting: true)
                        if build == .pipelineWithModel, message.offersModel, let request = session.modelRequestForUnansweredQuestion() {
                            // Routing was judged on what KITT did first; content on what the model then said.
                            let final = try runModel(request, session: session, generator: generator)
                            let content = EvalScorer.score(say: turn.say, reply: final, expect: turn.expect, judgeRouting: false)
                            result.reply += "\n[Ask the model anyway] " + final.text
                            result.contentCorrect = content.contentCorrect
                            result.problems = result.problems.filter { $0.hasPrefix("expected") } + content.problems
                            result.unsupportedNumbers = final.unsupportedNumbers
                        }
                        let flags = session.state.activeHazards
                        result.activeHazardsAfter = flags
                        if let expected = turn.expect?.activeHazards {
                            result.flagsCorrect = Set(flags) == Set(expected)
                            if result.flagsCorrect == false {
                                result.problems.append("flagged \(flags.isEmpty ? "nothing" : flags.joined(separator: ", ")), expected \(expected.isEmpty ? "nothing" : expected.joined(separator: ", "))")
                            }
                        }
                        if let expected = turn.expect?.hazardAnswers {
                            let got = session.state.hazardAnswers
                            func describe(_ a: [String: ConditionChange.State]) -> String {
                                a.isEmpty ? "none" : a.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.rawValue)" }.joined(separator: ", ")
                            }
                            if got != expected {
                                result.flagsCorrect = false
                                result.problems.append("answers \(describe(got)), expected \(describe(expected))")
                            } else if result.flagsCorrect == nil {
                                result.flagsCorrect = true
                            }
                        }
                        turns.append(result)
                    }
                case .model, .rag:
                    guard let generator else { throw RunError.modelRequired }
                    var history: [ChatTurn] = []
                    var raised: [GuideEntry] = []
                    for turn in scenario.turns {
                        let prompt: ModelPrompt
                        var citations: [String] = []
                        var sources = [turn.say]
                        if build == .rag {
                            for h in search.hazardsRaised(by: turn.say) where !raised.contains(where: { $0.id == h.id }) { raised.append(h) }
                            let best = search.rank(turn.say).first?.entry
                            let passages = best.map { [$0.modelPassage] } ?? []
                            let warnings = raised.filter { $0.id != best?.id }.map(\.modelPassage)
                            if passages.isEmpty && warnings.isEmpty {
                                prompt = PromptBuilder.open(question: turn.say)
                            } else {
                                prompt = PromptBuilder.grounded(question: turn.say, passages: passages, warnings: warnings)
                                citations = (best.map { [$0.citation] } ?? []) + raised.filter { $0.id != best?.id }.map(\.citation)
                                sources += passages + warnings
                            }
                        } else {
                            var p = PromptBuilder.open(question: turn.say)
                            p.turns = [p.turns[0]] + history.suffix(4) + [ChatTurn(.user, turn.say)]
                            prompt = p
                        }
                        var text = ""
                        _ = try generator.generate(prompt) { text += $0 }
                        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        history += [ChatTurn(.user, turn.say), ChatTurn(.assistant, text)]
                        var message = AssistantMessage(text: text, origin: .model, citations: citations, modelID: generator.modelID)
                        if build == .rag, !citations.isEmpty { message.unsupportedNumbers = NumberCheck.unsupported(in: text, sources: sources) }
                        turns.append(EvalScorer.score(say: turn.say, reply: message, expect: turn.expect, judgeRouting: false))
                    }
                }
                results.append(EvalScenarioResult(family: fam.id, scenario: scenario.id, split: fam.split, critical: fam.critical, turns: turns))
            }
        }
        return EvalReport(build: build, modelID: generator?.modelID, packVersion: "\(pack.packID)@v\(pack.version)", results: results)
    }

    private static func runModel(_ request: ModelRequest, session: KITTSession, generator: TextGenerating?) throws -> AssistantMessage {
        guard let generator else { throw RunError.modelRequired }
        var text = ""
        let stats = try generator.generate(request.prompt) { text += $0 }
        return try session.recordModelReply(text, for: request, modelID: generator.modelID, interrupted: stats.stop == .cancelled)
    }
}
