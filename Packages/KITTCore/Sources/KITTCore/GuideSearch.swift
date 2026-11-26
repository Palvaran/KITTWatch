import Foundation

public struct GuideCandidate: Equatable, Sendable {
    public var entry: GuideEntry
    public var score: Double
    /// Share of the question's content words this entry accounts for (0–1).
    public var coverage: Double
    /// Notes whose terms appeared in the question.
    public var notes: [GuideNote]
    /// How many of the entry's curated keywords (words or phrases) the question used.
    public var keywordHits: Int
}

public enum Retrieval: Equatable, Sendable {
    /// One entry clearly fits: show its reviewed answer.
    case confident(GuideCandidate)
    /// Something matched, but not clearly enough to speak for the user. Offer these as buttons.
    case ambiguous([GuideCandidate])
    case none

    public var confident: GuideCandidate? { if case let .confident(c) = self { return c } else { return nil } }
    public var candidates: [GuideCandidate] {
        switch self {
        case let .confident(c): return [c]
        case let .ambiguous(cs): return cs
        case .none: return []
        }
    }
}

/// Keyword search over the reviewed entries. Deliberately simple and inspectable: the
/// watch must be able to say which reviewed entry it used, and "no reliable match" has
/// to be a real outcome rather than the nearest neighbour of an embedding.
public struct GuideSearch: Sendable {
    public struct Tuning: Equatable, Sendable {
        /// Minimum score for a confident match.
        public var minScore = 2.2
        /// Minimum share of the question's content words explained by the entry.
        public var minCoverage = 0.6
        /// The best entry must beat the runner-up by this factor.
        public var margin = 1.25
        public init() {}
    }

    private static func vocabulary(of hazard: GuideHazard?) -> Set<String> {
        guard let hazard else { return [] }
        var v = Set(hazard.subjects.flatMap { Text.allStems($0) })
        for trigger in hazard.triggers {
            for slot in trigger.split(separator: " ") where !slot.hasPrefix("!") {
                for alt in slot.split(separator: "|") { v.formUnion(Text.allStems(String(alt))) }
            }
        }
        return v.subtracting(Text.stopwords)
    }

    /// One hazard trigger: every `required` slot must be met by a word of the message,
    /// and no `excluded` word may appear.
    private struct Trigger: Sendable {
        var required: [Set<String>] = []
        var excluded: Set<String> = []
        /// A slot lists negators ("nobody|hasn't"): the absence is the evidence, so the
        /// message is not read for negation.
        var usesNegators = false

        init(_ text: String) {
            for slot in text.split(separator: " ") {
                let negative = slot.hasPrefix("!")
                let words = slot.dropFirst(negative ? 1 : 0).split(separator: "|").map { Text.normalize(String($0)) }
                if !negative, words.contains(where: Text.isNegator) { usesNegators = true }
                let stems = Set(words.map { Text.stem($0) }.filter { !$0.isEmpty })
                if negative { excluded.formUnion(stems) } else if !stems.isEmpty { required.append(stems) }
            }
        }

        var requiredStems: Set<String> { required.reduce(into: Set<String>()) { $0.formUnion($1) } }

        func matches(_ stems: Set<String>) -> Bool {
            !required.isEmpty && excluded.isDisjoint(with: stems) && required.allSatisfy { !$0.isDisjoint(with: stems) }
        }
    }

    private struct Indexed: Sendable {
        var entry: GuideEntry
        var stems: Set<String>            // title + variants + keywords
        var keywordStems: Set<String>     // single-word curated keywords
        var phrases: [[String]]           // multi-word keywords and variants, stemmed
        var variantStems: [Set<String>]
        var hazardTriggers: [Trigger]
        var urgentSigns: [Trigger]
        var followUpStems: Set<String>
        var subjectStems: Set<String>
        var useStems: Set<String>
        var storageStems: Set<String>
        var negatableStems: Set<String>
        /// The hazard's own devices, places and chemicals: trigger words and subjects.
        var vocabulary: Set<String>
        var requiresUse: Bool
        var deviceStems: Set<String>
        var planStems: Set<String>
        var safeStems: Set<String>
        var exemptStems: Set<String>
    }

    public let pack: ContentPack
    public var tuning = Tuning()
    private let index: [Indexed]
    private let idf: [String: Double]
    private let maxIDF: Double

