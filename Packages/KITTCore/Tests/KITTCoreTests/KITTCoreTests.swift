import XCTest
@testable import KITTCore

final class WaterPlanTests: XCTestCase {
    func testBriefNumbers() {
        var plan = WaterPlan(people: People(3), days: Days(3))
        XCTAssertEqual(plan.required, USGallons(9))
        plan.stored = USGallons(4)
        XCTAssertEqual(plan.shortfall, USGallons(5))
        plan.days = Days(5)
        XCTAssertEqual(plan.required, USGallons(15))
        XCTAssertEqual(plan.shortfall, USGallons(11))
    }

    func testSurplusAndFormatting() {
        let plan = WaterPlan(people: People(1), days: Days(2), stored: USGallons(2.5))
        XCTAssertEqual(plan.shortfall, .zero)
        XCTAssertEqual(plan.surplus, USGallons(0.5))
        XCTAssertEqual(USGallons(2.5).label, "2.5 gal")
        XCTAssertEqual(USGallons(9).longLabel, "9 US gallons")
        XCTAssertEqual(plan.workingLine, "1 person × 2 days × 1 gal per person per day = 2 gal")
    }
}

final class IntentParserTests: XCTestCase {
    func facts(_ s: String) -> [HouseholdFact.Key: Double] {
        Dictionary(IntentParser.parse(s).facts.map { ($0.key, $0.value) }, uniquingKeysWith: { _, b in b })
    }

    func testDemoSentences() {
        XCTAssertEqual(facts("How much water should we store for three days?"), [.planDays: 3])
        XCTAssertEqual(facts("We already have four gallons."), [.storedWater: 4])
        XCTAssertTrue(IntentParser.parse("How much more do we need?").asksRemaining)
        XCTAssertEqual(facts("Change the plan to five days"), [.planDays: 5])
    }

    func testVariants() {
        XCTAssertEqual(facts("We're a household of 4"), [.people: 4])
        XCTAssertEqual(facts("there are five of us"), [.people: 5])
        XCTAssertEqual(facts("we've got two and a half gallons"), [.storedWater: 2.5])
        XCTAssertEqual(facts("6 gallons in the garage"), [.storedWater: 6])
        XCTAssertEqual(facts("make it 7 days"), [.planDays: 7])
        XCTAssertEqual(facts("do we have 4 gallons?"), [:], "a question is not a fact")
        XCTAssertEqual(facts("we are 3 days out"), [:])
    }

    /// "For two days" can be the plan or how long something lasted. Without a planning
    /// word it is tentative: it counts only in a water question or a bare follow-up.
    func testDurationsWithoutAPlanAreTentative() {
        let thirst = IntentParser.parse("Nobody has had anything to drink for two days. How long can we go?")
        XCTAssertEqual(thirst.tentative, [.planDays])
        XCTAssertTrue(thirst.declaredFacts.isEmpty)
        XCTAssertFalse(thirst.onlyFacts)
        XCTAssertFalse(IntentParser.parse("Is it bad to drink nothing for two days?").onlyFacts)
        XCTAssertEqual(IntentParser.parse("Two people have been sick for three days.").tentative, [.people, .planDays])
        XCTAssertEqual(IntentParser.parse("How much water should we store for three people for five days?").tentative, [])
        let followUp = IntentParser.parse("What about for 5 days?")
        XCTAssertEqual(followUp.tentative, [.planDays])
        XCTAssertTrue(followUp.onlyFacts)
        XCTAssertTrue(IntentParser.parse("And if the outage lasts for 4 days?").onlyFacts)
        let question = IntentParser.parse("How much water do we need for 3 people for 5 days?")
        XCTAssertTrue(question.asksWater)
        XCTAssertEqual(question.tentative, [.people, .planDays])
        XCTAssertEqual(IntentParser.parse("The outage has lasted a while; plan for 4 days.").declaredFacts.map(\.value), [4])
    }
}

final class EventLogTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitt-\(UUID())")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSurvivesReopenWithParentsAndSequence() throws {
        let url = dir.appendingPathComponent("events.jsonl")
        let watch = DeviceID("watch-test")
        let convo = UUID()
        do {
            let log = try EventLog(fileURL: url, device: watch)
            try log.append(.userMessage(text: "Hello KITT", inputMethod: .typed), conversation: convo)
            try log.append(.assistantMessage(AssistantMessage(text: "Hi", origin: .model)), conversation: convo)
        }
        let reopened = try EventLog(fileURL: url, device: watch)
        let ev = reopened.events(in: convo)
        XCTAssertEqual(ev.count, 2)
        XCTAssertEqual(ev[1].parentID, ev[0].id)
        XCTAssertEqual(ev.map(\.localSequence), [1, 2])
        let third = try reopened.append(.userMessage(text: "again", inputMethod: .typed), conversation: convo)
        XCTAssertEqual(third.localSequence, 3)
        XCTAssertEqual(third.parentID, ev[1].id)
    }

    func testTornLastLineIsSkipped() throws {
        let url = dir.appendingPathComponent("events.jsonl")
        let log = try EventLog(fileURL: url, device: DeviceID("w"))
        try log.append(.userMessage(text: "kept", inputMethod: .typed), conversation: UUID())
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd(); try h.write(contentsOf: Data("{\"id\":\"trunc".utf8)); try h.close()
        let reopened = try EventLog(fileURL: url, device: DeviceID("w"))
        XCTAssertEqual(reopened.all.count, 1)
        XCTAssertEqual(reopened.skippedLines, 1)
    }

    func testFiveDuplicateDeliveriesYieldOneEvent() throws {
        let mac = try EventLog(fileURL: dir.appendingPathComponent("mac.jsonl"), device: DeviceID("mac"))
        let remote = ConversationEvent(conversationID: UUID(), parentID: nil, device: DeviceID("watch"),
                                       localSequence: 1, payload: .userMessage(text: "x", inputMethod: .dictated))
        var added = 0
        for _ in 0..<5 { added += try mac.ingest([remote]).count }
        XCTAssertEqual(added, 1)
        XCTAssertEqual(mac.all.count, 1)
        let reopened = try EventLog(fileURL: dir.appendingPathComponent("mac.jsonl"), device: DeviceID("mac"))
        XCTAssertEqual(reopened.all.count, 1)
    }

    /// A condition written before `basis` existed still loads.
    func testOlderConditionStillDecodes() throws {
        let json = #"{"entryID":"water.contamination.fuel","state":"raised","sourceText":"gas smell"}"#
        let c = try JSONDecoder().decode(ConditionChange.self, from: Data(json.utf8))
        XCTAssertNil(c.basis)
        XCTAssertEqual(c.state, .raised)
    }

    /// An event written by the first build (before suggestions, offersModel, ...) still loads.
    func testOlderAssistantMessageStillDecodes() throws {
        let json = #"{"text":"Hi","origin":"model","citations":[],"interrupted":false}"#
        let m = try JSONDecoder().decode(AssistantMessage.self, from: Data(json.utf8))
        XCTAssertEqual(m.suggestions, [])
        XCTAssertFalse(m.offersModel)
        XCTAssertEqual(m.unsupportedNumbers, [])
        XCTAssertNil(m.suggestedHazard)
    }
}

final class PackTests: XCTestCase {
    func testBundledPackHasNoStructuralProblems() throws {
        let pack = try ContentPack.bundled()
        XCTAssertEqual(pack.problems(), [])
        XCTAssertGreaterThanOrEqual(pack.entries.count, 10)
        XCTAssertEqual(pack.topics.first, "Water")
    }

    func testSourceCorrectionsReachBothWatchAndModel() throws {
        let pack = try ContentPack.bundled()
        let checks = [
            ("water.rationing", ["unless local authorities"]),
            ("health.dehydration", ["alert and can swallow", "thirsty", "dark urine", "tired", "dizzy"]),
            ("health.heat.illness", ["Call 911", "103°F", "hot, red skin"])
        ]
        for (id, phrases) in checks {
            let entry = try XCTUnwrap(pack.entries.first { $0.id == id })
            for phrase in phrases {
                XCTAssertTrue(entry.shortAnswer.contains(phrase), id + ": " + phrase)
                XCTAssertTrue(entry.modelPassage.contains(phrase), id + ": " + phrase)
            }
        }
        let dehydration = try XCTUnwrap(pack.entries.first { $0.id == "health.dehydration" })
        XCTAssertEqual(dehydration.sources.map(\.publisher),
                       ["MedlinePlus (National Library of Medicine)", "American Red Cross"])
    }

    /// Every tappable question must find its own entry, or the topic buttons would lie.
    func testEveryCanonicalQuestionFindsItsOwnEntry() throws {
        let pack = try ContentPack.bundled()
        let search = GuideSearch(pack: pack)
        for e in pack.liveEntries {
            XCTAssertEqual(search.rank(e.canonicalQuestion).first?.entry.id, e.id, e.canonicalQuestion)
        }
    }

