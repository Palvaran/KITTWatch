import Foundation

/// What the UI should do after a user turn has been saved.
public enum TurnOutcome: Equatable, Sendable {
    /// Answered by the app: reviewed guide text, the calculator, a question for one
    /// missing fact, or "the guide doesn't cover that".
    case answered(AssistantMessage)
    /// Run the local model on this request, then call `recordModelReply`.
    case needsModel(ModelRequest)
}

/// A model prompt together with the guide entries that are in it.
public struct ModelRequest: Equatable, Sendable {
    public var prompt: ModelPrompt
    /// Citations of the entries whose passages are in the prompt. Empty: no guide text.
    public var citations: [String]
    /// The guide text and question the model saw, for checking its reply.
    public var sources: [String]
    public var isGrounded: Bool { !citations.isEmpty }
}

/// When the model is allowed to speak.
public enum ModelPolicy: String, Codable, Sendable {
    /// The model answers follow-up questions about the guide entry on screen, with that
    /// entry's passage in its prompt. Anything else needs "Ask the model anyway".
    case groundedFollowUps
    /// The model only runs when the user taps "Ask the model anyway".
    case onRequest
}

/// What the saved events say about a conversation right now.
public struct ConversationState: Equatable, Sendable {
    /// Hazard entries raised and not cleared, oldest first.
    public var activeHazards: [String] = []
    /// The guide entry the conversation is currently about.
    public var focusEntryID: String?
    public var hasWaterContext = false
    /// The last question, if the guide had no reliable answer for it.
    public var unansweredQuestion: String?
    /// A hazard the last reply showed as a precaution, not flagged. The next message can
    /// flag it by proposing the risky use.
    public var pendingHazard: String?
    /// A hazard whose question the last reply asked ("Is it running there...?").
    public var pendingQuestion: String?
    /// The user's latest answer about each hazard: `.ruledOut` or `.unknown` (flags are in
    /// `activeHazards`). What the Mac needs to tell "not in use" from "don't know".
    public var hazardAnswers: [String: ConditionChange.State] = [:]
    /// The most recent user message, for reading a follow-up that refers back to it.
    public var lastUserText: String?
    /// The water notice in force, as the user reported it. Questions about using the water
    /// are answered from its entry until the user says it was lifted.
    public var waterNotice: WaterNotice?
    /// The user said they weren't sure which notice it is.
    public var waterNoticeUnsure = false
    /// KITT asked "What does the notice say?" last turn, to answer this question.
    public var pendingNoticeQuestion: String?
}

/// Orchestrates one conversation. The order of authority is fixed:
///
///   1. a hazard the user just described            → its reviewed entry, flagged
///      (only located, for a hazard that needs use   → its entry and one question)
///   2. a hazard still active in this conversation  → that entry again
///   3. arithmetic                                  → the calculator
///   4. a reliable guide match                      → reviewed text, verbatim
///      (no reliable match, but the message reports a sign that someone may need
///      help now → that urgent entry first, the other candidates as buttons)
///      (a plain statement of the household          → saved, "Noted: ...")
///      (no reliable match, but a hazard entry is a candidate and the question names
///      its subject and a keyword → that hazard's entry as a precaution, not flagged)
///   5. a follow-up about the entry on screen       → the model, given that entry's passage
///   6. anything else                               → "not covered" plus buttons; the model
///                                                    answers only if the user asks for it
///
/// The user's words are saved before any of this runs. Household facts in the message are
/// saved only on the calculator and household-statement routes.
public final class KITTSession: @unchecked Sendable {
    public let log: EventLog
    public let pack: ContentPack
    public private(set) var conversationID: UUID
    public var promptBudget = PromptBudget()
    /// Off by default: in the off-watch evaluation no stock model under 400M parameters
    /// answered follow-ups from a passage reliably (see Eval/RESULTS.md). Change this
    /// when an evaluated model earns it.
    public var modelPolicy: ModelPolicy = .onRequest
    /// Whether a model is installed to ask. Without one, "the guide doesn't cover that"
    /// replies don't mention the model (the watch hides the button until it is downloaded).
    public var modelAvailable = true
    private let search: GuideSearch

    public static let waterCalculator = "water.storage"
    /// What the watch's answer buttons send after "Is it running there...?", so a tap and
    /// a typed reply take the same path and land in the transcript the same way.
    /// The last line of a reply that shows a hazard entry KITT is not sure applies.
    public static let precautionNote = "(Shown in case your question involves this.)"
    /// The last line of a reply that shows an urgent entry first when KITT is not sure
    /// which entry the question means.
    public static let urgentNote = "(Shown first in case someone needs help now.)"
    public static let notInUseAnswer = "No, it's not in use."
    public static let notSureAnswer = "I'm not sure."