    public init(pack: ContentPack) {
        self.pack = pack
        let live = pack.liveEntries
        var built: [Indexed] = []
        for e in live {
            var stems = Set(Text.contentStems(e.title))
            var keywordStems = Set<String>()
            var phrases: [[String]] = []
            for k in e.keywords {
                let s = Text.contentStems(k)
                stems.formUnion(s)
                if s.count == 1 { keywordStems.insert(s[0]) } else if s.count > 1 { phrases.append(s) }
            }
            var variantStems: [Set<String>] = []
            for v in e.questionVariants {
                let s = Set(Text.contentStems(v))
                stems.formUnion(s)
                variantStems.append(s)
            }
            // Words that trigger a note belong to the entry's vocabulary too ("dog", "heat wave").
            for n in e.notes { for t in n.terms { stems.formUnion(Text.contentStems(t)) } }
            built.append(Indexed(
                entry: e, stems: stems, keywordStems: keywordStems, phrases: phrases, variantStems: variantStems,
                hazardTriggers: (e.hazard?.triggers ?? []).map(Trigger.init),
                urgentSigns: e.urgentSigns.map(Trigger.init),
                followUpStems: Set((e.hazard?.followUpTerms ?? []).flatMap { Text.allStems($0) }),
                subjectStems: Set((e.hazard?.subjects ?? []).flatMap { Text.allStems($0) }),
                useStems: Set((e.hazard?.useTerms ?? []).flatMap { Text.allStems($0) }),
                storageStems: Set((e.hazard?.storageTerms ?? []).flatMap { Text.allStems($0) }),
                negatableStems: Set(((e.hazard?.useTerms ?? []) + (e.hazard?.evidenceTerms ?? [])).flatMap { Text.allStems($0) }),
                vocabulary: Self.vocabulary(of: e.hazard),
                requiresUse: e.hazard?.requiresUse ?? false,
                deviceStems: Set((e.hazard?.subjects ?? []).flatMap { Text.allStems($0) }),
                planStems: Set((e.hazard?.planTerms ?? []).flatMap { Text.allStems($0) }),
                safeStems: Set((e.hazard?.safePlaces ?? []).flatMap { Text.allStems($0) }),
                exemptStems: Set((e.hazard?.exemptTerms ?? []).flatMap { Text.allStems($0) })))
        }
        index = built
        var df: [String: Int] = [:]
        for i in built { for s in i.stems { df[s, default: 0] += 1 } }
        let n = Double(max(built.count, 1))
        var weights: [String: Double] = [:]
        for (s, d) in df { weights[s] = log(1 + n / Double(d)) }
        idf = weights
        maxIDF = log(1 + n)
    }

    /// Every entry with a non-zero score, best first.
    public func rank(_ text: String) -> [GuideCandidate] {
        let norm = Text.normalize(text)
        let query = Text.contentStems(text)
        let querySet = Set(query)
        guard !querySet.isEmpty else { return [] }
        let totalMass = querySet.reduce(0.0) { $0 + (idf[$1] ?? maxIDF) }

        return index.compactMap { item -> GuideCandidate? in
            var score = 0.0, mass = 0.0
            var keywordHits = 0
            for s in querySet where item.stems.contains(s) {
                let w = idf[s] ?? maxIDF
                mass += w
                if item.keywordStems.contains(s) { score += w * 1.5; keywordHits += 1 } else { score += w }
            }
            for p in item.phrases where Self.containsSequence(query, p) { score += 1.0; keywordHits += 1 }
            // A question that is nearly one of the written variants is a strong signal.
            let variant = item.variantStems.map { v -> Double in
                guard !v.isEmpty else { return 0 }
                return Double(v.intersection(querySet).count) / Double(v.union(querySet).count)
            }.max() ?? 0
            if variant >= 0.6 { score += variant * 2 }
            guard score > 0 else { return nil }
            let notes = item.entry.notes.filter { n in
                n.terms.contains { Text.containsPhrase(norm, Text.normalize($0)) }
            }
            return GuideCandidate(entry: item.entry, score: score, coverage: totalMass > 0 ? mass / totalMass : 0,
                                  notes: notes, keywordHits: keywordHits)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.id < $1.entry.id }
    }

    /// An entry's notes whose terms appear in the text ("baby", "dishes").
    public func notes(of entry: GuideEntry, for text: String) -> [GuideNote] {
        let norm = Text.normalize(text)
        return entry.notes.filter { n in n.terms.contains { Text.containsPhrase(norm, Text.normalize($0)) } }
    }

    public func retrieve(_ text: String) -> Retrieval {
        let ranked = rank(text)
        guard let top = ranked.first else { return .none }
        let second = ranked.dropFirst().first?.score ?? 0
        if top.score >= tuning.minScore, top.coverage >= tuning.minCoverage, top.score >= second * tuning.margin {
            return .confident(top)
        }
        return .ambiguous(Array(ranked.prefix(3)))
    }