    func testNoReliableMatchIsARealOutcome() throws {
        let search = GuideSearch(pack: try ContentPack.bundled())
        XCTAssertEqual(search.retrieve("best hiking boots"), .none)
        XCTAssertNil(search.retrieve("How do I treat a burn?").confident, "one shared word is not a match")
        XCTAssertNil(search.retrieve("How do I charge my phone?").confident)
    }

    func testHazardTriggersNeedEverySlot() throws {
        let search = GuideSearch(pack: try ContentPack.bundled())
        func raised(_ s: String) -> [String] { search.hazardsRaised(by: s).map(\.id) }
        XCTAssertEqual(raised("Our water smells like gasoline after a flood"), ["water.contamination.fuel"])
        XCTAssertEqual(raised("the tap water tastes like gas"), ["water.contamination.fuel"])
        XCTAssertEqual(raised("kerosene lamp in the bedroom ok?"), ["power.fuel-burning.co"])
        XCTAssertEqual(raised("Can I use the gas stove in the kitchen to cook dinner?"), [])
        XCTAssertEqual(raised("We put a few drops of bleach in the water jug like the guide says"), [])
        XCTAssertEqual(raised("can I run the generator in the garage"), ["power.fuel-burning.co"])
        XCTAssertEqual(raised("Could we bring the charcoal grill into the living room for heat?"), ["power.fuel-burning.co"])
        XCTAssertEqual(raised("Can I use the barbecue in the den if the power stays out?"), ["power.fuel-burning.co"])
        XCTAssertEqual(raised("Water from the kitchen faucet smells like paint thinner."), ["water.contamination.fuel"])
        // An unexplained smell or taste counts, whatever it is compared to...
        XCTAssertEqual(raised("the water smells like nail polish remover"), ["water.contamination.fuel"])
        // ...except the ones a slot starting with "!" rules out.
        XCTAssertEqual(raised("my tap water smells like chlorine"), [])
        // Mentioning the words is not describing the hazard.
        XCTAssertEqual(raised("We stored gasoline for the mower"), [])
        XCTAssertEqual(raised("How much water and fuel should we store?"), [])
        XCTAssertEqual(raised("My gas water heater smells"), [])
        XCTAssertEqual(raised("We're under a boil-water notice"), [])
        XCTAssertEqual(raised("Where can we run a generator or grill?"), [])
    }
}