    public init(log: EventLog, pack: ContentPack, conversationID: UUID? = nil) {
        self.log = log
        self.pack = pack
        self.search = GuideSearch(pack: pack)
        self.conversationID = conversationID ?? log.conversationIDs.last ?? UUID()
    }

    public var events: [ConversationEvent] { log.events(in: conversationID) }
    public var household: HouseholdState { HouseholdState.fold(log.all) }

    public func startNewConversation() { conversationID = UUID() }
    public func open(_ id: UUID) { conversationID = id }

    public var state: ConversationState {
        var s = ConversationState()
        var lastUser: String?
        let waterCitation = waterEntry?.citation
        for e in events {
            switch e.payload {
            case let .userMessage(text, _):
                lastUser = text
                s.lastUserText = text
            case let .condition(c):
                switch c.state {
                case .raised:
                    s.activeHazards.removeAll { $0 == c.entryID }
                    s.activeHazards.append(c.entryID)
                    s.hazardAnswers[c.entryID] = nil
                case .cleared:
                    s.activeHazards.removeAll { $0 == c.entryID }
                case .ruledOut, .unknown:
                    s.hazardAnswers[c.entryID] = c.state
                }
                if s.pendingHazard == c.entryID { s.pendingHazard = nil; s.pendingQuestion = nil }
            case .calculation:
                s.hasWaterContext = true
            case let .assistantMessage(m):
                if let first = m.citations.first, let entry = pack.entry(forCitation: first) {
                    s.focusEntryID = entry.id
                }
                if let waterCitation, m.citations.contains(waterCitation) { s.hasWaterContext = true }
                s.unansweredQuestion = m.offersModel ? lastUser : nil
                s.pendingHazard = m.suggestedHazard.flatMap { s.activeHazards.contains($0) ? nil : $0 }
                s.pendingQuestion = m.asksHazardQuestion ? s.pendingHazard : nil
                s.pendingNoticeQuestion = m.noticeQuestion
            case let .waterNotice(n):
                s.waterNotice = n.notice
                s.waterNoticeUnsure = n.state == .unknown
                if n.state == .lifted { s.pendingNoticeQuestion = nil }
            case .householdFact:
                break
            }
        }
        return s
    }

    /// Record a household fact chosen in the UI (e.g. the household-size stepper).
    @discardableResult
    public func setFact(_ key: HouseholdFact.Key, _ value: Double) throws -> ConversationEvent {
        try log.append(.householdFact(HouseholdFact(key: key, value: value)), conversation: conversationID)
    }

    /// The user says a hazard shown as a precaution does apply ("This applies to us").
    public func confirmHazard(_ entryID: String) throws {
        guard pack.entry(entryID)?.hazard != nil, !state.activeHazards.contains(entryID) else { return }
        try log.append(.condition(ConditionChange(entryID: entryID, state: .raised, basis: .confirmed)),
                       conversation: conversationID)
    }

    /// The user says a hazard no longer applies (dismissed the banner).
    public func clearHazard(_ entryID: String) throws {
        guard state.activeHazards.contains(entryID) else { return }
        try log.append(.condition(ConditionChange(entryID: entryID, state: .cleared)), conversation: conversationID)
    }

    /// The user says the water notice is over (cleared the banner on the home screen).
    public func clearWaterNotice() throws {
        let s = state
        guard s.waterNotice != nil || s.waterNoticeUnsure else { return }
        try log.append(.waterNotice(WaterNoticeChange(state: .lifted, sourceText: nil)), conversation: conversationID)
    }

    // MARK: Turns

    /// Save the user's exact words, then decide how to answer.
    public func send(_ text: String, via method: InputMethod = .typed) throws -> TurnOutcome {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KITTError.emptyMessage }
        let before = state
        try log.append(.userMessage(text: text, inputMethod: method), conversation: conversationID)

        // Household facts are read now but saved only once the message turns out to be about
        // the water plan (step 3) or to state the household (step 4c). A duration in a
        // question about something else ("nobody has had anything to drink for two days")
        // must not change the plan.
        var intent = IntentParser.parse(trimmed)

        // 1. A hazard described in this message outranks everything, including arithmetic.
        let readings = search.hazardReadings(of: trimmed)
        let described = readings.filter { $0.reading == .described }.map(\.entry)
        if let hazard = described.first {
            for h in described where !before.activeHazards.contains(h.id) {
                try log.append(.condition(ConditionChange(entryID: h.id, state: .raised, sourceText: text, basis: .described)),
                               conversation: conversationID)
            }
            return .answered(try reply(guideMessage(for: hazard, notes: [], activeHazards: before.activeHazards + [hazard.id])))
        }

