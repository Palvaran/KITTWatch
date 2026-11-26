import Foundation

/// Pulls household facts and water-planning intent out of plain sentences.
/// Rule-based on purpose: quantities must be exact, and a wrong parse is visible
/// in the saved fact (with the user's words) so it can be corrected.
public struct Interpretation: Equatable, Sendable {
    public var facts: [HouseholdFact] = []
    /// Facts read from words that also describe other things ("for two days", "two
    /// people"), in a message with no planning word: "nobody has had anything to drink for
    /// two days", "is it bad to drink nothing for two days?". They count only when the
    /// message asks about water amounts, or follows a water answer and says nothing else
    /// ("what about for 5 days?").
    public var tentative: Set<HouseholdFact.Key> = []
    /// The message says nothing beyond its numbers: "what about for 5 days?", "and 4 people?".
    public var onlyFacts = false
    /// The facts that state the household plan on their own.
    public var declaredFacts: [HouseholdFact] { facts.filter { !tentative.contains($0.key) } }
    public var asksWater = false
    /// "how much more", "how many more": a follow-up that only makes sense with context.
    public var asksRemaining = false
    public var isEmpty: Bool { facts.isEmpty && !asksWater && !asksRemaining }
}

public enum IntentParser {
    public static func parse(_ text: String) -> Interpretation {
        let s = Text.normalize(text)
        var out = Interpretation()

        // People listed in groups: "two adults and two kids", "2 adults, 3 children and a
        // baby", "one adult with a toddler". At least two groups, side by side, so a single
        // "three kids" (adults unsaid) is not taken for the household. It can describe
        // something else too ("two adults and a child were treated"), so unless the message
        // plans or says it is the household ("we're", "our family"), it is tentative.
        if let group = groupedPeople(in: s) {
            out.facts.append(HouseholdFact(key: .people, value: group.count, sourceText: text))
            if !hasPlanningWord(s), !group.isHousehold {
                out.tentative.insert(.people)
            }
        // People: "household of three", "family of 4", "3 people", "there are five of us", "we are 2"
        // The last pattern also describes events ("two people have been sick").
        } else if let (n, i) = firstMatch(in: s, patterns: [
            #"(?:household|family|group) of (NUM)\b"#,
            #"\b(NUM) of us\b"#,
            #"\bthere(?:'s| is| are) (NUM) of us\b"#,
            #"\bwe(?:'re| are) (NUM)\b(?! (?:days|gallons|gallon|gal)\b)"#,
            #"\b(NUM) (?:people|persons|adults)\b"#,
        ]), n >= 1, n == n.rounded() {
            out.facts.append(HouseholdFact(key: .people, value: n, sourceText: text))
            if i == 4, !hasPlanningWord(s) { out.tentative.insert(.people) }
        }

        // Stored water: "we already have four gallons", "we've got 2.5 gal", "4 gallons on hand".
        // Not when the message is about water used up ("I drank two gallons", "we went
        // through 4 gallons already"): that is not what is on hand.
        if !consumes(s), let n = firstNumber(in: s, patterns: [
            #"\b(?:already have|(?<!do )we have|we've got|we got|(?<!do )i have|i've got|have got|we stored|there's|there is) (NUM) (?:us )?(?:gallons|gallon|gal)\b"#,
            #"\b(NUM) (?:us )?(?:gallons|gallon|gal) (?:on hand|stored|already|in the (?:garage|closet|basement|pantry))\b"#,
        ]) {
            out.facts.append(HouseholdFact(key: .storedWater, value: n, sourceText: text))
        }

        // Plan length: "for three days", "change the plan to five days", "make it 5 days"
        // The last two patterns also describe how long something has lasted ("nobody has had
        // anything to drink for two days", "after a 3 day outage last year").
        if let (n, i) = firstMatch(in: s, patterns: [
            // "last" as a verb ("it has to last 5 days"), not "over the last three days".
            #"\b(?:plan to|plan for|make it|change it to|change the plan to|cover|covering|(?<!the )(?<!past )last|lasting) (NUM) days?\b"#,
            #"\b(NUM) day (?:plan|supply)\b"#,
            #"\b(NUM) days? (?:plan|supply|of water)\b"#,
            #"\bfor (NUM) days?\b"#,
            #"\b(NUM) days? outage\b"#,
        ]), n >= 1, n == n.rounded() {
            out.facts.append(HouseholdFact(key: .planDays, value: n, sourceText: text))
            if i >= 3, !hasPlanningWord(s) { out.tentative.insert(.planDays) }
        // The same in weeks: "for a week", "a two week supply", "make it two weeks".
        } else if let (n, i) = firstMatch(in: s, patterns: [
            #"\b(?:plan to|plan for|make it|change it to|change the plan to|cover|covering|(?<!the )(?<!past )last|lasting) (WEEKS) weeks?\b"#,
            #"\b(WEEKS)[ -]week (?:plan|supply)\b"#,
            #"\b(WEEKS) weeks? (?:plan|supply|of water)\b"#,
            #"\bfor (WEEKS) weeks?\b"#,
        ].map { $0.replacingOccurrences(of: "WEEKS", with: "a|an|NUM") }), n >= 1, n == n.rounded() {
            out.facts.append(HouseholdFact(key: .planDays, value: n * 7, sourceText: text))
            if i >= 3, !hasPlanningWord(s) { out.tentative.insert(.planDays) }
        }

        out.onlyFacts = !out.facts.isEmpty && Text.tokens(s).allSatisfy { w in
            Text.stopwords.contains(w) || factWords.contains(w) || Double(w) != nil || numberWords[w] != nil
        }

        let tokens = Set(Text.tokens(s))
        let mentionsWater = tokens.contains("water") || tokens.contains("gallons") || tokens.contains("gallon")
        // Only amount questions go to the calculator; "is tap water safe?" does not.
        let asksAmount = s.contains("how much") || s.contains("how many") || tokens.contains("enough")
            || tokens.contains("store") || tokens.contains("storing") || tokens.contains("stock") || s.contains("more water")
        out.asksWater = mentionsWater && asksAmount
        out.asksRemaining = s.contains("how much more") || s.contains("how many more")
            || s.contains("how much do we still need") || s.contains("is that enough") || s.contains("do we have enough")
        return out
    }