    /// How a message bears on a hazard.
    public enum Reading: Equatable, Sendable {
        /// It describes the hazard: flag it.
        case described
        /// It says where the thing is but not that it is in use (only for hazards with
        /// `requiresUse`): warn and ask.
        case located
    }

    /// Hazards the message describes or locates. A trigger's every slot must be met by a
    /// word the message does not negate, and the message must not say the thing is put
    /// away or rule out using it ("boxed", "I won't start it") without also proposing to
    /// use it.
    public func hazardReadings(of text: String) -> [(entry: GuideEntry, reading: Reading)] {
        index.compactMap { item in reading(item, text: text, context: nil, use: nil).map { (item.entry, $0) } }
    }

    /// Every hazard a message triggers, whether described or only located.
    public func hazardsRaised(by text: String) -> [GuideEntry] { hazardReadings(of: text).map(\.entry) }

    /// For a message that refers back ("can I run *it* in the basement?"): hazards it
    /// describes when read with `context` (the previous user message). The pointer must
    /// not have a referent of its own earlier in the message ("the dryer"), and the
    /// message must propose the use itself, not of another named object ("run the dryer").
    public func hazardsRaised(by text: String, referringTo context: String) -> [GuideEntry] {
        index.filter { item in
            guard Text.pointerRefersBack(text, vocabulary: item.vocabulary) else { return false }
            let use = actions(item, text)
            guard !use.isEmpty else { return false }
            return reading(item, text: text, context: context, use: use) == .described
        }.map(\.entry)
    }

    /// True when a pointer in the message refers back to the previous message rather than
    /// to something the message itself names.
    public func refersBack(_ text: String, forHazard entryID: String) -> Bool {
        guard let item = index.first(where: { $0.entry.id == entryID }) else { return false }
        return Text.pointerRefersBack(text, vocabulary: item.vocabulary)
    }

    /// True when the message proposes the hazard's risky use ("run", "drink"), not negated.
    public func proposesUse(_ text: String, ofHazard entryID: String) -> Bool {
        guard let item = index.first(where: { $0.entry.id == entryID }) else { return false }
        return !actions(item, text).isEmpty || !actions(item, text, certainty: .possible).isEmpty
            || !actions(item, text, certainty: .asked).isEmpty
    }

    /// Use words that belong to this hazard's device, clause by clause, not negated.
    private func actions(_ item: Indexed, _ text: String, extra: Set<String> = [],
                         certainty: Text.Certainty = .certain) -> Set<String> {
        Text.attributedActions(text, actions: item.useStems.union(extra), devices: item.deviceStems,
                               vocabulary: item.vocabulary, negatable: item.negatableStems.union(extra),
                               certainty: certainty)
    }

    /// The user's reply to a hazard's question ("Is it running there...?").
    public enum Answer: Equatable, Sendable { case yes, no, unknown }

    /// Reads a reply to the hazard's question, or nil if it is not an answer. Only plain
    /// statements settle it; a possibility ("it might be running", "maybe we'll run it
    /// there tonight", "no idea if it's running") or a dropped belief ("I thought it was
    /// running") does not.
    ///   - taking it somewhere safe ("we're taking it outdoors")         → no
    ///   - a use that belongs to the device ("we intend to run it there",
    ///     "I can hear it running below me")                              → yes
    ///   - not this hazard at all ("it's the battery power station")      → no
    ///   - stored, off, or use ruled out ("the generator is off",
    ///     "we are not using it", "it will stay boxed")                   → no
    ///   - an intent that belongs to the device ("we're planning to")     → yes
    ///   - a bare yes or no, with nothing uncertain beside it             → yes / no
    /// With a possibility or a dropped belief in the message, a plain yes still counts
    /// ("Not sure yet, but we've decided to start it there tonight"), and so does a plain no
    /// unless a possible use stands beside it ("It's off, but we might run it later").
    /// Anything else is unknown ("It could be running", "Probably not. I'll ask.").
    public func answer(to entryID: String, text: String) -> Answer? {
        guard let item = index.first(where: { $0.entry.id == entryID }) else { return nil }
        let list = Text.clauseList(text)
        let certainties = Text.certainties(list, vocabulary: item.vocabulary)
        let negatable = item.negatableStems.union(item.planStems)
        let own = Text.stems(list, certainties, keeping: .certain, negatable: negatable)
        // "Off" in a question ("If it's running, should I turn it off?") does not say it is off.
        let stated = Text.stems(list.enumerated().map { $0.element.isQuestion && $0.element.answered == nil ? nil : $0.element }
                                    .compactMap { $0 },
                                list.indices.filter { !list[$0].isQuestion || list[$0].answered != nil }.map { certainties[$0] },
                                keeping: .certain, negatable: negatable)
        var settled: Answer?
        if !item.safeStems.isDisjoint(with: own.kept) { settled = .no }
        else if !actions(item, text).isEmpty { settled = .yes }
        else if !item.exemptStems.isDisjoint(with: own.kept) { settled = .no }
        else if isStored(item, stated, use: []) { settled = .no }
        else if !actions(item, text, extra: item.planStems).isEmpty { settled = .yes }

        guard certainties.contains(where: { $0 != .certain }) else {
            if let settled { return settled }
            if let first = Text.tokens(Text.normalize(text)).first {
                if ["yes", "yeah", "yep", "yup", "ya", "sure", "correct", "right", "both", "affirmative"].contains(first) { return .yes }
                if ["no", "nope", "nah", "neither", "negative"].contains(first) { return .no }
            }
            return nil
        }
        if settled == .yes { return .yes }
        // A plain no stands unless a possible use stands beside it ("It's off, but we might run
        // it later"). A question the user then answers does not count against it: "Is it
        // idling? I just looked. The generator is off."
        if settled == .no, actions(item, text, extra: item.planStems, certainty: .possible).isEmpty { return .no }
        return .unknown
    }

