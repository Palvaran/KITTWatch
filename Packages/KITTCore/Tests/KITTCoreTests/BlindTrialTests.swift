import XCTest
@testable import KITTCore

/// Scoring for blind trials: what each reply did with the question, so asking a needed
/// question, a button, a guess and a confidently wrong answer are counted apart.
final class BlindTrialTests: XCTestCase {
    func testPlainTextBecomesOneHeldOutFamily() {
        let text = """
        # Written by someone who hasn't read the guide.
        The power went out last night. Is the milk okay?
          What about the cheese?

        The city says boil the water. Can I brush my teeth?


        # trailing comment
        Can the dog drink from the tap?
        """
        let suite = EvalSuite.blindTrial(from: text, name: "blind-hurricane", people: 3)
        XCTAssertEqual(suite.families.count, 1)
        let family = suite.families[0]
        XCTAssertEqual(family.id, "blind-hurricane")
        XCTAssertEqual(family.split, "heldout", "written once and only reported")
        XCTAssertEqual(family.scenarios.map(\.id), ["q01", "q02", "q03"])
        XCTAssertEqual(family.scenarios[0].turns.map(\.say),
                       ["The power went out last night. Is the milk okay?", "What about the cheese?"],
                       "consecutive lines are follow-ups in one conversation")
        XCTAssertEqual(family.scenarios[2].turns.map(\.say), ["Can the dog drink from the tap?"])
        XCTAssertEqual(family.scenarios[0].people, 3)
        XCTAssertTrue(family.scenarios.allSatisfy { $0.turns.allSatisfy { $0.expect == nil } }, "labels come later")
    }

    func outcome(_ reply: AssistantMessage, _ expect: EvalExpectation) -> EvalOutcome? {
        EvalScorer.score(say: "q", reply: reply, expect: expect, judgeRouting: true).outcome
    }

    func expectEntry(_ id: String, asks: Bool? = nil) -> EvalExpectation {
        EvalExpectation(entries: [id], asks: asks)
    }

    var notCovered: EvalExpectation { EvalExpectation(notCovered: true) }

    func testOutcomes() {
        let food = "food.outage.cold"
        let answer = AssistantMessage(text: "Keep the doors closed.", origin: .app, citations: ["\(food)@v2"])
        XCTAssertEqual(outcome(answer, expectEntry(food)), .answered)
        XCTAssertEqual(outcome(answer, expectEntry(food, asks: true)), .guessed,
                       "answering when the answer depends on a missing fact is a guess")

        let question = AssistantMessage(text: "Is it running there?", origin: .app, citations: ["power.generator.co@v3"],
                                        asksHazardQuestion: true)
        XCTAssertEqual(outcome(question, expectEntry("power.generator.co", asks: true)), .asked)
        let fact = AssistantMessage(text: "How many people?", origin: .app, citations: ["water.storage.amount@v2"],
                                    needsFact: .people)
        XCTAssertEqual(outcome(fact, expectEntry("water.storage.amount", asks: true)), .asked)

        let buttons = AssistantMessage(text: "Is it one of these?", origin: .app, suggestions: ["water.without", food],
                                       offersModel: true)
        XCTAssertEqual(outcome(buttons, expectEntry(food)), .button)
        let ambiguous = EvalScorer.score(say: "q", reply: buttons, expect: notCovered, judgeRouting: true)
        XCTAssertEqual(ambiguous.outcome, .missed)
        XCTAssertEqual(ambiguous.routedCorrectly, false)
        XCTAssertEqual(outcome(buttons, expectEntry("health.dehydration")), .missed)

        let other = AssistantMessage(text: "Freezer answer.", origin: .app, citations: ["food.outage.freezer@v1"],
                                     suggestions: [food])
        XCTAssertEqual(outcome(other, expectEntry(food)), .wrong,
                       "another entry shown outright is wrong, even with the right one among related topics")

        let precaution = AssistantMessage(text: "Never run a generator indoors.\n" + KITTSession.precautionNote, origin: .app,
                                          citations: ["power.generator.co@v3"], suggestions: [food])
        XCTAssertEqual(outcome(precaution, expectEntry(food)), .button, "a precaution's alternatives sit under it")
        XCTAssertEqual(outcome(precaution, expectEntry("water.without")), .precaution)

        let none = AssistantMessage(text: "The guide doesn't cover that yet. Browse the topics.", origin: .app, offersModel: true)
        XCTAssertEqual(outcome(none, notCovered), .notCovered)
        XCTAssertEqual(outcome(none, expectEntry(food)), .missed)
        XCTAssertEqual(outcome(answer, notCovered), .wrong, "an answer where the guide has none")
        XCTAssertNil(EvalScorer.score(say: "q", reply: answer, expect: nil, judgeRouting: true).outcome, "unlabelled")
    }