final class SessionTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitt-\(UUID())")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func makeSession(file: String = "events.jsonl") throws -> KITTSession {
        let log = try EventLog(fileURL: dir.appendingPathComponent(file), device: DeviceID("watch"))
        return KITTSession(log: log, pack: try ContentPack.bundled())
    }

    func answered(_ o: TurnOutcome, file: StaticString = #filePath, line: UInt = #line) -> AssistantMessage {
        guard case let .answered(m) = o else {
            XCTFail("expected an app answer, got \(o)", file: file, line: line)
            return AssistantMessage(text: "", origin: .app)
        }
        return m
    }

    /// The brief's first end-to-end demo, minus the transport.
    func testFirstDemo() throws {
        let s = try makeSession()
        try s.setFact(.people, 3)

        let a1 = answered(try s.send("How much water should we store for three days?", via: .dictated))
        XCTAssertTrue(a1.text.hasPrefix("Plan for 9 US gallons."), a1.text)
        XCTAssertTrue(a1.text.contains("3 people × 3 days × 1 gal per person per day = 9 gal"))
        XCTAssertEqual(a1.citations, ["water.storage.baseline@v2"])

        let a2 = answered(try s.send("We already have four gallons."))
        XCTAssertTrue(a2.text.hasPrefix("You need 5 US gallons more."), a2.text)

        // "Back at the Mac": reopen the same record from disk; nothing is re-asked.
        let resumed = try makeSession()
        XCTAssertEqual(resumed.conversationID, s.conversationID)
        let a3 = answered(try resumed.send("How much more do we need?"))
        XCTAssertTrue(a3.text.hasPrefix("You need 5 US gallons more."), a3.text)

        let a4 = answered(try resumed.send("Change the plan to five days"))
        XCTAssertTrue(a4.text.hasPrefix("You need 11 US gallons more."), a4.text)
        XCTAssertTrue(a4.text.contains("15 gal needed − 4 gal stored = 11 gal more"))

        // Exact user wording is preserved.
        let userTexts = resumed.events.compactMap { e -> String? in
            if case let .userMessage(t, _) = e.payload { return t } else { return nil }
        }
        XCTAssertEqual(userTexts.first, "How much water should we store for three days?")
    }

    func testAsksForOneMissingFact() throws {
        let s = try makeSession()
        let a = answered(try s.send("How much water should we store?"))
        XCTAssertEqual(a.origin, .app)
        XCTAssertEqual(a.needsFact, .people)
        let b = answered(try s.send("We're a family of 4"))
        XCTAssertTrue(b.text.hasPrefix("Plan for 12 US gallons."), b.text)
    }

    /// Guide-and-speech trial acceptance: a question about going without water must not
    /// change the household plan. The first reply is about dehydration; the next
    /// conversation, and a replay of the log, still plan 3 people × 7 days = 21 gallons.
    func testADurationInAnotherQuestionDoesNotChangeThePlan() throws {
        let s = try makeSession()
        XCTAssertTrue(answered(try s.send("We're a family of three.")).text.hasPrefix("Noted"))
        XCTAssertTrue(answered(try s.send("Plan for 7 days.")).text.hasPrefix("Noted"))

        s.startNewConversation()
        let thirst = answered(try s.send("Nobody has had anything to drink for two days. How long can we go?"))
        XCTAssertEqual(thirst.citations, ["health.dehydration@v3"], thirst.text)
        XCTAssertTrue(thirst.text.hasPrefix("Replace lost fluids now"), thirst.text)
        XCTAssertTrue(thirst.suggestions.contains("water.without"), "the curiosity answer stays a tap away")
        XCTAssertEqual(s.household.planDays, Days(7))
        XCTAssertFalse(s.events.contains { if case .householdFact = $0.payload { return true } else { return false } })

        s.startNewConversation()
        let plan = answered(try s.send("How much water should we store?"))
        XCTAssertTrue(plan.text.hasPrefix("Plan for 21 US gallons."), plan.text)

        let replayed = try makeSession()
        XCTAssertEqual(replayed.household.planDays, Days(7))
        replayed.startNewConversation()
        XCTAssertTrue(answered(try replayed.send("How much water should we store?")).text.hasPrefix("Plan for 21 US gallons."))
    }

    /// Stop-and-guide trial, priority 1: a report of water already drunk changes neither
    /// the plan nor the water on hand, and the plan survives a replay of the log.
    func testAConsumedAmountDoesNotChangeThePlan() throws {
        XCTAssertTrue(IntentParser.parse("I drank two gallons over the last three days").facts.isEmpty)
        XCTAssertTrue(IntentParser.parse("We went through 4 gallons already.").facts.isEmpty)
        XCTAssertEqual(IntentParser.parse("It has to last 5 days.").declaredFacts.map(\.value), [5])

        let s = try makeSession()
        try s.setFact(.people, 3)
        try s.setFact(.planDays, 7)
        s.startNewConversation()
        let report = answered(try s.send("I drank two gallons over the last three days"))
        XCTAssertFalse(report.text.hasPrefix("Noted"), report.text)
        XCTAssertEqual(s.household.planDays, Days(7))
        XCTAssertNil(s.household.storedWater)

        let replayed = try makeSession()
        replayed.startNewConversation()
        XCTAssertTrue(answered(try replayed.send("How much water should we store?")).text.hasPrefix("Plan for 21 US gallons."))

        // The control: a follow-up to a water answer that only changes the length.
        replayed.startNewConversation()
        _ = try replayed.send("How much water do we need?")
        XCTAssertTrue(answered(try replayed.send("What about for five days?")).text.hasPrefix("Plan for 15 US gallons."))
        XCTAssertEqual(replayed.household.planDays, Days(5))
    }

    /// Priority 2: an urgent entry is shown first only on a reported sign, not on a topic
    /// word. The real warnings stay immediate.
    func testUrgentAnswersNeedASign() throws {
        let s = try makeSession()
        let milk = answered(try s.send("The fridge is warm after the blackout. Is the milk OK?"))
        XCTAssertEqual(milk.citations, ["food.outage.cold@v2"], milk.text)

        s.startNewConversation()
        let noGas = answered(try s.send("We don't smell gas. Which flashlight should we keep near the breaker box?"))
        XCTAssertFalse(noGas.text.contains("Leave the area now"), noGas.text)
        XCTAssertFalse(noGas.citations.contains("gas.leak@v2"))

        s.startNewConversation()
        let packing = answered(try s.send("What should I pack before a heat wave? Everyone here feels fine."))
        XCTAssertFalse(packing.text.contains("Call 911 now if you suspect heat stroke."), packing.text)
        XCTAssertEqual(packing.citations.isEmpty ? packing.suggestions.first : packing.citations.first.map { String($0.split(separator: "@")[0]) },
                       "heat.prepare", "preparedness is the answer or the first choice")
        s.startNewConversation()
        XCTAssertEqual(answered(try s.send("What should I pack before a heat wave?")).citations, ["heat.prepare@v1"])

        s.startNewConversation()
        let gas = answered(try s.send("I smell gas in the kitchen."))
        XCTAssertTrue(gas.text.hasPrefix("Leave the area now."), gas.text)

        s.startNewConversation()
        let heat = answered(try s.send("Grandpa got confused while mowing in the heat and his skin feels hot."))
        XCTAssertEqual(heat.citations, ["health.heat.illness@v3"], heat.text)
        XCTAssertTrue(heat.text.hasPrefix("Call 911 now if you suspect heat stroke."))
        XCTAssertFalse(heat.suggestions.contains("health.cold.hypothermia") || heat.suggestions.contains("health.cold.frostbite"),
                       "no cold buttons for a heat case: \(heat.suggestions)")
    }

    /// Priority 3: the direct answers.
    func testDehydrationAndFrozenInsulinAnswerDirectly() throws {
        let s = try makeSession()
        try s.setFact(.people, 3)
        try s.setFact(.planDays, 7)
        s.startNewConversation()
        let signs = answered(try s.send("Our water supply was cut off two days ago. What are the signs of dehydration?"))
        XCTAssertEqual(signs.citations, ["health.dehydration@v3"], signs.text)

        s.startNewConversation()
        XCTAssertTrue(answered(try s.send("How much water do we need?")).text.hasPrefix("Plan for 21 US gallons."))
        let nobody = answered(try s.send("Nobody has had water to drink for two days."))
        XCTAssertEqual(nobody.citations, ["health.dehydration@v3"], nobody.text)
        XCTAssertEqual(s.household.planDays, Days(7))

        s.startNewConversation()
        let vial = answered(try s.send("My insulin vial froze overnight. Is it usable?"))
        XCTAssertEqual(vial.citations, ["health.insulin.outage@v3"], vial.text)
        XCTAssertTrue(vial.text.hasPrefix("Do not use insulin that has frozen.\n"))
    }

    /// Planning follow-ups still change the plan.
    func testPlanningFollowUpsStillChangeThePlan() throws {
        let s = try makeSession()
        try s.setFact(.people, 3)
        XCTAssertTrue(answered(try s.send("How much water should we store?")).text.hasPrefix("Plan for 9 US gallons."))
        XCTAssertTrue(answered(try s.send("What about for 5 days?")).text.hasPrefix("Plan for 15 US gallons."))
        XCTAssertTrue(answered(try s.send("We have 4 gallons stored.")).text.hasPrefix("You need 11 US gallons more."))
        XCTAssertEqual(s.household.planDays, Days(5))
        // A water question states its own numbers, planning word or not.
        XCTAssertTrue(answered(try s.send("How much water do we need for 2 people for 4 days?")).text.hasPrefix("You need 4 US gallons more."))
        XCTAssertTrue(answered(try s.send("Make it 5 days.")).text.hasPrefix("You need 6 US gallons more."))
        // A question about something else, right after the water answer, does not.
        _ = try s.send("Is it bad to drink nothing for two days?")
        XCTAssertEqual(s.household.planDays, Days(5))
        // Inside the water conversation, a message that belongs to another entry still
        // leaves the plan alone.
        let other = answered(try s.send("The power has been out for two days. What should we do?"))
        XCTAssertFalse(other.citations.contains("water.storage.baseline@v2"), other.text)
        XCTAssertEqual(s.household.planDays, Days(5))
    }

    /// Guide-and-speech trial: what each reply says first.
    func testUrgentRepliesLeadWithTheAction() throws {
        let s = try makeSession()
        let frozen = answered(try s.send("My insulin froze in the cooler. Can I still use it?"))
        XCTAssertTrue(frozen.text.hasPrefix("Do not use insulin that has frozen.\n"), frozen.text)
        s.startNewConversation()
        let warm = answered(try s.send("The refrigerator lost power. How long is my insulin good?"))
        XCTAssertTrue(warm.text.hasPrefix("Check your insulin's label."), warm.text)
        s.startNewConversation()
        let heat = answered(try s.send("After working outside in the heat, my dad is confused and his skin is hot."))
        XCTAssertEqual(heat.citations, ["health.heat.illness@v3"], heat.text)
        XCTAssertTrue(heat.text.hasPrefix("Call 911 now if you suspect heat stroke."))
        XCTAssertFalse(heat.suggestions.contains("health.cold.hypothermia"))
        s.startNewConversation()
        let gas = answered(try s.send("The kitchen smells like rotten eggs and I hear a hiss by the stove."))
        XCTAssertTrue(gas.text.hasPrefix("Leave the area now."), gas.text)
        s.startNewConversation()
        let cold = answered(try s.send("My fingertips are white and numb after being out in the cold."))
        XCTAssertEqual(cold.citations, ["health.cold.frostbite@v2"], cold.text)
        XCTAssertTrue(cold.text.hasPrefix("Get medical care as soon as you can."))
        s.startNewConversation()
        let curious = answered(try s.send("How long can you live without drinking water?"))
        XCTAssertEqual(curious.citations, ["water.without@v2"], curious.text)
    }

    /// Read-aloud says what the buttons say, so a reply can be answered without looking.
    func testSpeechReadsTheAnswerButtonsAndSkipsTheArithmetic() throws {
        let s = try makeSession()
        let pack = s.pack
        let asked = answered(try s.send("The generator is in the basement."))
        let spokenQuestion = SpeechText.make(for: asked, pack: pack, activeHazards: s.state.activeHazards)
        XCTAssertTrue(spokenQuestion.hasSuffix("Is it running there, or are you planning to run it there? "
                                               + "Answer: This applies to us, Not in use, or Not sure."), spokenQuestion)
        XCTAssertFalse(spokenQuestion.contains("Related:"), "the question's answers come last, alone")

        let unsure = answered(try s.send("I'm not sure."))
        XCTAssertTrue(SpeechText.make(for: unsure, pack: pack, activeHazards: s.state.activeHazards)
            .hasSuffix("Answer: This applies to us, Not in use, or Not sure."))

        let yes = answered(try s.send("Yes, it's running."))
        let flagged = SpeechText.make(for: yes, pack: pack, activeHazards: s.state.activeHazards)
        XCTAssertFalse(flagged.contains("This applies to us"), "already flagged: no button, nothing to read")

        s.startNewConversation()
        try s.setFact(.people, 3)
        let plan = answered(try s.send("How much water should we store?"))
        let spokenPlan = SpeechText.make(for: plan, pack: pack)
        XCTAssertTrue(spokenPlan.hasPrefix("Plan for 9 US gallons. 3 days is the default"), spokenPlan)
        XCTAssertFalse(spokenPlan.contains("×"))
        XCTAssertTrue(spokenPlan.hasSuffix("The calculation is on screen."), spokenPlan)
        XCTAssertFalse(spokenPlan.contains("Related"), "related topics sit behind a button; not read")

        s.startNewConversation()
        let pick = answered(try s.send("What are the best hiking boots?"))
        XCTAssertEqual(SpeechText.make(for: pick, pack: pack),
                       "The guide doesn't cover that yet. Browse the topics, or ask the model for an unverified answer.")
        let model = AssistantMessage(text: "Sturdy ones.", origin: .model)
        XCTAssertEqual(SpeechText.make(for: model, pack: pack), "Unverified. Sturdy ones.")
    }

    /// The watch's answer screen keeps what the user acts on; Show calculation keeps the
    /// arithmetic. A precaution's alternatives are offered as what the user may have meant.
    func testAnswerScreenLayout() throws {
        let s = try makeSession()
        try s.setFact(.people, 3)
        let plan = answered(try s.send("How much water should we store for a heat wave?"))
        let layout = WaterAnswerLayout(text: plan.text)
        XCTAssertEqual(layout.headline, "Plan for 9 US gallons.")
        XCTAssertEqual(layout.details, ["3 days is the default; tell me if your plan is longer.",
                                        "In very hot weather, water needs can double."])
        XCTAssertEqual(layout.calculation, ["3 people × 3 days × 1 gal per person per day = 9 gal",
                                            "Planning baseline from Ready.gov (FEMA)."])
        XCTAssertFalse(plan.isPrecaution)

        let stored = WaterAnswerLayout(text: answered(try s.send("We have 4 gallons stored.")).text)
        XCTAssertEqual(stored.headline, "You need 5 US gallons more.")
        XCTAssertTrue(stored.calculation.contains("9 gal needed − 4 gal stored = 5 gal more"), "\(stored.calculation)")

        s.startNewConversation()
        let urgent = answered(try s.send("Nobody has had anything to drink for two days. How long can we go?"))
        XCTAssertTrue(urgent.isPrecaution)
        XCTAssertTrue(SpeechText.make(for: urgent, pack: s.pack)
            .hasSuffix("Or did you mean: How long a person can go without water, Rationing drinking water, or Making water safe to drink?"))
    }

    /// Speech acceptance, the parts that do not need the watch: an urgent reply's first
    /// instruction stands alone (the watch taps the wrist with it), then a pause; a water
    /// answer reads the total, pauses, and says the calculation is on screen; spoken
    /// choices are only buttons on the answer screen; and numbers and symbols are said
    /// the way a person would say them.
    func testSpokenRepliesPauseAndSayWhatIsOnScreen() throws {
        let s = try makeSession()
        let heat = answered(try s.send("After working outside in the heat, my dad is confused and his skin is hot."))
        let urgent = SpeechText.reply(for: heat, pack: s.pack)
        XCTAssertTrue(urgent.urgent)
        XCTAssertEqual(urgent.segments.first, SpokenSegment("Call nine one one now if you suspect heat stroke.", pauseAfter: 0.6))
        XCTAssertTrue(urgent.segments[1].text.contains("103 degrees Fahrenheit or higher"), urgent.segments[1].text)
        XCTAssertFalse(urgent.text.contains("(") || urgent.text.contains("°") || urgent.text.contains("911"), urgent.text)

        s.startNewConversation()
        let gas = SpeechText.reply(for: answered(try s.send("I smell gas in the kitchen.")), pack: s.pack)
        XCTAssertTrue(gas.urgent)
        XCTAssertEqual(gas.segments.first?.text, "Leave the area now.")

        s.startNewConversation()
        try s.setFact(.people, 3)
        let plan = SpeechText.reply(for: answered(try s.send("How much water should we store for a heat wave?")), pack: s.pack)
        XCTAssertFalse(plan.urgent)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0], SpokenSegment("Plan for 9 US gallons. 3 days is the default; tell me if your plan is longer. "
                                                       + "In very hot weather, water needs can double.", pauseAfter: 0.5))
        XCTAssertEqual(plan.segments[1], SpokenSegment("The calculation is on screen."))

        s.startNewConversation()
        let asked = SpeechText.reply(for: answered(try s.send("The generator is in the garage.")), pack: s.pack)
        XCTAssertTrue(asked.urgent)
        XCTAssertEqual(asked.segments.last, SpokenSegment("Answer: This applies to us, Not in use, or Not sure."))
        XCTAssertEqual(asked.segments[asked.segments.count - 2].pauseAfter, 0.5)

        s.startNewConversation()
        let guide = SpeechText.reply(for: answered(try s.send("How long does food stay safe without power?")), pack: s.pack)
        XCTAssertEqual(guide.segments.count, 1, "a guide answer's related topics are behind a button: \(guide.transcript)")

        s.startNewConversation()
        let pick = SpeechText.reply(for: answered(try s.send("How do I keep the house warm until electricity comes back?")), pack: s.pack)
        XCTAssertTrue(pick.segments.last!.text.hasSuffix("."), pick.transcript)
        XCTAssertEqual(pick.segments.count, 2, "the choice list is its own segment after a pause: \(pick.transcript)")

        let ask = try makeSession(file: "ask.jsonl")
        let household = SpeechText.reply(for: answered(try ask.send("How much water should we store?")), pack: s.pack)
        XCTAssertEqual(household.segments.last?.text, "Tap Set household.")
    }

    func testPronunciation() {
        XCTAssertEqual(SpeechText.spoken("Call 911 now."), "Call nine one one now.")
        XCTAssertEqual(SpeechText.spoken("between 59°F and 86°F for up to 28 days"),
                       "between 59 and 86 degrees Fahrenheit for up to 28 days")
        XCTAssertEqual(SpeechText.spoken("Keep it at 40°F or below."), "Keep it at 40 degrees Fahrenheit or below.")
        XCTAssertEqual(SpeechText.spoken("pump insulin above 98.6°F."), "pump insulin above 98.6 degrees Fahrenheit.")
        XCTAssertEqual(SpeechText.spoken("hot, red skin (dry or damp), or a temperature"), "hot, red skin, dry or damp, or a temperature")
        XCTAssertEqual(SpeechText.spoken("boil for 1 minute (3 minutes above 6,500 feet)."), "boil for 1 minute, 3 minutes above 6,500 feet.")
        XCTAssertEqual(SpeechText.spoken("Planning baseline from Ready.gov (FEMA)."), "Planning baseline from Ready dot gov, FEMA.")
        XCTAssertEqual(SpeechText.spoken("Sweat 1 to 1.5 liters an hour."), "Sweat 1 to 1.5 liters an hour.")
    }

    func testBleachQuestionIsNotSentToTheWaterCalculator() throws {
        let s = try makeSession()
        try s.setFact(.people, 3)
        let a = answered(try s.send("How much bleach do I add to a gallon of water?"))
        XCTAssertEqual(a.citations, ["water.treat.emergency@v2"])
        XCTAssertTrue(a.text.contains("8 drops per gallon"))
    }

    /// The brief's content acceptance example.
    func testFuelContaminationStaysInForce() throws {
        let s = try makeSession()
        let first = answered(try s.send("Our water smells like gasoline after a flood"))
        XCTAssertEqual(first.citations, ["water.contamination.fuel@v4"])
        XCTAssertTrue(first.text.contains("Boiling and disinfecting will not make water safe"))
        XCTAssertEqual(s.state.activeHazards, ["water.contamination.fuel"])

        let followUp = answered(try s.send("would boiling help?"))
        XCTAssertEqual(followUp.origin, .guide, "a hazard follow-up never reaches the model")
        XCTAssertTrue(followUp.text.hasPrefix("Still applies: Possible fuel or chemicals in the water."), followUp.text)
        XCTAssertTrue(followUp.text.contains("Boiling and disinfecting will not"))

        // A follow-up with none of the listed words, that only points back, gets the warning too.
        let brita = answered(try s.send("What if I run it through the Brita?"))
        XCTAssertEqual(brita.citations, ["water.contamination.fuel@v4"])
        let vague = answered(try s.send("so what do we do about it"))
        XCTAssertEqual(vague.citations, ["water.contamination.fuel@v4"])

        // Tapping the boil-water entry must not show boiling steps while the hazard is active.
        let tapped = answered(try s.ask(entryID: "water.advisory.boil"))
        XCTAssertEqual(tapped.citations, ["water.contamination.fuel@v4"])

        // An unrelated question is answered normally.
        let generator = answered(try s.send("Where can we run a generator or grill?"))
        XCTAssertEqual(generator.citations, ["power.fuel-burning.co@v6"])

        // The hazard survives a restart, and the user can clear it.
        let reopened = try makeSession()
        XCTAssertEqual(reopened.state.activeHazards, ["water.contamination.fuel"])
        try reopened.clearHazard("water.contamination.fuel")
        XCTAssertEqual(reopened.state.activeHazards, [])
        let after = answered(try reopened.ask(entryID: "water.advisory.boil"))
        XCTAssertEqual(after.citations, ["water.advisory.boil@v2"])
    }

    /// Unsure which entry is meant, but the question names a hazard's subject and one of
    /// its keywords: the warning is shown, not offered as a button, and not flagged.
    func testSuspectedHazardIsShownButNotFlagged() throws {
        let s = try makeSession()
        let a = answered(try s.send("Where's the assembly manual for the barbecue?"))
        XCTAssertEqual(a.citations, ["power.fuel-burning.co@v6"])
        XCTAssertTrue(a.text.hasPrefix("Never run a generator"))
        XCTAssertEqual(a.suggestedHazard, "power.fuel-burning.co")
        XCTAssertEqual(s.state.activeHazards, [], "a guess must not change how later turns are answered")
        XCTAssertEqual(s.state.pendingHazard, "power.fuel-burning.co")

        // The next, unrelated question is answered normally and clears the pending warning.
        try s.setFact(.people, 3)
        let water = answered(try s.send("How much water should we store for three days?"))
        XCTAssertTrue(water.text.hasPrefix("Plan for 9 US gallons."), water.text)
        XCTAssertEqual(s.state.activeHazards, [])
        XCTAssertNil(s.state.pendingHazard)

        // A keyword without the subject is not enough: "fuel" here is not about water.
        // A gas appliance that smells is the gas leak entry, which is not a hazard flag.
        let t = try makeSession(file: "other.jsonl")
        let c = answered(try t.send("My gas water heater smells"))
        XCTAssertEqual(c.citations, ["gas.leak@v2"])
        XCTAssertEqual(t.state.activeHazards, [])
    }

    /// The acceptance pair from the fourth trial: what the user puts in the garage, and
    /// what they mean to do there, decides the flag.
    /// Acceptance test from the fifth trial: three follow-ups to the same opening. An
    /// action already under way flags; "it" that refers to something else in the same
    /// message does not borrow the generator; a use the user rules out does not flag.
    func testBasementTrio() throws {
        let opening = "I found the manual for our generator."
        func run(_ followUp: String, file: String) throws -> KITTSession {
            let s = try makeSession(file: file)
            let first = answered(try s.send(opening))
            XCTAssertEqual(first.suggestedHazard, "power.fuel-burning.co")
            XCTAssertEqual(s.state.activeHazards, [])
            _ = answered(try s.send(followUp))
            return s
        }
        let underway = try run("It's running in the basement right now.", file: "a.jsonl")
        XCTAssertEqual(underway.state.activeHazards, ["power.fuel-burning.co"])
        let dryer = try run("The dryer is in the basement. Can I run it tonight?", file: "b.jsonl")
        XCTAssertEqual(dryer.state.activeHazards, [])
        let ruledOut = try run("The generator is in the basement. I won't start it down there.", file: "c.jsonl")
        XCTAssertEqual(ruledOut.state.activeHazards, [])
    }

    /// Acceptance pair from the sixth trial. A sentence break can keep the subject ("Quick
    /// update. It's running...") and one sentence can bring a new one ("run the dryer").
    func testSubjectAcrossSentencesAndWithinOne() throws {
        let keep = try makeSession(file: "keep.jsonl")
        _ = answered(try keep.send("I found the generator manual."))
        _ = answered(try keep.send("Quick update. It's running downstairs in the basement."))
        XCTAssertEqual(keep.state.activeHazards, ["power.fuel-burning.co"])

        let switched = try makeSession(file: "switch.jsonl")
        _ = answered(try switched.send("I found the generator manual."))
        _ = answered(try switched.send("Can I run the dryer in the basement if it is full?"))
        XCTAssertEqual(switched.state.activeHazards, [])
    }

    /// A device in a room says where it is, not what it is doing: warn, ask, don't flag.
    func testLocatedDeviceWarnsAndAsks() throws {
        let s = try makeSession()
        let a = answered(try s.send("The generator is in the basement."))
        XCTAssertTrue(a.text.hasPrefix("Never run a generator"))
        XCTAssertTrue(a.text.hasSuffix("Is it running there, or are you planning to run it there?"))
        XCTAssertTrue(a.asksHazardQuestion)
        XCTAssertEqual(a.suggestedHazard, "power.fuel-burning.co")
        XCTAssertEqual(s.state.activeHazards, [])

        let yes = answered(try s.send("Yes."))
        XCTAssertTrue(yes.text.hasPrefix("This applies"))
        XCTAssertEqual(s.state.activeHazards, ["power.fuel-burning.co"])
        let basis = s.events.compactMap { e -> ConditionChange? in
            if case let .condition(c) = e.payload { return c } else { return nil }
        }.last?.basis
        XCTAssertEqual(basis, .answered)

        let no = try makeSession(file: "no.jsonl")
        _ = answered(try no.send("The generator is in the basement."))
        let reply = answered(try no.send("No, it's off."))
        XCTAssertEqual(reply.text, "OK. I haven't flagged the generator.")
        XCTAssertEqual(no.state.activeHazards, [])

        let cooking = try makeSession(file: "cooking.jsonl")
        _ = answered(try cooking.send("We moved the gas grill onto the screened porch while the burgers were still cooking."))
        XCTAssertEqual(cooking.state.activeHazards, ["power.fuel-burning.co"], "use in the same message flags at once")

        let sealed = try makeSession(file: "sealed.jsonl")
        let sealedReply = answered(try sealed.send("The new generator is in our basement, still sealed in its shipping carton."))
        XCTAssertFalse(sealedReply.asksHazardQuestion, "storage needs no question")
        XCTAssertEqual(sealed.state.activeHazards, [])
    }

    /// Three answers to "Is it running there...?": yes flags, no rules use out, and not
    /// knowing keeps the question open with the warning on screen. The last two are logged
    /// apart so the Mac can tell "ruled out" from "still unknown". (Clarification trial.)
    func testUnsureAnswerKeepsTheQuestionOpen() throws {
        let unsure = ["I don't know. My brother set it up.",
                      "No idea if it's running. How can I tell?",
                      KITTSession.notSureAnswer]
        for (i, text) in unsure.enumerated() {
            let s = try makeSession(file: "unsure\(i).jsonl")
            _ = answered(try s.send("Our generator is in the basement."))
            let reply = answered(try s.send(text))
            XCTAssertTrue(reply.text.hasPrefix("Not flagged while you're not sure."), text)
            XCTAssertTrue(reply.text.contains("Never run a generator"), text)
            XCTAssertTrue(reply.text.hasSuffix("Is it running there, or are you planning to run it there?"), text)
            XCTAssertTrue(reply.asksHazardQuestion, text)
            XCTAssertEqual(reply.suggestedHazard, "power.fuel-burning.co", text)
            XCTAssertEqual(s.state.activeHazards, [], text)
            XCTAssertEqual(s.state.hazardAnswers["power.fuel-burning.co"], .unknown, text)
        }
        let later = try makeSession(file: "unsure-then-yes.jsonl")
        _ = answered(try later.send("Our generator is in the basement."))
        _ = answered(try later.send(KITTSession.notSureAnswer))
        _ = answered(try later.send("Yes, it's running now."))
        XCTAssertEqual(later.state.activeHazards, ["power.fuel-burning.co"])
        XCTAssertNil(later.state.hazardAnswers["power.fuel-burning.co"], "a flag replaces the earlier answer")

        // A possibility is unknown, a plain statement beside it still counts, and a belief
        // the user has dropped does not count at all. (Uncertainty trial.)
        let answers: [(String, ConditionChange.State?)] = [
            ("Probably not.", .unknown), ("I think so.", .unknown), ("Maybe.", .unknown),
            ("Probably not. I'll ask.", .unknown),
            ("I haven't checked yet.", .unknown),
            ("It might be running.", .unknown),
            ("Maybe we'll run it down there tonight.", .unknown),
            ("I can't see it from here. It could be running.", .unknown),
            ("It may be on; the noise could be the freezer.", .unknown),
            ("It's off, but we might run it there later.", .unknown),
            ("Not sure, but we plan to run it there tonight.", .raised),
            ("Not sure yet, but we've decided to start it there tonight.", .raised),
            ("I'm not sure about the sump pump. The generator is definitely running.", .raised),
            ("I heard it start. It's definitely running down there.", .raised),
            ("Could we run it down there tonight?", .raised),
            ("I thought it was running. Turns out it's the dehumidifier; the generator is off.", .ruledOut),
            ("No, it isn't running and we won't start it there.", .ruledOut),
            ("I'm not sure, but it's switched off.", .ruledOut)]
        for (text, expected) in answers {
            let s = try makeSession(file: UUID().uuidString + ".jsonl")
            _ = answered(try s.send("Our generator is in the basement."))
            _ = answered(try s.send(text))
            let got: ConditionChange.State? = s.state.activeHazards.contains("power.fuel-burning.co")
                ? .raised : s.state.hazardAnswers["power.fuel-burning.co"]
            XCTAssertEqual(got, expected, text)
        }

        let thenNo = try makeSession(file: "unsure-then-no.jsonl")
        _ = answered(try thenNo.send("Our generator is in the basement."))
        _ = answered(try thenNo.send(KITTSession.notSureAnswer))
        let no = answered(try thenNo.send(KITTSession.notInUseAnswer))
        XCTAssertEqual(no.text, "OK. I haven't flagged the generator.")
        XCTAssertEqual(thenNo.state.hazardAnswers["power.fuel-burning.co"], .ruledOut, "the later answer replaces \"not sure\"")
    }

    /// "I haven't checked yet" keeps the question open, so the next message is read as the
    /// answer. A reply that answers nothing gets the question again instead of dropping it.
    func testTheQuestionStaysOpenUntilAnswered() throws {
        let s = try makeSession()
        _ = answered(try s.send("Our generator is in the basement."))
        let wait = answered(try s.send("I haven't checked yet."))
        XCTAssertTrue(wait.asksHazardQuestion)
        XCTAssertEqual(s.state.pendingQuestion, "power.fuel-burning.co")
        _ = answered(try s.send("I checked. It's running down there."))
        XCTAssertEqual(s.state.activeHazards, ["power.fuel-burning.co"])

        let other = try makeSession(file: "other.jsonl")
        _ = answered(try other.send("Our generator is in the basement."))
        let again = answered(try other.send("My wife went downstairs."))
        XCTAssertEqual(again.text, "I didn't catch an answer. Is it running there, or are you planning to run it there?")
        XCTAssertTrue(again.asksHazardQuestion)
        XCTAssertEqual(other.state.hazardAnswers, [:], "no answer is recorded")
        _ = answered(try other.send("She says it's running."))
        XCTAssertEqual(other.state.activeHazards, ["power.fuel-burning.co"])
    }

    /// Acceptance pairs from the modal-questions trial. A comma does not change what a hedge
    /// covers, and a question about what the thing is doing is not a proposal to use it.
    func testHedgesAndQuestionsAcceptancePairs() throws {
        let replies: [(String, ConditionChange.State?)] = [
            ("The generator is idling I think.", .unknown),
            ("The generator is idling, I think.", .unknown),
            ("Could I start it down there after supper?", .raised),
            ("Could it already be running down there?", .unknown),
            ("May I ask whether it's running?", .unknown),
            ("I think the freezer stopped, but the generator is running.", .raised),
            ("It's off now, but we will start it there after supper.", .raised),
            ("It's off now, but perhaps we'll start it there after supper.", .unknown)]
        for (text, expected) in replies {
            let s = try makeSession(file: UUID().uuidString + ".jsonl")
            _ = answered(try s.send("Our generator is in the basement."))
            _ = answered(try s.send(text))
            let got: ConditionChange.State? = s.state.activeHazards.contains("power.fuel-burning.co")
                ? .raised : s.state.hazardAnswers["power.fuel-burning.co"]
            XCTAssertEqual(got, expected, text)
        }

        let asking = try makeSession(file: "asking.jsonl")
        let reply = answered(try asking.send("Could the generator already be running in the basement?"))
        XCTAssertTrue(reply.asksHazardQuestion, "a question about what is happening gets the warning and the question")
        XCTAssertEqual(asking.state.activeHazards, [])

        let proposing = try makeSession(file: "proposing.jsonl")
        _ = answered(try proposing.send("Could I run the generator in the basement after supper?"))
        XCTAssertEqual(proposing.state.activeHazards, ["power.fuel-burning.co"])
    }

    /// The question-and-answer trial: a question the user answers in the same message, a
    /// correction that names another device, and questions about what is happening.
    func testSelfAnswersAndCorrections() throws {
        let replies: [(String, ConditionChange.State?)] = [
            ("Is it idling? Yes, it is.", .raised),
            ("Is it idling? No, it isn't.", .ruledOut),
            ("Is the dryer running? Yes, it is. I haven't checked the generator.", .unknown),
            ("Is it idling? I just looked. The generator is off.", .ruledOut),
            ("It's running. Sorry, I meant the dryer. The generator is off.", .ruledOut),
            ("It's running. I mean it's been on all night.", .raised),
            ("Is it OK if my dad starts the generator down there?", .raised),
            ("Could I be hearing the generator running downstairs?", .unknown),
            ("If it's running, should I turn it off?", .unknown)]
        for (text, expected) in replies {
            let s = try makeSession(file: UUID().uuidString + ".jsonl")
            _ = answered(try s.send("Our generator is in the basement."))
            _ = answered(try s.send(text))
            let got: ConditionChange.State? = s.state.activeHazards.contains("power.fuel-burning.co")
                ? .raised : s.state.hazardAnswers["power.fuel-burning.co"]
            XCTAssertEqual(got, expected, text)
        }
        let loud = try makeSession(file: "loud.jsonl")
        _ = answered(try loud.send("The generator is running in the basement. Sorry, the dryer is loud."))
        XCTAssertEqual(loud.state.activeHazards, ["power.fuel-burning.co"], "\"sorry\" alone corrects nothing")
    }

    /// "Might" in a first message is a possibility too: warn and ask, no flag.
    func testAPossibleUseWarnsAndAsks() throws {
        let s = try makeSession()
        let reply = answered(try s.send("The generator might be running in the basement."))
        XCTAssertTrue(reply.asksHazardQuestion)
        XCTAssertTrue(reply.text.hasPrefix("Never run a generator"))
        XCTAssertEqual(s.state.activeHazards, [])

        let off = try makeSession(file: "off.jsonl")
        let offReply = answered(try off.send("The generator in the basement is off for now, but we may run it there tonight."))
        XCTAssertTrue(offReply.text.hasPrefix("Never run a generator"), "storage words must not hide a possible use")
        XCTAssertEqual(off.state.activeHazards, [])
    }

    func testNotInUseAnswersAreRecordedAsRuledOut() throws {
        let noes = ["Yes, it's down there. No, we are not using it.",
                    "No, we're taking it outdoors before we start it.",
                    "Not in use.",
                    KITTSession.notInUseAnswer,
                    "Actually it is the battery power station, no fuel or engine."]
        for (i, text) in noes.enumerated() {
            let s = try makeSession(file: "no\(i).jsonl")
            _ = answered(try s.send("Our generator is in the basement."))
            let reply = answered(try s.send(text))
            XCTAssertEqual(reply.text, "OK. I haven't flagged the generator.", text)
            XCTAssertEqual(s.state.activeHazards, [], text)
            XCTAssertEqual(s.state.hazardAnswers["power.fuel-burning.co"], .ruledOut, text)
        }
        for text in ["It's off now, but we intend to run it right there after dark.",
                     "I'm upstairs and can hear it running below me.",
                     "Yes."] {
            let s = try makeSession(file: UUID().uuidString + ".jsonl")
            _ = answered(try s.send("Our generator is in the basement."))
            _ = answered(try s.send(text))
            XCTAssertEqual(s.state.activeHazards, ["power.fuel-burning.co"], text)
        }
    }

    /// Each clause's action belongs to the device that clause names: the pump is running,
    /// the generator is off.
    func testActionsAttachToTheDeviceTheirClauseNames() throws {
        let s = try makeSession()
        _ = answered(try s.send("Our generator is in the basement."))
        let reply = answered(try s.send("The sump pump is running. The generator is off."))
        XCTAssertEqual(reply.text, "OK. I haven't flagged the generator.")
        XCTAssertEqual(s.state.activeHazards, [])

        let washer = try makeSession(file: "washer.jsonl")
        _ = answered(try washer.send("I have the owner's manual for a generator."))
        let again = answered(try washer.send("When the washer finishes, can I run it again?"))
        XCTAssertNil(again.suggestedHazard, "\"it\" is the washer, named earlier in the message")
        XCTAssertEqual(washer.state.activeHazards, [])

        let tent = try makeSession(file: "tent.jsonl")
        _ = answered(try tent.send("We've got briquettes still glowing in a metal pan. Can we bring them into the tent for warmth?"))
        XCTAssertEqual(tent.state.activeHazards, ["power.fuel-burning.co"], "\"them\" skips the pan back to the briquettes")
    }

    /// With another hazard flagged, ruling out the generator names the generator and keeps
    /// the other flag.
    func testRulingOutOneHazardKeepsAnother() throws {
        let s = try makeSession()
        _ = answered(try s.send("The tap water smells like gasoline."))
        _ = answered(try s.send("Our generator is in the basement."))
        let reply = answered(try s.send("No, it is off."))
        XCTAssertEqual(reply.text, "OK. I haven't flagged the generator.")
        XCTAssertEqual(s.state.activeHazards, ["water.contamination.fuel"])
    }

    /// Negating an action prevents a new flag. It does not clear one: "I won't start it
    /// again" never says the generator has stopped.
    func testNegationDoesNotClearAnExistingFlag() throws {
        let s = try makeSession()
        _ = answered(try s.send("The generator is running in the basement."))
        _ = answered(try s.send("I won't start it again."))
        XCTAssertEqual(s.state.activeHazards, ["power.fuel-burning.co"])
    }

    func testNegationOnlyCancelsWhatItNegates() throws {
        func flags(_ messages: String...) throws -> [String] {
            let s = try makeSession(file: UUID().uuidString + ".jsonl")
            for m in messages { _ = try s.send(m) }
            return s.state.activeHazards
        }
        XCTAssertEqual(try flags("The sealed weed killer bottle sits on a shelf next to unopened bottled water. Nothing leaked."), [])
        XCTAssertEqual(try flags("Nothing leaked but the water smells like gasoline."), ["water.contamination.fuel"])
        XCTAssertEqual(try flags("The water doesn't smell like gasoline anymore."), [])
        XCTAssertEqual(try flags("Don't worry, the generator is running in the garage."), ["power.fuel-burning.co"])
        XCTAssertEqual(try flags("Can't I run the generator in the garage?"), ["power.fuel-burning.co"], "a negative question still proposes it")
        XCTAssertEqual(try flags("The generator isn't in the basement, it's running in the garage."), ["power.fuel-burning.co"])
        XCTAssertEqual(try flags("Rain carried lawn pesticide into the well we drink from."), ["water.contamination.fuel"])
        XCTAssertEqual(try flags("Where can I find the model number on this charcoal cooker?", "Can we fire it up in the mudroom?"), ["power.fuel-burning.co"])
    }

    func testRunningFlagsButStoringDoesNot() throws {
        let run = try makeSession(file: "run.jsonl")
        _ = answered(try run.send("Is our generator still under warranty?"))
        let basement = answered(try run.send("Can I run it in our basement while the street is dark?"))
        XCTAssertTrue(basement.text.hasPrefix("This applies: Carbon monoxide risk"), basement.text)
        XCTAssertEqual(run.state.activeHazards, ["power.fuel-burning.co"])
        let condition = run.events.compactMap { e -> ConditionChange? in
            if case let .condition(c) = e.payload { return c } else { return nil }
        }.last
        XCTAssertEqual(condition?.basis, .followUp)

        let receipt = try makeSession(file: "receipt.jsonl")
        _ = answered(try receipt.send("The handle on our grill snapped off. Can it be replaced?"))
        let r = answered(try receipt.send("I keep the receipt in the garage. Does that help?"))
        XCTAssertFalse(r.text.contains("Never run"), r.text)
        XCTAssertEqual(receipt.state.activeHazards, [])

        let boxed = try makeSession(file: "boxed.jsonl")
        _ = answered(try boxed.send("Where's the manual for the generator?"))
        let b = answered(try boxed.send("It will stay boxed in the garage until spring."))
        XCTAssertFalse(b.text.contains("Never run"), b.text)
        XCTAssertEqual(boxed.state.activeHazards, [])
    }

    func testStorageWordsDoNotHideAProposedUse() throws {
        let s = try makeSession()
        _ = answered(try s.send("The generator is stored in the garage. Can we run it in there during the outage?"))
        XCTAssertEqual(s.state.activeHazards, ["power.fuel-burning.co"])
        let t = try makeSession(file: "quiet.jsonl")
        _ = answered(try t.send("We keep the generator stored in the garage."))
        XCTAssertEqual(t.state.activeHazards, [])
    }

    func testAFollowUpWithoutAPointerDoesNotBorrowTheDevice() throws {
        let s = try makeSession()
        _ = answered(try s.send("Is our generator still under warranty?"))
        let d = answered(try s.send("Can I run the dishwasher in the basement?"))
        XCTAssertEqual(d.citations, [])
        XCTAssertEqual(s.state.activeHazards, [])
    }

    func testStayingNearASuspectedHazardShowsItAgainUnflagged() throws {
        let s = try makeSession()
        _ = answered(try s.send("Where's the assembly manual for the barbecue?"))
        let garage = answered(try s.send("Can I set it up in the garage?"))
        XCTAssertEqual(garage.citations, ["power.fuel-burning.co@v6"])
        XCTAssertEqual(garage.suggestedHazard, "power.fuel-burning.co")
        XCTAssertEqual(s.state.activeHazards, [], "setting up is not running")
    }

    /// The replay of the third trial found an extra carbon monoxide flag here, because
    /// "kerosene" plus "bathroom" looked like a heater indoors.
    func testWaterContaminationRaisesOnlyItsOwnFlag() throws {
        let s = try makeSession()
        _ = answered(try s.send("The water out of the bathroom tap has a rainbow slick and reeks of kerosene"))
        XCTAssertEqual(s.state.activeHazards, ["water.contamination.fuel"])
        let t = try makeSession(file: "barrel.jsonl")
        _ = answered(try t.send("We got weed killer in the water barrel we drink from."))
        XCTAssertEqual(t.state.activeHazards, ["water.contamination.fuel"])
    }

    func testAHazardEntryShownOnRequestIsAPrecaution() throws {
        let s = try makeSession()
        let a = answered(try s.send("Is there fuel in our water?"))
        XCTAssertEqual(a.citations, ["water.contamination.fuel@v4"])
        XCTAssertEqual(a.suggestedHazard, "water.contamination.fuel")
        XCTAssertEqual(s.state.activeHazards, [], "asking is not describing")
        let boil = answered(try s.send("would boiling help?"))
        XCTAssertEqual(boil.citations, ["water.contamination.fuel@v4"])
        XCTAssertEqual(s.state.activeHazards, [])
    }

    func testAPointerAloneDoesNotFlagASuspectedHazard() throws {
        let s = try makeSession()
        _ = answered(try s.send("Where do I find the serial number on the generator?"))
        let warranty = answered(try s.send("Is it still under warranty?"))
        XCTAssertEqual(warranty.citations, [])
        XCTAssertEqual(s.state.activeHazards, [])
    }

    func testConfirmingASuspectedHazardFlagsIt() throws {
        let s = try makeSession()
        let a = answered(try s.send("Why does food cooked over charcoal taste smoky?"))
        let id = try XCTUnwrap(a.suggestedHazard)
        XCTAssertEqual(s.state.activeHazards, [])
        try s.confirmHazard(id)
        XCTAssertEqual(s.state.activeHazards, [id])
        try s.confirmHazard(id)   // a second tap changes nothing
        XCTAssertEqual(s.events.filter { $0.type == .condition }.count, 1)
        XCTAssertNoThrow(try s.confirmHazard("water.storage.baseline"))  // not a hazard: ignored
        XCTAssertEqual(s.state.activeHazards, [id])
    }

    func testDescribedHazardIsFlaggedWithItsBasis() throws {
        let s = try makeSession()
        _ = answered(try s.send("We've got briquettes still glowing in a metal pan. Can we bring them into the tent for warmth?"))
        XCTAssertEqual(s.state.activeHazards, ["power.fuel-burning.co"])
        let condition = s.events.compactMap { e -> ConditionChange? in
            if case let .condition(c) = e.payload { return c } else { return nil }
        }.first
        XCTAssertEqual(condition?.basis, .described)
    }

    func testContainerEntryGivesContactTimeAndEmptying() throws {
        let entry = try XCTUnwrap(try ContentPack.bundled().entry("water.storage.containers"))
        XCTAssertTrue(entry.shortAnswer.contains("at least 30 seconds"))
        XCTAssertTrue(entry.shortAnswer.contains("pour it out"))
        XCTAssertTrue(entry.shortAnswer.contains("air-dry"))
        XCTAssertEqual(entry.source.publisher, "CDC")
    }

    func testBoilNoticeAloneIsNotFuelContamination() throws {
        let s = try makeSession()
        let a = answered(try s.send("We're under a boil-water notice"))
        XCTAssertEqual(a.citations, ["water.advisory.boil@v2"])
        XCTAssertFalse(a.text.contains("fuel"))
        XCTAssertEqual(s.state.activeHazards, [])
    }

    func testUncoveredQuestionOffersButtonsAndDoesNotCallTheModel() throws {
        let s = try makeSession()
        let a = answered(try s.send("What are the best hiking boots?"))
        XCTAssertEqual(a.origin, .app)
        XCTAssertTrue(a.offersModel)
        XCTAssertEqual(s.state.unansweredQuestion, "What are the best hiking boots?")

        // Only when the user asks for it does the model get the question, with no guide text.
        let request = try XCTUnwrap(s.modelRequestForUnansweredQuestion())
        XCTAssertFalse(request.isGrounded)
        XCTAssertEqual(request.prompt.turns.last, ChatTurn(.user, "What are the best hiking boots?"))
        let saved = try s.recordModelReply("Sturdy ones.", for: request, modelID: "test", interrupted: false)
        XCTAssertEqual(saved.origin, .model)
        XCTAssertEqual(saved.citations, [])
        XCTAssertNil(s.state.unansweredQuestion)

        let reopened = try makeSession()
        XCTAssertEqual(reopened.events.filter { $0.type == .userMessage || $0.type == .assistantMessage }.count, 3)
    }

    func testFollowUpOnScreenEntryIsGroundedInThatEntry() throws {
        let s = try makeSession()
        _ = answered(try s.ask(entryID: "food.outage.cold"))
        let a = answered(try s.send("Why does a half-full freezer warm up faster?"))
        XCTAssertTrue(a.offersModel, "model is off by default")
        let request = try XCTUnwrap(s.modelRequestForUnansweredQuestion())
        XCTAssertEqual(request.citations, ["food.outage.cold@v2"])
        XCTAssertTrue(request.prompt.turns.last?.content.contains("48 hours in a full freezer") ?? false)

        // A reply that invents a number is flagged.
        let bad = try s.recordModelReply("It stays safe for 72 hours.", for: request, modelID: "test", interrupted: false)
        XCTAssertEqual(bad.unsupportedNumbers, ["72"])
    }

    func testGroundedFollowUpPolicySendsFollowUpsStraightToTheModel() throws {
        let s = try makeSession()
        s.modelPolicy = .groundedFollowUps
        _ = answered(try s.ask(entryID: "food.outage.cold"))
        guard case let .needsModel(request) = try s.send("Why does a half-full freezer warm up faster?") else {
            return XCTFail("expected a model request")
        }
        XCTAssertEqual(request.citations, ["food.outage.cold@v2"])
        // The model following its instruction is shown as "not covered", not as an answer.
        let saved = try s.recordModelReply("The guide does not cover that.", for: request, modelID: "test", interrupted: false)
        XCTAssertEqual(saved.origin, .app)
        XCTAssertFalse(saved.offersModel, "asking the same model again would only repeat it")
        XCTAssertEqual(saved.suggestions, ["food.outage.after", "power.fuel-burning.co", "power.outage.during"])
    }

    func testActiveHazardIsPutInFrontOfTheModel() throws {
        let s = try makeSession()
        _ = try s.send("Our water smells like gasoline")
        _ = answered(try s.send("What are the best hiking boots?"))
        let request = try XCTUnwrap(s.modelRequestForUnansweredQuestion())
        XCTAssertEqual(request.citations, ["water.contamination.fuel@v4"])
        XCTAssertTrue(request.prompt.turns.last?.content.contains("WARNING: If water may have fuel") ?? false)
        // And the "not covered" reply itself leads with the hazard as a button.
        let again = answered(try s.send("which emergency radio should I buy"))
        XCTAssertEqual(again.suggestions.first, "water.contamination.fuel")
    }
}