        // 1a. The message only says where the thing is ("the generator is in the basement",
        //     "we brought the grill onto the porch"). Warn now, ask the hazard's one
        //     question, and leave the flag to the answer.
        if let located = readings.first(where: { $0.reading == .located })?.entry,
           !before.activeHazards.contains(located.id) {
            var message = guideMessage(for: located, notes: [], activeHazards: before.activeHazards)
            if let question = located.hazard?.question { message.text += "\n" + question }
            message.suggestedHazard = located.id
            message.asksHazardQuestion = located.hazard?.question != nil
            return .answered(try reply(message))
        }

        // 1c. The answer to that question. Yes, or a use that belongs to the device, flags
        //     it. No (off, stored, taken outside, not this kind of device) is recorded as
        //     ruled out. "I don't know" is recorded as unknown: no flag, the warning shown
        //     again, and the question left open.
        if let id = before.pendingQuestion, let hazard = pack.entry(id),
           let answer = search.answer(to: id, text: trimmed) {
            switch answer {
            case .yes:
                try log.append(.condition(ConditionChange(entryID: id, state: .raised, sourceText: text, basis: .answered)),
                               conversation: conversationID)
                return .answered(try reply(reminder(of: hazard, prefix: "This applies")))
            case .no:
                try log.append(.condition(ConditionChange(entryID: id, state: .ruledOut, sourceText: text)),
                               conversation: conversationID)
                // The device the question was about: the latest earlier message that names
                // one (the question may have been asked again after "I'm not sure").
                let device = events.dropLast().reversed().lazy.compactMap { e -> String? in
                    if case let .userMessage(t, _) = e.payload { return self.search.deviceWord(in: t, forHazard: id) }
                    return nil
                }.first
                return .answered(try reply(AssistantMessage(
                    text: device.map { "OK. I haven't flagged the \($0)." } ?? "OK. I haven't flagged it.", origin: .app)))
            case .unknown:
                try log.append(.condition(ConditionChange(entryID: id, state: .unknown, sourceText: text)),
                               conversation: conversationID)
                var message = guideMessage(for: hazard, notes: [], activeHazards: before.activeHazards)
                message.text = "Not flagged while you're not sure.\n" + message.text
                if let question = hazard.hazard?.question { message.text += "\n" + question }
                message.suggestedHazard = id
                message.asksHazardQuestion = true
                message.suggestions = []
                return .answered(try reply(message))
            }
        }

        // 1d. The answer to "What does the notice say?". A kind answers the question that was
        //     waiting for it. "Not sure" is saved as unknown: nothing is assumed, what each
        //     notice means is shown, and the question stays open.
        var notice = WaterNotice.read(trimmed)
        if let waiting = before.pendingNoticeQuestion, !notice.discussesEnd, let answer = WaterNotice.answer(to: trimmed) {
            switch answer {
            case .notice(let kind):
                try log.append(.waterNotice(WaterNoticeChange(kind, sourceText: text)), conversation: conversationID)
                return .answered(try reply(noticeAnswer(kind, question: waiting, activeHazards: before.activeHazards)))
            case .unsure:
                try log.append(.waterNotice(WaterNoticeChange(state: .unknown, sourceText: text)), conversation: conversationID)
                return .answered(try reply(askWaterNotice(about: waiting, unsure: true)))
            }
        }

        // 1e. "The boil notice was lifted" ends the notice. The rest of the message is
        //     answered on its own: "...How much water should I store for the dog?" is about
        //     preparing, not about the notice. Only a notice named as such ends; "the outage
        //     is over" leaves a boil notice in force.
        let concernsCurrentNotice = before.waterNotice.map { notice.endedKinds.isEmpty || notice.endedKinds.contains($0) } ?? true
        if notice.discussesEnd && notice.kinds.isEmpty {
            let ended = notice.lifted && concernsCurrentNotice
            if ended {
                try log.append(.waterNotice(WaterNoticeChange(state: .lifted, sourceText: text)), conversation: conversationID)
            }
            let rest = notice.remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty {
                if ended {
                    return .answered(try reply(AssistantMessage(text: "Noted: the water notice is over.", origin: .app)))
                }
                let status = Self.noticeStatus(current: before.waterNotice, otherNoticeLifted: notice.lifted)
                if let waiting = before.pendingNoticeQuestion {
                    var message = askWaterNotice(about: waiting, unsure: false)
                    message.text = status + " " + WaterNotice.question
                    return .answered(try reply(message))
                }
                return .answered(try reply(AssistantMessage(text: status, origin: .app)))
            }
            trimmed = rest
            intent = IntentParser.parse(rest)
            if !ended { notice = WaterNotice.read(rest) }
        }

