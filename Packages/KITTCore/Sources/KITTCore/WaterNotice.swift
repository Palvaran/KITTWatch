import Foundation

/// The three kinds of drinking water notice (CDC): boil water, do not drink, do not use.
/// What is safe depends on which one was issued, so when someone mentions a notice without
/// saying which, KITT asks before answering: "Can I brush my teeth?" is yes with boiled
/// water under a boil notice and no under the other two.
public enum WaterNotice: String, Codable, Sendable, CaseIterable {
    case boil, doNotDrink, doNotUse

    /// The button, and what a tap on it sends.
    public var answer: String {
        switch self {
        case .boil: return "Boil water"
        case .doNotDrink: return "Do not drink"
        case .doNotUse: return "Do not use"
        }
    }

    /// The entry that answers questions while this notice is in force.
    public var entryID: String {
        switch self {
        case .boil: return "water.advisory.boil"
        case .doNotDrink, .doNotUse: return "water.advisory.do-not-drink"
        }
    }

    /// What each kind means, for someone who doesn't know which notice they have.
    public static let typesEntryID = "water.advisory.types"
    /// Every entry about notices.
    public static let entryIDs: Set<String> = Set([typesEntryID] + allCases.map(\.entryID))

    /// KITT's question, and the answer buttons in order.
    public static let question = "What does the notice say?"
    public static let notSure = "Not sure"
    public static let answers = allCases.map(\.answer) + [notSure]

    // MARK: Reading a message

    /// What a message says about a water notice.
    public struct Reading: Equatable, Sendable {
        /// It mentions a notice, alert or advisory about the water, or an instruction to
        /// boil it, not drink it or not use it.
        public var mentionsNotice = false
        /// The kinds it names. Two or more means it is comparing them.
        public var kinds: Set<WaterNotice> = []
        /// It says the notice is over ("the boil notice was lifted").
        public var lifted = false
        /// Kinds explicitly named in a confirmed end, separate from a new notice in the same message.
        var endedKinds: Set<WaterNotice> = []
        var discussesEnd = false
        /// It asks what a notice means rather than saying one was issued.
        public var asksMeaning = false
        /// Sentences that say nothing about a notice, for answering the rest of a message
        /// that also says the notice was lifted.
        public var remainder = ""
    }

    public static func read(_ text: String) -> Reading {
        var r = Reading()
        var rest: [String] = []
        for (raw, isQuestion) in Text.sentences(text) {
            let s = " " + Text.normalize(raw).replacingOccurrences(of: ".", with: " ") + " "
            let kinds = kindsNamed(in: s, isQuestion: isQuestion)
            let mentions = !kinds.isEmpty || noticeWordNearWater(s)
            if mentions {
                r.mentionsNotice = true
                if matches(s, liftedPattern) {
                    r.discussesEnd = true
                    if !isQuestion && matches(s.trimmingCharacters(in: .whitespaces), confirmedEndPattern) {
                        r.lifted = true
                        r.endedKinds.formUnion(kinds)
                        r.kinds.subtract(kinds)
                    }
                } else {
                    r.kinds.formUnion(kinds)
                }
                if matches(s, meaningPattern) { r.asksMeaning = true }
            } else {
                rest.append(raw.trimmingCharacters(in: .whitespaces))
            }
        }
        r.remainder = rest.joined(separator: " ")
        return r
    }

    /// The reply to "What does the notice say?": a kind, `nil` for not sure, or no answer
    /// at all (`.none`). A hedge ("I think it says boil") is not sure: the answer changes
    /// whether boiling is enough, so it is only taken from a plain statement.
    public enum Answer: Equatable, Sendable { case notice(WaterNotice), unsure }