    /// Credit only for asking the fact the answer depends on (asksFor).
    func testOnlyTheRightQuestionEarnsCredit() {
        let expect = EvalExpectation(entries: ["water.advisory.boil"], asks: true, asksFor: "notice")
        func score(_ m: AssistantMessage) -> EvalTurnResult { EvalScorer.score(say: "q", reply: m, expect: expect, judgeRouting: true) }

        let notice = AssistantMessage(text: "What does the notice say?", origin: .app, citations: ["water.advisory.types@v1"],
                                      noticeQuestion: "Can the dog drink from the tap?")
        XCTAssertEqual(score(notice).outcome, .asked)
        XCTAssertEqual(score(notice).routedCorrectly, true)

        let household = AssistantMessage(text: "How many people?", origin: .app, citations: ["water.storage.baseline@v2"],
                                         needsFact: .people)
        XCTAssertEqual(score(household).outcome, .askedOther, "asking for the household size earns nothing here")
        XCTAssertEqual(score(household).routedCorrectly, false)

        let guess = AssistantMessage(text: "Use bottled water...", origin: .guide, citations: ["water.advisory.boil@v2"])
        XCTAssertEqual(score(guess).outcome, .guessed)
        XCTAssertEqual(score(guess).routedCorrectly, false)

        XCTAssertEqual(notice.askedFor, "notice")
        XCTAssertEqual(household.askedFor, "people")
        XCTAssertEqual(AssistantMessage(text: "Is it running?", origin: .app, asksHazardQuestion: true).askedFor, "hazardUse")
    }

    /// Labels carry `asksFor` beside `asks`, so evaluators that predate it still read them.
    func testLabelsWithAsksForStillDecodeAsBefore() throws {
        struct Frozen: Decodable { var entries: [String]?; var asks: Bool? }
        let json = Data(#"{"entries": ["water.advisory.boil"], "asks": true, "asksFor": "notice"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Frozen.self, from: json).asks, true)
        XCTAssertEqual(try JSONDecoder().decode(EvalExpectation.self, from: json).asksFor, "notice")
    }

    func testTallyCountsOutcomesAndAGuessIsNotRoutedCorrectly() {
        let food = "food.outage.cold"
        let answer = AssistantMessage(text: "Keep the doors closed.", origin: .app, citations: ["\(food)@v2"])
        let guess = EvalScorer.score(say: "q", reply: answer, expect: expectEntry(food, asks: true), judgeRouting: true)
        XCTAssertEqual(guess.routedCorrectly, false)
        XCTAssertTrue(guess.problems.contains { $0.contains("without asking") }, "\(guess.problems)")
        let hit = EvalScorer.score(say: "q", reply: answer, expect: expectEntry(food), judgeRouting: true)
        let report = EvalReport(build: .pipeline, modelID: nil, packVersion: "test", results: [
            EvalScenarioResult(family: "blind", scenario: "q01", split: "heldout", critical: false, turns: [guess, hit]),
        ])
        XCTAssertEqual(report.tally(split: "heldout").outcomes, ["guessed": 1, "answered": 1])
    }
}