final class TextTests: XCTestCase {
    func testStemming() {
        XCTAssertEqual(Text.stem("boiling"), Text.stem("boil"))
        XCTAssertEqual(Text.stem("boiled"), Text.stem("boil"))
        XCTAssertEqual(Text.stem("gallons"), Text.stem("gallon"))
        XCTAssertEqual(Text.stem("advisories"), Text.stem("advisory"))
        XCTAssertEqual(Text.stem("stored"), Text.stem("store"))
        XCTAssertEqual(Text.stem("gas"), "gas")
    }

    func testUTF8SplitAcrossTokens() {
        var acc = UTF8Accumulator()
        var out = ""
        for b in Array("3 × 3 ✅".utf8) { out += acc.append([b]) }
        out += acc.finish()
        XCTAssertEqual(out, "3 × 3 ✅")
    }

    func testSentenceCounter() {
        var c = SentenceCounter()
        c.append("Store 1.5 gal per day. Use U.S. gallons, e.g. jugs. 2. Boil it")
        XCTAssertEqual(c.count, 2, "decimals, initials and list numbers do not end a sentence")
        c.append("!")
        XCTAssertEqual(c.countIncludingTrailing, 3)
    }

    func testSentencesPointersAndNegation() {
        XCTAssertEqual(Text.sentences("Store 1.5 gal. Is it ok? Yes").map(\.isQuestion), [false, true, false])
        XCTAssertTrue(Text.refersToPreviousMessage("It's running in the basement right now."))
        XCTAssertFalse(Text.refersToPreviousMessage("The dryer is in the basement. Can I run it tonight?"))
        let n = Text.stemsHonouringNegation("I won't start it down there.", negatable: [Text.stem("start")])
        XCTAssertTrue(n.negated.contains(Text.stem("start")))
        XCTAssertFalse(n.kept.contains(Text.stem("start")))
        let q = Text.stemsHonouringNegation("Won't it start in the garage?", negatable: [Text.stem("start")])
        XCTAssertTrue(q.kept.contains(Text.stem("start")), "questions are not negated")
    }