    public static func answer(to text: String) -> Answer? {
        let s = " " + Text.normalize(text).replacingOccurrences(of: ".", with: " ") + " "
        for kind in allCases where Text.normalize(kind.answer) == Text.normalize(text).trimmingCharacters(in: .whitespaces) {
            return .notice(kind)
        }
        // A reply to "What does the notice say?" is a statement. "Should we boil creek
        // water?" is a new question, not the answer "boil".
        if text.contains("?") { return nil }
        if matches(s, unsurePattern) { return .unsure }
        var named: Set<WaterNotice> = []
        let mentionsBoiling = matches(s, #" boil(?:ing|ed)? "#)
        // Accept a named notice or an affirmative instruction. A mention such as
        // "it doesn't say to boil" supplies neither.
        let speaker = #"(?:it|they|the (?:notice|city|(?:water )?utility|message))"#
        let attribution = #"(?:"# + speaker + #" (?:says|said|told us)|we were told)"#
        let instruction = #"boil(?: (?:it|(?:the |our |your |all )?(?:tap |drinking )?water))?(?: for (?:a|one|1) minute)?"#
        let label = #"(?:(?:it is|it's|we have|(?:we are|we're) under|"# + speaker + #" issued) an? )?boil(?: water)? (?:notice|advisory|alert|order)"#
        let answerText = s.trimmingCharacters(in: .whitespaces)
        let quotedInstruction = #"(?:"# + attribution + #" (?:to )?)?"# + instruction + #"(?: "# + attribution + #")?"#
        if matches(answerText, "^(?:" + quotedInstruction + "|" + label + ")$") { named.insert(.boil) }
        if matches(s, #" (do not|dont|don't|not to|no|can ?not|can't|cant|shouldn't|shouldnt) drink"#) { named.insert(.doNotDrink) }
        if matches(s, #" (do not|dont|don't|not to|no|can ?not|can't|cant) use"#)
            || matches(s, #" (no|avoid|avoid all|without) contact"#) || matches(s, #" (do not|dont|don't|not to|can't|cant) touch"#) {
            named.insert(.doNotUse)
        }
        // "Do not drink, and don't boil it" names one kind; "boil" there is the advice not to.
        if matches(s, #" (do not|dont|don't|not to|no|never|cannot|can't|cant|should not|shouldn't|shouldnt) boil"#) {
            named.remove(.boil)
            if named.isEmpty { return .unsure }
        } else if mentionsBoiling && (named.isEmpty || Text.containsPhrase(s, "or")) {
            // A choice such as "boil water or do not drink it" leaves the notice unresolved.
            return .unsure
        }
        if named.count > 1 { return .unsure }
        guard named.count == 1, let kind = named.first else { return nil }
        return matches(s, hedgePattern) ? .unsure : .notice(kind)
    }

    // MARK: Patterns (on normalized text with a space at each end)

    private static let noticeWords = #"(notice|notices|advisory|advisories|alert|alerts|order|orders|warning|warnings)"#
    private static let waterWords = #"(water|tap|faucet|drinking|boil|boiled|utility)"#
    private static let attribution = #"(told|tell|tells|telling|says|said|saying|asked|asking|ordered|orders|want|wants|issued|announced|posted|sent|put out|instructed|warned|advised|advising)"#
    private static let liftedPattern = #" (lifted|lift|lifting|ended|ends|over|cancell?ed|called off|rescinded|removed|expired|no longer|all clear|back to normal|safe again|is off|was off) "#
    // Recognize an affirmative, completed change to the notice itself. A mention of
    // lifting, including a forecast or news about a different area, cannot clear it.
    private static let confirmedEndPattern: String = {
        let subject = #"(?:the |our |this )?(?:(?:boil(?:ed)?(?: water)?|do not (?:use|drink)(?: water)?|drinking water|tap water|water) )"# + noticeWords
        let verb = #"(?:lifted|ended|cancell?ed|called off|rescinded|removed)"#
        let passive = subject + #" (?:(?:has been|was|is|got) (?:officially )?"# + verb + #"|lifted|(?:has )?(?:ended|expired)|is (?:over|off|no longer in (?:force|effect)))"#
        let active = #"(?:they(?:'ve)?|the (?:city|county|utility|water department|water utility|authorities)) (?:has |have )?(?:officially )?"# + verb + " " + subject
        return "^(?:" + passive + "|" + active + #")(?: today| yesterday| this morning| last night| just now)?$"#
    }()
    private static let meaningPattern = #" (mean|means|meaning|difference|kinds|types|explain|what is a|what's a|whats a) "#
    private static let unsurePattern = #" (not sure|unsure|don't know|dont know|do not know|no idea|can't tell|cant tell|can't remember|cant remember|didn't say|didnt say|doesn't say|doesnt say|not certain|no clue) "#
    private static let hedgePattern = #" (i think|maybe|might|probably|i guess|perhaps|possibly|could be|i believe) "#

    /// A notice word within a few words of a water word, in one sentence: "water notice",
    /// "an alert about our tap water", "the water utility issued a notice". A heat advisory
    /// or an emergency alert about the storm is not a water notice.
    private static func noticeWordNearWater(_ s: String) -> Bool {
        let tokens = Text.tokens(s)
        let notice = try! NSRegularExpression(pattern: "^" + noticeWords + "$")
        let water = try! NSRegularExpression(pattern: "^" + waterWords + "$")
        func isMatch(_ re: NSRegularExpression, _ t: String) -> Bool {
            re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        }
        for (i, t) in tokens.enumerated() where isMatch(notice, t) {
            // "heat advisory", "storm warning": a notice word right after another hazard's name.
            if i > 0, ["heat", "storm", "hurricane", "flood", "tornado", "wind", "weather", "winter", "evacuation", "emergency"].contains(tokens[i - 1]) { continue }
            let lo = max(0, i - 4), hi = min(tokens.count - 1, i + 5)
            if (lo...hi).contains(where: { $0 != i && isMatch(water, tokens[$0]) }) { return true }
        }
        return false
    }

    /// Kinds of notice the sentence says are in force, by name ("boil water notice", "do not
    /// drink advisory") or as an instruction someone gave ("they told us to boil our water",
    /// "the city says not to drink the tap water"). A question about boiling ("how long do
    /// we boil water?") is not a notice.
    private static func kindsNamed(in s: String, isQuestion: Bool) -> Set<WaterNotice> {
        var kinds: Set<WaterNotice> = []
        let notice = " " + noticeWords
        let named = matches(s, noticeWords + " ") || matches(s, notice)
        let attributed = matches(s, " " + attribution + " ")

        // Boil water.
        if matches(s, #" boil(ed|ing)?( (the|our|your|all|tap|drinking|any))*( water)?"# + notice)
            || matches(s, notice + #" to boil"#)
            || matches(s, #" under an? boil"#)
            || (matches(s, " " + attribution + #"( (us|you|people|everyone|residents|that|the|city|county))* (to|we|you|everyone|people)( (have|has|need|needs|must|should|got))?( to)? boil"#)
                && matches(s, #" (water|tap|it) "#))
            // "We have to boil our water": a household statement, not "we need to boil water
            // from the creek" (treating it) and not a question.
            || (!isQuestion && matches(s, #"^ (we|i|you)( (have|has|got|must))+( to)? boil (the|our|your|all|tap|all our|all the|any) "#)) {
            kinds.insert(.boil)
        }

        // Do not drink, and do not use.
        let neg = #"(do not|don't|dont|not to|cannot|can't|cant|shouldn't|shouldnt|should not|not supposed to|aren't supposed to|are not supposed to)"#
        let theWater = #"(( (the|our|your|any))*( (tap|faucet|city|drinking))? water| (from|out of)( the)? (tap|faucet))"#
        if matches(s, " " + neg + #" drink"# + notice) || matches(s, #" do not drink "#) && named
            || (attributed && matches(s, " " + neg + " drink" + theWater)) {
            kinds.insert(.doNotDrink)
        }
        if matches(s, " " + neg + #" use"# + notice) || matches(s, #" do not use "#) && named
            || (attributed && (matches(s, " " + neg + " use" + theWater)
                || matches(s, #" (avoid|no)( all| any)? contact with"# + theWater)
                || matches(s, " " + neg + " touch" + theWater))) {
            kinds.insert(.doNotUse)
        }
        return kinds
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}

/// A water notice the user reported, said they weren't sure of, or said was over. Saved
/// as its own event so a later turn (and the Mac) knows which notice is in force.
public struct WaterNoticeChange: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case boil, doNotDrink, doNotUse
        /// The user doesn't know which notice it is. Nothing is assumed; KITT asks again.
        case unknown
        /// The notice is over.
        case lifted
    }
    public var state: State
    public var sourceText: String?

    public init(state: State, sourceText: String? = nil) {
        self.state = state
        self.sourceText = sourceText
    }

    public init(_ notice: WaterNotice, sourceText: String? = nil) {
        self.init(state: State(rawValue: notice.rawValue)!, sourceText: sourceText)
    }

    public var notice: WaterNotice? { WaterNotice(rawValue: state.rawValue) }

    /// How a transcript shows it.
    public var title: String {
        switch state {
        case .boil, .doNotDrink, .doNotUse: return "Water notice: " + (notice?.answer ?? "")
        case .unknown: return "Water notice: not sure which"
        case .lifted: return "Water notice: over"
        }
    }
}
