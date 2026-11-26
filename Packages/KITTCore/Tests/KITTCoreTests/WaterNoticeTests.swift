import XCTest
@testable import KITTCore

/// Water notices: which kind is in force decides what is safe, so KITT asks when a notice
/// is mentioned without its kind, answers directly when the kind is given, and keeps the
/// kind for the rest of the conversation until the notice is lifted.
final class WaterNoticeReaderTests: XCTestCase {
    func read(_ s: String) -> WaterNotice.Reading { WaterNotice.read(s) }

    func testANoticeWithoutItsKind() {
        for s in ["The city sent a water alert. Can the dog drink from the tap?",
                  "We got a water notice. Can I brush my teeth?",
                  "There's a notice about our tap water.",
                  "The water utility issued a notice. Can we drink from the tap?",
                  "We got a text alert about our tap water. What does it mean?"] {
            XCTAssertTrue(read(s).mentionsNotice, s)
            XCTAssertEqual(read(s).kinds, [], s)
        }
    }

    func testTheKindByNameOrAsAnInstruction() {
        let cases: [(String, WaterNotice)] = [
            ("We're under a boil-water notice", .boil),
            ("They told us to boil the water. What about the dog's bowl?", .boil),
            ("City says we have to boil our water. For how long?", .boil),
            ("We have to boil our water. What about the dog?", .boil),
            ("There's a boil order for our street.", .boil),
            ("We're under a do not drink advisory. Can we just boil it?", .doNotDrink),
            ("The city says not to drink the tap water.", .doNotDrink),
            ("They said don't drink from the tap.", .doNotDrink),
            ("We're under a do not use water advisory", .doNotUse),
            ("The utility told us to avoid all contact with the tap water.", .doNotUse),
        ]
        for (s, kind) in cases {
            XCTAssertTrue(read(s).mentionsNotice, s)
            XCTAssertEqual(read(s).kinds, [kind], s)
        }
    }

    func testNotANotice() {
        for s in ["How long do we boil water?",
                  "We need to boil water from the creek. How long?",
                  "Can we drink rainwater if we boil it?",
                  "There's a heat advisory. Can I drink tap water?",
                  "We got an emergency alert about the hurricane.",
                  "Is our tap water safe?",
                  "I'll boil pasta in bottled water instead. Can I use the tap water for the dog's bowl?",
                  "Don't use candles when the power is out."] {
            XCTAssertFalse(read(s).mentionsNotice, s)
        }
    }

    func testComparingKindsAndAskingWhatOneMeans() {
        let compare = read("What is the difference between a boil water and a do not drink notice?")
        XCTAssertTrue(compare.asksMeaning, "a comparison is a question about meaning, not a notice in force")
        XCTAssertTrue(read("What does a do not drink notice mean?").asksMeaning)
        XCTAssertTrue(read("What do the water notices mean?").asksMeaning)
        XCTAssertFalse(read("We got a water notice. Can I brush my teeth?").asksMeaning)
    }

    func testLiftedAndWhatElseTheMessageAsks() {
        let r = read("The boil notice was lifted yesterday. How much water should I store for the dog?")
        XCTAssertTrue(r.lifted)
        XCTAssertEqual(r.remainder, "How much water should I store for the dog?")
        XCTAssertTrue(read("The water advisory is over.").lifted)
        XCTAssertEqual(read("The water advisory is over.").remainder, "")
        XCTAssertFalse(read("We're under a boil water notice").lifted)
        XCTAssertFalse(read("The outage is over.").lifted, "only a notice that is named ends")
    }