    func testNumberCheck() {
        XCTAssertEqual(NumberCheck.numbers(in: "Boil for 1 minute, or three minutes above 6,500 feet."), ["1", "3", "6500"])
        XCTAssertEqual(NumberCheck.unsupported(in: "Boil for 10 minutes.", sources: ["rolling boil for 1 minute"]), ["10"])
        XCTAssertEqual(NumberCheck.unsupported(in: "Boil for one minute.", sources: ["rolling boil for 1 minute"]), [])
    }

    func testGroundedPromptKeepsTheSystemTextFixed() {
        let a = PromptBuilder.grounded(question: "why?", passages: ["Passage A."])
        let b = PromptBuilder.grounded(question: "how?", passages: ["Passage B."], warnings: ["Danger."])
        XCTAssertEqual(a.turns[0], b.turns[0], "a fixed system turn is what lets the engine reuse its cache")
        XCTAssertTrue(b.turns[1].content.hasPrefix("GUIDE: WARNING: Danger.\nPassage B."))
        XCTAssertTrue(a.deterministic)
    }
}

/// The scorer once passed "I'm not sure which guide entry fits" as a correct answer to
/// "can we bring the charcoal grill inside?", because "not sure" contains "not".
final class ScorerTests: XCTestCase {
    let expect = EvalExpectation(entries: ["power.fuel-burning.co"], notCovered: nil, mustSay: [["never", "not"]], mustNotSay: ["yes"])