        // 1b. A message that refers back and proposes the risky use: "Can I run it in our
        //     basement?" after a question about the generator. Read together with the
        //     previous message, it describes the hazard. The pointer must not have a
        //     referent earlier in the message ("The dryer is in the basement. Can I run it
        //     tonight?"), and the use must not be aimed at another named object ("can I run
        //     the dryer in the basement?").
        if let previous = before.lastUserText {
            for hazard in search.hazardsRaised(by: trimmed, referringTo: previous)
            where !before.activeHazards.contains(hazard.id) {
                try log.append(.condition(ConditionChange(entryID: hazard.id, state: .raised, sourceText: text, basis: .followUp)),
                               conversation: conversationID)
                return .answered(try reply(reminder(of: hazard, prefix: "This applies")))
            }
        }

        let retrieval = search.retrieve(trimmed)
        let top = retrieval.candidates.first

        // 2. A hazard raised earlier stays in force for questions inside its scope, unless
        //    the question clearly belongs to an entry the hazard has nothing to say about.
        //    Two ways in: a word from the hazard's own follow-up list, or a question that
        //    points back ("what if I run it through the Brita?") while the hazard is what
        //    the conversation is about.
        for id in before.activeHazards.reversed() {
            guard let hazard = pack.entry(id) else { continue }
            let pointsBack = before.focusEntryID == id && search.refersBack(trimmed, forHazard: id)
            guard search.isFollowUp(trimmed, toHazard: id) || pointsBack else { continue }
            if let hit = retrieval.confident, hit.entry.id != id, hazard.hazard?.overrides.contains(hit.entry.id) != true { continue }
            return .answered(try reply(reminder(of: hazard)))
        }

        // 2b. The last reply showed a hazard as a precaution, and this message stays on it
        //     without describing an exposure: it refers back and proposes a use ("can I run
        //     it on the patio?") or uses a scope word ("can I set it up in the garage?").
        //     Show the precaution again, still not flagged. A message that says the thing is
        //     put away ("it stays boxed in the garage") or only asks about it ("is it
        //     available in red?") is answered as an ordinary question.
        if let id = before.pendingHazard, let hazard = pack.entry(id),
           (search.refersBack(trimmed, forHazard: id) && search.proposesUse(trimmed, ofHazard: id))
               || search.isFollowUp(trimmed, toHazard: id),
           !search.saysStored(trimmed, forHazard: id),
           !(retrieval.confident.map { $0.entry.id != id } ?? false) {
            var message = guideMessage(for: hazard, notes: [], activeHazards: before.activeHazards)
            message.text += "\n" + Self.precautionNote
            message.suggestedHazard = id
            return .answered(try reply(message))
        }

        // 2c. A water notice in this message. Named with its kind, it is saved and the
        //     question is answered from that kind's entry. Without its kind, KITT asks which
        //     notice it is, unless a kind is already in force here. A message that asks what
        //     notices mean, compares them, or is clearly about something else ("we're under a
        //     boil notice; how much water should we store?") is answered as usual.
        let noticeEntry: (GuideCandidate) -> Bool = { WaterNotice.entryIDs.contains($0.entry.id) }
        let elsewhere = retrieval.confident.map { !noticeEntry($0) } ?? false
        if (!notice.lifted || !notice.kinds.isEmpty), notice.mentionsNotice, !notice.asksMeaning {
            if notice.kinds.count == 1, let kind = notice.kinds.first {
                if before.waterNotice != kind {
                    try log.append(.waterNotice(WaterNoticeChange(kind, sourceText: text)), conversation: conversationID)
                }
                if !elsewhere {
                    return .answered(try reply(noticeAnswer(kind, question: trimmed, activeHazards: before.activeHazards)))
                }
            } else if notice.kinds.isEmpty, !elsewhere {
                if let kind = before.waterNotice {
                    return .answered(try reply(noticeAnswer(kind, question: trimmed, activeHazards: before.activeHazards)))
                }
                return .answered(try reply(askWaterNotice(about: trimmed, unsure: before.waterNoticeUnsure)))
            }
        }

        // 2d. A notice is in force and this question is about using the water ("Can we
        //     shower?", "What about the dog?"): answer from that notice's entry. Under a
        //     do-not-use notice the boil entry's "showering is fine" would be wrong.
        if let kind = before.waterNotice, !notice.lifted, !notice.mentionsNotice, !elsewhere,
           retrieval.candidates.prefix(3).contains(where: noticeEntry) || Self.usesTapWater(trimmed) {
            return .answered(try reply(noticeAnswer(kind, question: trimmed, activeHazards: before.activeHazards)))
        }