    /// The word the user used for the hazard's device ("generator", "grill"), if any.
    public func deviceWord(in text: String, forHazard entryID: String) -> String? {
        guard let item = index.first(where: { $0.entry.id == entryID }) else { return nil }
        return Text.tokens(Text.normalize(text)).first { item.deviceStems.contains(Text.stem($0)) }
    }

    /// True when the message says the thing is put away, or rules out using it, and does
    /// not also propose using it.
    public func saysStored(_ text: String, forHazard entryID: String) -> Bool {
        guard let item = index.first(where: { $0.entry.id == entryID }) else { return false }
        return isStored(item, Text.stemsHonouringNegation(text, negatable: item.negatableStems), use: actions(item, text))
    }

    /// Put away, or use ruled out, and no use that belongs to the device.
    private func isStored(_ item: Indexed, _ own: (kept: Set<String>, negated: Set<String>), use: Set<String>) -> Bool {
        let putAway = !item.storageStems.isDisjoint(with: own.kept) || !item.useStems.isDisjoint(with: own.negated)
        return putAway && use.isEmpty
    }

    private func reading(_ item: Indexed, text: String, context: String?, use: Set<String>?) -> Reading? {
        let own = Text.stemsHonouringNegation(text, negatable: item.negatableStems)
        var all = own.kept
        if let context { all.formUnion(Text.stemsHonouringNegation(context, negatable: item.negatableStems).kept) }
        let attributed = use ?? actions(item, text)
        // A possible use ("we might run it there tonight") is not a described one, but it
        // keeps storage words ("it's off for now") from hiding the warning.
        let possible = actions(item, text, certainty: .possible).union(actions(item, text, certainty: .asked))
        guard item.hazardTriggers.contains(where: { $0.matches(all) }),
              !isStored(item, own, use: attributed.union(possible)) else { return nil }
        let proposesUse = !attributed.isEmpty
        return item.requiresUse && !proposesUse ? .located : .described
    }

    /// Urgent entries whose signs the message reports, not negated: "nobody has had water
    /// to drink", "smells like rotten eggs", "confused while mowing in the heat". "We don't
    /// smell gas" and "everyone here feels fine" report none. Pack order.
    public func urgentEntries(signalledBy text: String) -> [GuideEntry] {
        let plain = Text.allStems(text)
        return index.filter { item in
            item.urgentSigns.contains { sign in
                if sign.usesNegators { return sign.matches(plain) }
                return sign.matches(Text.stemsHonouringNegation(text, negatable: sign.requiredStems).kept)
            }
        }.map(\.entry)
    }

    public func isFollowUp(_ text: String, toHazard entryID: String) -> Bool {
        guard let item = index.first(where: { $0.entry.id == entryID }) else { return false }
        return !item.followUpStems.isDisjoint(with: Text.allStems(text))
    }

    /// True when the message names what a hazard entry is about (its `subjects`).
    public func mentionsSubject(_ text: String, ofHazard entryID: String) -> Bool {
        guard let item = index.first(where: { $0.entry.id == entryID }) else { return false }
        return !item.subjectStems.isDisjoint(with: Text.allStems(text))
    }

    /// Whether the message shares a content word with the entry (used to decide if a
    /// question continues the entry on screen).
    public func sharesTopic(_ text: String, with entryID: String) -> Bool {
        guard let item = index.first(where: { $0.entry.id == entryID }) else { return false }
        return !item.stems.isDisjoint(with: Text.contentStems(text))
    }

    private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