    func testANonAnswerCannotPassAContentCheck() {
        let reply = AssistantMessage(text: "I'm not sure which guide entry fits. Is it one of these?", origin: .app,
                                     suggestions: ["power.fuel-burning.co"], offersModel: true)
        let r = EvalScorer.score(say: "q", reply: reply, expect: expect, judgeRouting: true)
        XCTAssertEqual(r.routedCorrectly, false)
        XCTAssertEqual(r.contentCorrect, false)
        XCTAssertTrue(r.offeredAsButton)
    }

    func testUrgentActionMustBeInOpeningSentence() {
        let expected = EvalExpectation(firstSentence: "Call 911.")
        for (reply, correct) in [("Call 911. Move to a cooler place.", true),
                                 ("Move to a cooler place. Call 911.", false),
                                 ("It might be necessary to call 911.", false)] {
            let message = AssistantMessage(text: reply, origin: .model)
            let result = EvalScorer.score(say: "What comes first?", reply: message, expect: expected, judgeRouting: false)
            XCTAssertEqual(result.contentCorrect, correct, reply)
        }
    }

    func testHedgesAndSubstringsDoNotCount() {
        let hedge = AssistantMessage(text: "I'm not sure. Nothing I know of says so.", origin: .model)
        XCTAssertEqual(EvalScorer.score(say: "q", reply: hedge, expect: expect, judgeRouting: false).contentCorrect, false)
        let real = AssistantMessage(text: "Never do that. It is not safe.", origin: .model)
        XCTAssertEqual(EvalScorer.score(say: "q", reply: real, expect: expect, judgeRouting: false).contentCorrect, true)
        XCTAssertFalse(EvalScorer.containsPhrase("Use eyes and ears", "yes"))
        XCTAssertTrue(EvalScorer.containsPhrase("Yes, you can.", "yes"))
    }