        // 3. Arithmetic belongs to the calculator, never to the model.
        //    After a water answer or KITT's household question, a fact or "how much more?"
        //    continues the plan, unless the message clearly belongs to another entry. A
        //    number in words that also describe other things ("for two days") counts only
        //    in a question about water amounts, or in a follow-up that says nothing else.
        let declared = intent.declaredFacts
        let planFacts = intent.asksWater || intent.onlyFacts ? intent.facts : declared
        let otherEntry = retrieval.confident.map { $0.entry.calculator != Self.waterCalculator } ?? false
        // A water-amount question that states the household ("Two adults and two kids, how
        // much water for a week?") goes to the calculator when the water entry leads, even if
        // the extra words keep it from a confident match. Not when someone may need help now:
        // "Nobody has had water for two days" must show the dehydration entry first (4c).
        let statesHousehold = intent.asksWater && !planFacts.isEmpty && !otherEntry
            && top?.entry.calculator == Self.waterCalculator && search.urgentEntries(signalledBy: trimmed).isEmpty
        let wantsWater = retrieval.confident?.entry.calculator == Self.waterCalculator || statesHousehold
            || (before.hasWaterContext && !otherEntry && (intent.asksRemaining || !planFacts.isEmpty))
        if wantsWater, let entry = waterEntry {
            try save(planFacts)
            return .answered(try answerWater(entry: entry, notes: top?.entry.id == entry.id ? top?.notes ?? [] : [],
                                             activeHazards: before.activeHazards))
        }

        // 4. A reliable guide match is shown verbatim, unless an active hazard forbids it.
        if let hit = retrieval.confident {
            if let hazard = overridingHazard(for: hit.entry.id, among: before.activeHazards) {
                return .answered(try reply(reminder(of: hazard)))
            }
            var message = guideMessage(for: hit.entry, notes: hit.notes, activeHazards: before.activeHazards)
            if hit.entry.hazard != nil, !before.activeHazards.contains(hit.entry.id) { message.suggestedHazard = hit.entry.id }
            return .answered(try reply(message))
        }

        // 4b. Unsure which entry is meant, and a hazard entry is one of the candidates. A
        //     missed warning costs more than an unneeded one, so show it instead of
        //     offering it as a button. It is not flagged: a guess must not change how later
        //     turns are answered. "This applies to us", or a follow-up that stays on the
        //     hazard (2b), flags it.
        if let suspected = suspectedHazard(in: retrieval, text: trimmed), !before.activeHazards.contains(suspected.id) {
            var message = guideMessage(for: suspected, notes: [], activeHazards: before.activeHazards)
            message.text += "\n" + Self.precautionNote
            message.suggestedHazard = suspected.id
            return .answered(try reply(message))
        }

        // 4c. Unsure which entry is meant, and the message reports a sign that someone may
        //     need help now: "Nobody has had anything to drink for two days. How long can
        //     we go?", "confused while mowing in the heat". Show that urgent entry first,
        //     with the other candidates as buttons. A topic word alone is not a sign: "we
        //     don't smell gas" and "what should I pack before a heat wave?" get buttons.
        if retrieval.confident == nil {
            let signalled = search.urgentEntries(signalledBy: trimmed)
            let ranked = retrieval.candidates.map(\.entry.id)
            if let urgent = signalled.min(by: { (ranked.firstIndex(of: $0.id) ?? .max) < (ranked.firstIndex(of: $1.id) ?? .max) }),
               overridingHazard(for: urgent.id, among: before.activeHazards) == nil {
                let notes = retrieval.candidates.first { $0.entry.id == urgent.id }?.notes ?? []
                var message = guideMessage(for: urgent, notes: notes, activeHazards: before.activeHazards)
                message.text += "\n" + Self.urgentNote
                // The alternatives: other candidates, but not urgent entries with no sign
                // of their own (no hypothermia button for a heat case), then related entries.
                var buttons: [String] = []
                for c in retrieval.candidates where c.entry.id != urgent.id && !buttons.contains(c.entry.id)
                    && (c.keywordHits > 0 || message.suggestions.contains(c.entry.id) || signalled.contains { $0.id == c.entry.id })
                    && (!c.entry.urgent || signalled.contains { $0.id == c.entry.id })
                    && overridingHazard(for: c.entry.id, among: before.activeHazards) == nil {
                    buttons.append(c.entry.id)
                }
                for id in message.suggestions where id != urgent.id && !buttons.contains(id) { buttons.append(id) }
                message.suggestions = Array(buttons.prefix(3))
                return .answered(try reply(message))
            }
        }