    func testAnswersToTheQuestion() {
        XCTAssertEqual(WaterNotice.answer(to: "Boil water"), .notice(.boil))
        XCTAssertEqual(WaterNotice.answer(to: "Do not drink"), .notice(.doNotDrink))
        XCTAssertEqual(WaterNotice.answer(to: "Do not use"), .notice(.doNotUse))
        XCTAssertEqual(WaterNotice.answer(to: "Not sure"), .unsure)
        XCTAssertEqual(WaterNotice.answer(to: "It says to boil water for a minute."), .notice(.boil))
        XCTAssertEqual(WaterNotice.answer(to: "We're under a boil-water advisory."), .notice(.boil))
        XCTAssertEqual(WaterNotice.answer(to: "The water utility issued a boil order."), .notice(.boil))
        XCTAssertEqual(WaterNotice.answer(to: "It says do not drink."), .notice(.doNotDrink))
        XCTAssertEqual(WaterNotice.answer(to: "Don't drink it and don't boil it."), .notice(.doNotDrink))
        XCTAssertEqual(WaterNotice.answer(to: "No contact with the water at all."), .notice(.doNotUse))
        XCTAssertEqual(WaterNotice.answer(to: "I don't know, it didn't say."), .unsure)
        XCTAssertEqual(WaterNotice.answer(to: "I think it says boil."), .unsure, "a hedge decides nothing")
        XCTAssertNil(WaterNotice.answer(to: "How long does food stay safe without power?"))
        XCTAssertNil(WaterNotice.answer(to: "Should we boil water from the creek?"), "a new question, not an answer")
        XCTAssertEqual(WaterNotice.answer(to: "Boil it or don't drink it, I can't remember which."), .unsure)
    }

    func testEntriesExist() throws {
        let pack = try ContentPack.bundled()
        for id in WaterNotice.entryIDs { XCTAssertNotNil(pack.entry(id), id) }
    }
}