    // MARK: Numbers

    static let numberWords: [String: Double] = [
        "zero": 0, "one": 1, "a": 1, "an": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "dozen": 12, "couple": 2,
    ]

    static let numPattern: String = {
        let words = numberWords.keys.filter { $0 != "a" && $0 != "an" && $0 != "dozen" && $0 != "couple" }
            .sorted { $0.count > $1.count }.joined(separator: "|")
        return #"(?:\d+(?:\.\d+)?|(?:"# + words + #")(?: and a half)?|a dozen|a couple(?: of)?|half a|a half)"#
    }()

    static func parseNumber(_ raw: String) -> Double? {
        let r = raw.trimmingCharacters(in: .whitespaces)
        if let d = Double(r) { return d }
        if r == "half a" || r == "a half" { return 0.5 }
        if r == "a dozen" { return 12 }
        if r.hasPrefix("a couple") { return 2 }
        var base = r, extra = 0.0
        if r.hasSuffix(" and a half") { base = String(r.dropLast(" and a half".count)); extra = 0.5 }
        return numberWords[base].map { $0 + extra }
    }

    /// Words for people in a household, as counted groups.
    static let personNouns = #"(?:adults?|grown[- ]?ups|kids?|children|child|teens?|teenagers?|toddlers?|bab(?:y|ies)|infants?|seniors?|people|persons)"#

    /// Count a list and check whether the words adjoining it identify the user's household.
    static func groupedPeople(in s: String) -> (count: Double, isHousehold: Bool)? {
        let group = "(?:a|an|" + numPattern + ") " + personNouns
        // Commas are spaces by now: "2 adults, 3 children" reads "2 adults 3 children".
        let list = #"\b"# + group + #"(?:(?: and| plus| with)? "# + group + #")+\b"#
        guard let range = s.range(of: list, options: .regularExpression) else { return nil }
        let found = String(s[range])
        guard let re = try? NSRegularExpression(pattern: "(a|an|" + numPattern + ") " + personNouns) else { return nil }
        var total = 0.0
        for m in re.matches(in: found, range: NSRange(found.startIndex..., in: found)) {
            guard let r = Range(m.range(at: 1), in: found), let v = parseNumber(String(found[r])),
                  v >= 1, v == v.rounded() else { return nil }
            total += v
        }
        let before = String(s[..<range.lowerBound])
        let after = String(s[range.upperBound...])
        // An explicit total can introduce a partial breakdown: "Family of 5: two adults and two kids".
        if let n = firstNumber(in: before, patterns: [#"\b(?:family|household) of (NUM)\s*$"#]),
           n >= 1, n == n.rounded() { return (n, true) }
        let bareCount = ["there are", "there's"].contains(before.trimmingCharacters(in: .whitespaces))
            && Text.tokens(after).isEmpty
        let householdPrefix = #"\b(?:we are|we're|our (?:family|household)(?: is| has| includes| consists of)?|(?:in our (?:family|household) there are)) $"#
        let householdSuffix = #"^ (?:of us|in our (?:family|household))\b"#
        let isHousehold = bareCount || before.range(of: householdPrefix, options: .regularExpression) != nil
            || after.range(of: householdSuffix, options: .regularExpression) != nil
        return (total, isHousehold)
    }

    static func consumes(_ s: String) -> Bool {
        s.range(of: #"\b(?:drank|drunk|used|went through|gone through|finished|spilled|lost|poured out|used up)\b"#,
                options: .regularExpression) != nil
    }

    static func hasPlanningWord(_ s: String) -> Bool {
        // "store" as a verb: "the store has been closed" is not planning.
        s.range(of: #"\b(?:plan|planning|prepare|preparing|storing|stock|stocking)\b|\b(?:need|want|build|keep|have) (?:a |our )?supply\b|(?<!the )(?<!a )(?<!grocery )\bstore\b"#,
                options: .regularExpression) != nil
    }

    /// Words a bare follow-up about the plan may use besides its numbers.
    static let factWords: Set<String> = ["day", "days", "week", "weeks", "people", "person", "persons", "adults", "gallon", "gallons",
                                         "gal", "water", "outage", "last", "lasts", "lasting", "instead", "plan", "half"]

    static func firstNumber(in s: String, patterns: [String]) -> Double? {
        firstMatch(in: s, patterns: patterns)?.0
    }

    /// The number from the first pattern that matches, and that pattern's index.
    static func firstMatch(in s: String, patterns: [String]) -> (Double, Int)? {
        for (i, p) in patterns.enumerated() {
            let pattern = p.replacingOccurrences(of: "NUM", with: numPattern)
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            if let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: s), let v = parseNumber(String(s[r])) {
                return (v, i)
            }
        }
        return nil
    }
}