        // 4d. A plain statement of the household ("we're a family of four", "we have 4
        //     gallons stored", "plan for 5 days").
        if !declared.isEmpty {
            try save(declared)
            return .answered(try reply(AssistantMessage(text: "Noted: " + declared.map(describe).joined(separator: ", ") + ".",
                                                        origin: .app)))
        }

        // 5. A follow-up about the entry on screen goes to the model with that entry's passage.
        if modelPolicy == .groundedFollowUps, let focusID = before.focusEntryID, let focus = pack.entry(focusID),
           continuesFocus(trimmed, focus: focus, top: top) {
            return .needsModel(groundedRequest(question: trimmed, focus: focus, activeHazards: before.activeHazards))
        }

        // 5b. KITT asked its question last turn, and this reply neither answered it nor
        //     matched anything else. Ask again rather than drop the question, so a later
        //     "I checked. It's running down there." is still read as the answer.
        if let id = before.pendingQuestion, let question = pack.entry(id)?.hazard?.question,
           !before.activeHazards.contains(id) {
            var message = AssistantMessage(text: "I didn't catch an answer. " + question, origin: .app)
            message.suggestedHazard = id
            message.asksHazardQuestion = true
            return .answered(try reply(message))
        }

        // 5c. KITT asked which notice it is, and this reply neither answered that nor
        //     matched anything else. Ask again.
        if let waiting = before.pendingNoticeQuestion, !notice.lifted {
            return .answered(try reply(askWaterNotice(about: waiting, unsure: false, again: true)))
        }