final class WaterNoticeSessionTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitt-notice-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func session() throws -> KITTSession {
        KITTSession(log: try EventLog(fileURL: dir.appendingPathComponent("events.jsonl"), device: DeviceID("watch")),
                    pack: try ContentPack.bundled())
    }

    func reply(_ o: TurnOutcome) -> AssistantMessage {
        guard case let .answered(m) = o else { XCTFail("\(o)"); return AssistantMessage(text: "", origin: .app) }
        return m
    }

    func testUnconfirmedEndLeavesTheReportedNoticeInForce() throws {
        let s = try session()
        _ = try s.send("We are under a do not use water advisory.")
        for line in ["Has the do not use water advisory been lifted?",
                     "The do not use water advisory has not been lifted.",
                     "The city might lift the water advisory tomorrow.",
                     "Our water notice was lifted in the next county.",
                     "The boil notice was lifted yesterday."] {
            _ = try s.send(line)
            XCTAssertEqual(s.state.waterNotice, .doNotUse, line)
        }
        let followup = reply(try s.send("The boil notice was lifted yesterday. Can we shower?"))
        XCTAssertEqual(followup.citations, ["water.advisory.do-not-drink@v1"])
        XCTAssertEqual(try session().state.waterNotice, .doNotUse)
        _ = try s.send("The city lifted our do not use water advisory.")
        XCTAssertNil(s.state.waterNotice)
    }

    func testClosureAndReplacementInOneMessage() throws {
        let s = try session()
        _ = try s.send("We are under a boil water notice.")
        _ = try s.send("The boil notice was lifted. We are under a do not use water advisory.")
        XCTAssertEqual(try session().state.waterNotice, .doNotUse)
    }

    func testReportedInstructionsAndInformalClosureInConversation() throws {
        let pairs = [
            ("They told us to boil the water", "They’ve lifted the boil notice"),
            ("They said boil water", "Boil notice lifted."),
            ("Boil water for one minute, it says", "The boil water notice got lifted this morning."),
        ]
        let s = try session()
        let boilCitation = try XCTUnwrap(s.pack.entry(WaterNotice.boil.entryID)).citation
        for (instruction, lifted) in pairs {
            XCTAssertEqual(WaterNotice.read(lifted).endedKinds, [.boil], lifted)
            _ = try s.send("We got a water notice. Can I brush my teeth?")
            let answer = reply(try s.send(instruction))
            XCTAssertEqual(answer.citations, [boilCitation], instruction)
            XCTAssertNil(s.state.pendingNoticeQuestion, instruction)
            XCTAssertEqual(try session().state.waterNotice, .boil, instruction)
            XCTAssertEqual(reply(try s.send("Can we shower?")).citations, [boilCitation], instruction)
            _ = try s.send(lifted)
            XCTAssertNil(try session().state.waterNotice, lifted)
        }
    }

    func testInformalWordingStillRequiresAConfirmedSingleNotice() throws {
        let s = try session()
        let question = "We got a water notice. Can I brush my teeth?"
        _ = try s.send(question)
        for line in ["They told us not to boil the water.", "They never said boil water.",
                     "Maybe they said boil water.", "They said boil water or do not drink it."] {
            XCTAssertEqual(reply(try s.send(line)).askedFor, "notice", line)
            XCTAssertNil(s.state.waterNotice, line)
            XCTAssertEqual(s.state.pendingNoticeQuestion, question, line)
        }
        _ = try s.send("Do not use")
        for line in ["Do not use water advisory lifted?", "They haven't lifted the do not use water advisory.",
                     "The do not use advisory hasn't been lifted.",
                     "Maybe the do not use advisory got lifted.", "They’ve lifted the boil notice."] {
            _ = try s.send(line)
            XCTAssertEqual(s.state.waterNotice, .doNotUse, line)
        }
    }

    func testNegatedBoilingDoesNotAnswerThePendingQuestion() throws {
        let s = try session()
        let original = "We got a water notice. Can I brush my teeth?"
        _ = try s.send(original)
        let answer = reply(try s.send("It says do not boil the water."))
        XCTAssertEqual(answer.askedFor, "notice")
        XCTAssertNil(s.state.waterNotice)
        XCTAssertEqual(s.state.pendingNoticeQuestion, original)
        for line in ["It doesn't say to boil.", "They said never ever boil it."] {
            XCTAssertEqual(reply(try s.send(line)).askedFor, "notice", line)
            XCTAssertNil(s.state.waterNotice)
        }
        _ = try s.send("It says to boil the tap water.")
        XCTAssertEqual(s.state.waterNotice, .boil)
    }

    /// "Not sure" decides nothing: the original question waits for the kind, and the next
    /// plain answer is applied to it.
    func testNotSureKeepsTheOriginalQuestionOpen() throws {
        let s = try session()
        let asked = reply(try s.send("We got a water notice. Can I brush my teeth?"))
        XCTAssertEqual(asked.askedFor, "notice")
        XCTAssertTrue(asked.text.hasSuffix(WaterNotice.question))
        XCTAssertEqual(s.state.pendingNoticeQuestion, "We got a water notice. Can I brush my teeth?")

        let unsure = reply(try s.send(WaterNotice.notSure))
        XCTAssertEqual(unsure.askedFor, "notice", "asked again")
        XCTAssertTrue(unsure.text.contains("Do not use advisory"), "what each notice means, from its entry")
        XCTAssertNil(s.state.waterNotice)
        XCTAssertTrue(s.state.waterNoticeUnsure)
        XCTAssertEqual(s.state.pendingNoticeQuestion, "We got a water notice. Can I brush my teeth?", "still the first question")

        let answer = reply(try s.send("Do not drink"))
        XCTAssertEqual(answer.citations, ["water.advisory.do-not-drink@v1"])
        XCTAssertEqual(s.state.waterNotice, .doNotDrink)
        XCTAssertNil(s.state.pendingNoticeQuestion)
    }

    /// The notice is its own event, so a reopened log (or the Mac) sees it.
    func testTheNoticeIsSavedAndSurvivesAReopen() throws {
        let s = try session()
        _ = try s.send("They told us to boil the water. What about the dog's bowl?")
        let saved = s.events.compactMap { e -> WaterNoticeChange? in
            if case let .waterNotice(n) = e.payload { return n } else { return nil }
        }
        XCTAssertEqual(saved.map(\.state), [.boil])
        XCTAssertEqual(saved.first?.title, "Water notice: Boil water")
        let reopened = try session()
        XCTAssertEqual(reopened.state.waterNotice, .boil)
        _ = try reopened.send("The boil notice was lifted.")
        XCTAssertNil(reopened.state.waterNotice)
    }

    /// Spoken, the question offers exactly the four buttons.
    func testTheQuestionIsReadWithItsAnswers() throws {
        let s = try session()
        let asked = reply(try s.send("The city sent a water alert. Can the dog drink from the tap?"))
        let spoken = SpeechText.make(for: asked, pack: s.pack)
        XCTAssertTrue(spoken.hasSuffix("Answer: Boil water, Do not drink, Do not use, or Not sure."), spoken)
    }
}