    func testAMissedWarningIsACriticalFailureEvenWithNoContentCheck() {
        let turn = EvalTurnResult(say: "q", reply: "not sure", origin: "app", citations: [], routedCorrectly: false,
                                  offeredAsButton: true, contentCorrect: nil, problems: ["expected x"], unsupportedNumbers: [])
        let report = EvalReport(build: .pipeline, modelID: nil, packVersion: "t",
                                results: [EvalScenarioResult(family: "f", scenario: "s", split: "heldout", critical: true, turns: [turn])])
        XCTAssertEqual(report.tally().criticalFailures, 1)
        XCTAssertEqual(report.tally().criticalNotShown, 1)
    }
}

/// The deterministic part of Eval/scenarios.json is a regression test: every "dev"
/// scenario must be routed and answered correctly without the model. Held-out families
/// are reported by `kitt eval`, never asserted here, so they stay honest.
final class ScenarioTests: XCTestCase {
    func testDevScenariosPassWithoutTheModel() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Eval/scenarios.json")
        let suite = try JSONDecoder().decode(EvalSuite.self, from: Data(contentsOf: url))
        let report = try EvalRunner.run(.pipeline, suite: suite, pack: try ContentPack.bundled(), generator: nil)
        let heat = try XCTUnwrap(ContentPack.bundled().entries.first { $0.id == "health.heat.illness" })
        let wrongAnswer = AssistantMessage(text: heat.shortAnswer, origin: .guide, citations: [heat.citation])
        for id in ["heat-wave-packing", "cool-house-heat-wave"] {
            let scenario = try XCTUnwrap(suite.families.flatMap(\.scenarios).first { $0.id == id })
            let turn = try XCTUnwrap(scenario.turns.first)
            XCTAssertEqual(EvalScorer.score(say: turn.say, reply: wrongAnswer, expect: turn.expect,
                                            judgeRouting: true).contentCorrect, false, id)
        }
        let freezer = try XCTUnwrap(report.results.first { $0.scenario == "pen-in-freezer" }?.turns.first)
        XCTAssertEqual(freezer.contentCorrect, true, freezer.reply)
        for r in report.results where r.split == "dev" {
            for t in r.turns {
                XCTAssertEqual(t.problems, [], "\(r.family)/\(r.scenario): \(t.say) → \(t.reply)")
            }
        }
        XCTAssertEqual(report.tally(split: "dev").criticalFailures, 0)
        // Held-out scenarios are not required to pass. One thing is required of them: a miss
        // may ask the user to pick, but it must never show a different guide entry.
        for r in report.results where r.split == "heldout" {
            for t in r.turns where t.routedCorrectly == false {
                XCTAssertEqual(t.citations, [], "\(r.family)/\(r.scenario): \(t.say) showed the wrong entry")
            }
        }
    }
}