        // 6. No reliable answer. Say so and offer buttons.
        //    Active hazards lead the buttons, so the warning is never more than a tap away.
        var offered = Array(before.activeHazards.reversed())
        for candidate in retrieval.candidates where Self.worthOffering(candidate) {
            let id = candidate.entry.id
            guard !offered.contains(id), overridingHazard(for: id, among: before.activeHazards) == nil else { continue }
            offered.append(id)
        }
        let message = AssistantMessage(
            text: offered.isEmpty
                ? (modelAvailable
                    ? "The guide doesn't cover that yet. Browse the topics, or ask the model for an unverified answer."
                    : "The guide doesn't cover that yet. Browse the topics.")
                : "I'm not sure which guide entry fits. Is it one of these?",
            origin: .app, suggestions: offered, offersModel: true)
        return .answered(try reply(message))
    }

    /// The user tapped a guide entry (topic list, suggestion button). The entry's own
    /// question is saved as the user's turn so the record reads the same as a typed one.
    public func ask(entryID: String, via method: InputMethod = .suggestion) throws -> TurnOutcome {
        guard let entry = pack.entry(entryID) else { throw KITTError.unknownEntry(entryID) }
        let before = state
        try log.append(.userMessage(text: entry.canonicalQuestion, inputMethod: method), conversation: conversationID)
        if let hazard = overridingHazard(for: entry.id, among: before.activeHazards) {
            return .answered(try reply(reminder(of: hazard)))
        }
        if entry.calculator == Self.waterCalculator {
            return .answered(try answerWater(entry: entry, notes: [], activeHazards: before.activeHazards))
        }
        var message = guideMessage(for: entry, notes: [], activeHazards: before.activeHazards)
        if entry.hazard != nil, !before.activeHazards.contains(entry.id) { message.suggestedHazard = entry.id }
        return .answered(try reply(message))
    }

    /// The user asked for a model reply to the question the guide could not answer.
    /// If the question continues the entry on screen, that entry's passage goes into the
    /// prompt. Active hazards are always put in front of the model.
    public func modelRequestForUnansweredQuestion() -> ModelRequest? {
        let s = state
        guard let question = s.unansweredQuestion else { return nil }
        if let focusID = s.focusEntryID, let focus = pack.entry(focusID),
           continuesFocus(question, focus: focus, top: search.retrieve(question).candidates.first) {
            return groundedRequest(question: question, focus: focus, activeHazards: s.activeHazards)
        }
        let hazards = s.activeHazards.compactMap { self.pack.entry($0) }
        if hazards.isEmpty {
            return ModelRequest(prompt: PromptBuilder.open(question: question, budget: promptBudget), citations: [], sources: [question])
        }
        let warnings = hazards.map(\.modelPassage)
        return ModelRequest(prompt: PromptBuilder.grounded(question: question, passages: [], warnings: warnings, budget: promptBudget),
                            citations: hazards.map(\.citation), sources: warnings + [question])
    }

    /// Save a model reply (possibly partial). Call even when interrupted so the record
    /// shows what the user saw.
    @discardableResult
    public func recordModelReply(_ text: String, for request: ModelRequest, modelID: String, interrupted: Bool) throws -> AssistantMessage {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var reply = AssistantMessage(text: cleaned, origin: .model, citations: request.citations, modelID: modelID, interrupted: interrupted)
        if request.isGrounded {
            if Self.saysNotCovered(cleaned) {
                // The model followed its instruction. Present that as the app's own
                // "not covered", with the way forward, instead of as an answer.
                reply.text = "The guide entry doesn't answer that."
                reply.origin = .app
                reply.suggestions = request.citations.compactMap { pack.entry(forCitation: $0) }.flatMap(\.related)
            } else {
                reply.unsupportedNumbers = NumberCheck.unsupported(in: cleaned, sources: request.sources)
            }
        }
        try log.append(.assistantMessage(reply), conversation: conversationID)
        return reply
    }

    static func saysNotCovered(_ text: String) -> Bool {
        let n = Text.normalize(text)
        return n.contains("guide does not cover") || n.contains("guide doesn't cover") || n.contains("does not cover that")
    }

    // MARK: Answers

    private var waterEntry: GuideEntry? { pack.liveEntries.first { $0.calculator == Self.waterCalculator } }

    private func save(_ facts: [HouseholdFact]) throws {
        for f in facts { try log.append(.householdFact(f), conversation: conversationID) }
    }

    private func reply(_ message: AssistantMessage) throws -> AssistantMessage {
        try log.append(.assistantMessage(message), conversation: conversationID)
        return message
    }

    private func guideMessage(for entry: GuideEntry, notes: [GuideNote], activeHazards: [String]) -> AssistantMessage {
        var text = (notes.filter { $0.lead == true }.map(\.note) + [entry.shortAnswer]).joined(separator: "\n")
        for n in notes where n.lead != true { text += "\n• " + n.note }
        return AssistantMessage(text: text, origin: .guide, citations: [entry.citation],
                                suggestions: related(to: entry, activeHazards: activeHazards))
    }

    /// The entry for the notice in force, with its notes for the question ("baby",
    /// "dishes"), unless an active hazard overrides it.
    private func noticeAnswer(_ kind: WaterNotice, question: String, activeHazards: [String]) -> AssistantMessage {
        if let hazard = overridingHazard(for: kind.entryID, among: activeHazards) { return reminder(of: hazard) }
        guard let entry = pack.entry(kind.entryID) else {
            return AssistantMessage(text: "The guide doesn't cover that yet. Browse the topics.", origin: .app, offersModel: true)
        }
        return guideMessage(for: entry, notes: search.notes(of: entry, for: question), activeHazards: activeHazards)
    }

    /// "What does the notice say?" Unsure: what each notice means first, from its entry.
    /// Whether a weak match is still worth a button. An entry that shares a single word with
    /// the question, not one of its keywords, and explains less than most of it, is a
    /// coincidence: "How do I treat a burn?" shares only "treat" with treating water, and a
    /// water button there would suggest the guide covers burns. Two shared words, one of the
    /// entry's keywords, or most of the question explained, is enough.
    static func worthOffering(_ candidate: GuideCandidate) -> Bool {
        candidate.matchedWords >= 2 || candidate.keywordHits > 0
            || candidate.coverage >= GuideSearch.Tuning().minCoverage
    }

    /// What KITT says when the user asks whether the notice ended, or says a different
    /// notice ended: KITT can't check offline, and the notice it knows of stays in force.
    static func noticeStatus(current: WaterNotice?, otherNoticeLifted: Bool) -> String {
        let check = "Check the latest notice from your water utility."
        guard let current else { return "I can’t verify the notice offline. " + check }
        if otherNoticeLifted { return "Your \(current.answer) notice is still in force. " + check }
        return "I can’t verify the notice offline, so your \(current.answer) notice stays in force. " + check
    }

    private func askWaterNotice(about question: String, unsure: Bool, again: Bool = false) -> AssistantMessage {
        let types = pack.entry(WaterNotice.typesEntryID)
        var message: AssistantMessage
        if unsure, let types {
            message = AssistantMessage(text: "Not sure which notice it is. Here is what each one means:\n" + types.shortAnswer
                                           + "\n" + WaterNotice.question,
                                       origin: .guide, citations: [types.citation])
        } else {
            let lead = again ? "I didn't catch which notice. " : "The answer depends on which notice it is. "
            message = AssistantMessage(text: lead + WaterNotice.question, origin: .app, citations: types.map { [$0.citation] } ?? [])
        }
        message.noticeQuestion = question
        return message
    }

    /// A question about using tap water: "tap" or "faucet", or water with a use.
    static func usesTapWater(_ text: String) -> Bool {
        let words = Set(Text.tokens(Text.normalize(text)))
        if !words.isDisjoint(with: ["tap", "faucet"]) { return true }
        let uses: Set<String> = ["drink", "drinking", "brush", "teeth", "cook", "cooking", "wash", "washing", "shower",
                                 "showering", "bath", "bathe", "ice", "formula", "dishes", "dog", "dogs", "cat", "cats", "pet", "pets"]
        return words.contains("water") && !words.isDisjoint(with: uses)
    }

    private func reminder(of hazard: GuideEntry, prefix: String = "Still applies") -> AssistantMessage {
        let label = hazard.hazard?.label ?? hazard.title
        return AssistantMessage(text: "\(prefix): \(label).\n" + hazard.shortAnswer, origin: .guide, citations: [hazard.citation])
    }

    private func related(to entry: GuideEntry, activeHazards: [String]) -> [String] {
        entry.related.filter { id in
            pack.entry(id).map { $0.review.status != .retired } == true && overridingHazard(for: id, among: activeHazards) == nil
        }
    }

    /// A hazard entry worth showing although no entry matched reliably: it is among the
    /// top candidates, the question names what the hazard is about ("water", "grill"),
    /// and it uses one of the entry's own keywords ("solvent", "barbecue").
    private func suspectedHazard(in retrieval: Retrieval, text: String) -> GuideEntry? {
        guard case let .ambiguous(candidates) = retrieval else { return nil }
        return candidates.first { c in
            c.entry.hazard != nil && c.keywordHits > 0 && search.mentionsSubject(text, ofHazard: c.entry.id)
        }?.entry
    }

    private func overridingHazard(for entryID: String, among active: [String]) -> GuideEntry? {
        for id in active.reversed() {
            if let h = pack.entry(id), h.hazard?.overrides.contains(entryID) == true { return h }
        }
        return nil
    }

    private func answerWater(entry: GuideEntry, notes: [GuideNote], activeHazards: [String]) throws -> AssistantMessage {
        let state = household
        guard let plan = state.waterPlan() else {
            return try reply(AssistantMessage(text: "How many people are in your household? I'll work out the water from that.",
                                              origin: .app, citations: [entry.citation], needsFact: .people))
        }
        try log.append(.calculation(WaterCalculation(plan: plan, guideCitation: entry.citation)), conversation: conversationID)

        var lines: [String] = []
        if let shortfall = plan.shortfall {
            lines.append(shortfall == .zero ? "You have enough for the plan." : "You need \(shortfall.longLabel) more.")
            lines.append(plan.workingLine)
            if let s = plan.shortfallLine { lines.append(s) }
        } else {
            lines.append("Plan for \(plan.required.longLabel).")
            lines.append(plan.workingLine)
        }
        if state.planDays == nil { lines.append("(\(plan.days.label) is the default; tell me if your plan is longer.)") }
        lines.append("Planning baseline from \(entry.source.publisher).")
        for n in notes { lines.append("• " + n.note) }

        return try reply(AssistantMessage(text: lines.joined(separator: "\n"), origin: .guide, citations: [entry.citation],
                                          suggestions: related(to: entry, activeHazards: activeHazards)))
    }

    // MARK: Model

    private func groundedRequest(question: String, focus: GuideEntry, activeHazards: [String]) -> ModelRequest {
        let hazards = activeHazards.compactMap { self.pack.entry($0) }.filter { $0.id != focus.id }
        let warnings = hazards.map(\.modelPassage)
        let prompt = PromptBuilder.grounded(question: question, passages: [focus.modelPassage], warnings: warnings, budget: promptBudget)
        return ModelRequest(prompt: prompt, citations: [focus.citation] + hazards.map(\.citation),
                            sources: warnings + [focus.modelPassage, focus.shortAnswer, question])
    }

    /// Whether a message that matched no entry reliably is still about the entry on screen.
    private func continuesFocus(_ text: String, focus: GuideEntry, top: GuideCandidate?) -> Bool {
        let words = Text.tokens(Text.normalize(text))
        guard words.count <= 14 else { return false }
        if let top, top.entry.id != focus.id { return false }
        return search.sharesTopic(text, with: focus.id) || Self.pointsBack(text)
    }

    /// A short question that refers to what was just said ("is it ok then?").
    static func pointsBack(_ text: String) -> Bool {
        let words = Text.tokens(Text.normalize(text))
        let extra: Set<String> = ["then", "instead", "why", "else"]
        return words.count <= 14 && words.contains { Text.isPointer($0) || extra.contains($0) }
    }

    private func describe(_ f: HouseholdFact) -> String {
        switch f.key {
        case .people: return People(Int(f.value)).label
        case .storedWater: return "\(USGallons(f.value).label) stored"
        case .planDays: return "plan for \(Days(Int(f.value)).label)"
        }
    }
}

public enum KITTError: Error, Equatable {
    case emptyMessage
    case unknownEntry(String)
}
