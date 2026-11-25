import Foundation

// Published guidance. Read-only at runtime: household edits never touch these records.
// A pack is plain JSON so it can be written and reviewed on the Mac, diffed in git, and
// replaced as a whole on the watch.

public struct GuideSource: Codable, Equatable, Sendable {
    public var publisher: String
    public var title: String
    public var url: String
    /// Date printed on the source, if it has one (ISO 8601 date).
    public var sourceDate: String?
    /// When the wording was checked against the live source.
    public var retrieved: String
}

public struct GuideReview: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, reviewed, retired }
    public var status: Status
    public var reviewer: String?
    public var reviewDate: String?
}

/// Extra line added to an answer when the question mentions one of `terms`
/// ("pets", "heat wave"). It refines the answer; it never replaces it.
public struct GuideNote: Codable, Equatable, Sendable {
    public var terms: [String]
    public var note: String
    /// Shown before the entry's answer instead of after it, for a note that changes what
    /// to do first ("Do not use insulin that has frozen.").
    public var lead: Bool? = nil

    public init(terms: [String], note: String, lead: Bool? = nil) {
        self.terms = terms
        self.note = note
        self.lead = lead
    }
}

/// Marks an entry as a hazard: a detail that changes the right action
/// ("our water smells like gasoline"). A raised hazard outranks every other answer and
/// stays active for the rest of the conversation until the user clears it.
public struct GuideHazard: Codable, Equatable, Sendable {
    /// Banner text while active, e.g. "Possible fuel or chemical contamination".
    public var label: String
    /// Each trigger is a list of slots separated by spaces; every slot must be met by a
    /// word of the message, in any order and any inflection. A slot can offer
    /// alternatives with "|": "water|tap smell|taste gasoline|diesel" matches
    /// "our tap water smells like gasoline". A slot that starts with "!" lists words
    /// that cancel the trigger: "water smell like !chlorine|bleach".
    public var triggers: [String]
    /// While active, a message containing any of these words gets this entry again
    /// instead of ordinary guidance or a model reply ("would boiling help?").
    public var followUpTerms: [String]
    /// Entries that must not be shown while this hazard is active (e.g. boil-water steps).
    public var overrides: [String]
    /// What the hazard is about ("water", "tap"; or "generator", "grill"). When KITT is
    /// unsure which entry a question means and this entry is a candidate, a subject word
    /// in the question is enough to show the warning rather than a button for it.
    public var subjects: [String]
    /// Words that say the user means to do the risky thing ("run", "light", "drink",
    /// "boil"). A follow-up that only points back ("can I run it in the basement?") can
    /// set the flag only if it contains one of these.
    public var useTerms: [String]
    /// Words that say the thing is not in use ("stored", "boxed", "receipt"). A trigger
    /// does not set the flag when the message has one of these and no use term, so
    /// "the generator stays boxed in the garage" is not an exposure.
    public var storageTerms: [String]
    /// Words that report what was seen or happened ("smells", "leaked", "sheen"). Like use
    /// terms, a statement can negate them: "nothing leaked" is not evidence of a leak.
    public var evidenceTerms: [String]
    /// When true, a trigger on its own only says where the thing is ("the generator is in
    /// the basement"). KITT then warns and asks `question` instead of flagging, and flags
    /// once the user describes use, answers yes, or taps "This applies to us".
    public var requiresUse: Bool
    /// The one question asked when `requiresUse` and the message gives no use.
    public var question: String?
    /// In an answer to `question`, words of intent ("planning", "intend") that count as yes.
    public var planTerms: [String]
    /// In an answer to `question`, places that mean the use is not the hazard ("outdoors").
    public var safePlaces: [String]
    /// In an answer to `question`, words that mean the thing is not this hazard at all
    /// ("battery", "electric"). Only answers: "electric start" generators burn fuel.
    public var exemptTerms: [String]

    enum CodingKeys: String, CodingKey {
        case label, triggers, followUpTerms, overrides, subjects, useTerms, storageTerms, evidenceTerms, requiresUse, question
        case planTerms, safePlaces, exemptTerms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        triggers = try c.decode([String].self, forKey: .triggers)
        followUpTerms = try c.decodeIfPresent([String].self, forKey: .followUpTerms) ?? []
        overrides = try c.decodeIfPresent([String].self, forKey: .overrides) ?? []
        subjects = try c.decodeIfPresent([String].self, forKey: .subjects) ?? []
        useTerms = try c.decodeIfPresent([String].self, forKey: .useTerms) ?? []
        storageTerms = try c.decodeIfPresent([String].self, forKey: .storageTerms) ?? []
        evidenceTerms = try c.decodeIfPresent([String].self, forKey: .evidenceTerms) ?? []
        requiresUse = try c.decodeIfPresent(Bool.self, forKey: .requiresUse) ?? false
        question = try c.decodeIfPresent(String.self, forKey: .question)
        planTerms = try c.decodeIfPresent([String].self, forKey: .planTerms) ?? []
        safePlaces = try c.decodeIfPresent([String].self, forKey: .safePlaces) ?? []
        exemptTerms = try c.decodeIfPresent([String].self, forKey: .exemptTerms) ?? []
    }
}

public struct GuideEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var version: Int
    public var title: String
    public var topic: String
    /// Ways people ask this. The first one is the tappable question on the watch.
    public var questionVariants: [String]
    /// Curated keywords and aliases for local search. Multi-word entries match as phrases.
    public var keywords: [String]
    public var applicability: String
    /// The reviewed action. Shown verbatim.
    public var shortAnswer: String
    /// Short passage handed to the model for conversational follow-ups.
    public var modelPassage: String
    public var notes: [GuideNote]
    public var hazard: GuideHazard?
    /// Calculator this entry drives, if any ("water.storage").
    public var calculator: String?
    /// Entries offered as next-step buttons under this answer.
    public var related: [String]
    /// Signs that someone may need help now, in hazard-trigger syntax ("smell|odor
    /// gas|rotten"; "confused|dizzy heat|hot|mowing"). When KITT is unsure which entry a
    /// question means and the message reports one of these signs, not negated, this
    /// entry is shown first and the others are offered as buttons. A slot that lists
    /// negators ("nobody|hasn't") makes the absence itself the sign.
    public var urgentSigns: [String]
    public var urgent: Bool { !urgentSigns.isEmpty }
    public var source: GuideSource
    public var additionalSources: [GuideSource]
    public var sources: [GuideSource] { [source] + additionalSources }
    public var review: GuideReview

    public var citation: String { "\(id)@v\(version)" }
    public var canonicalQuestion: String { questionVariants.first ?? title }

    enum CodingKeys: String, CodingKey {
        case id, version, title, topic, questionVariants, keywords, applicability, shortAnswer
        case modelPassage, notes, hazard, calculator, related, urgentSigns, source, additionalSources, review
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(Int.self, forKey: .version)
        title = try c.decode(String.self, forKey: .title)
        topic = try c.decode(String.self, forKey: .topic)
        questionVariants = try c.decode([String].self, forKey: .questionVariants)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        applicability = try c.decodeIfPresent(String.self, forKey: .applicability) ?? ""
        shortAnswer = try c.decode(String.self, forKey: .shortAnswer)
        modelPassage = try c.decodeIfPresent(String.self, forKey: .modelPassage) ?? shortAnswer
        notes = try c.decodeIfPresent([GuideNote].self, forKey: .notes) ?? []
        hazard = try c.decodeIfPresent(GuideHazard.self, forKey: .hazard)
        calculator = try c.decodeIfPresent(String.self, forKey: .calculator)
        related = try c.decodeIfPresent([String].self, forKey: .related) ?? []
        urgentSigns = try c.decodeIfPresent([String].self, forKey: .urgentSigns) ?? []
        source = try c.decode(GuideSource.self, forKey: .source)
        additionalSources = try c.decodeIfPresent([GuideSource].self, forKey: .additionalSources) ?? []
        review = try c.decode(GuideReview.self, forKey: .review)
    }
}

public struct ContentPack: Codable, Equatable, Sendable {
    public var packID: String
    public var version: Int
    public var title: String
    public var entries: [GuideEntry]

    public func entry(_ id: String) -> GuideEntry? { entries.first { $0.id == id } }

    /// Entry for a citation string ("water.storage.baseline@v2").
    public func entry(forCitation citation: String) -> GuideEntry? {
        entry(citation.split(separator: "@").first.map(String.init) ?? citation)
    }

    /// Entries the watch may show (everything not retired).
    public var liveEntries: [GuideEntry] { entries.filter { $0.review.status != .retired } }

    /// Topics in pack order, for the browse screen.
    public var topics: [String] {
        var seen = Set<String>(), out: [String] = []
        for e in liveEntries where seen.insert(e.topic).inserted { out.append(e.topic) }
        return out
    }

    public func entries(inTopic topic: String) -> [GuideEntry] { liveEntries.filter { $0.topic == topic } }

    public static func load(from url: URL) throws -> ContentPack {
        try JSONDecoder().decode(ContentPack.self, from: Data(contentsOf: url))
    }

    /// The pack that ships inside KITTCore.
    public static func bundled() throws -> ContentPack {
        guard let url = Bundle.module.url(forResource: "guide-pack", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try load(from: url)
    }

    /// Structural problems that would make the pack misbehave on the watch. An empty
    /// result is required before a pack is installed (and is checked by the tests).
    public func problems(maxAnswerCharacters: Int = 420, maxPassageWords: Int = 80) -> [String] {
        var out: [String] = []
        var ids = Set<String>()
        for e in entries {
            if !ids.insert(e.id).inserted { out.append("\(e.id): duplicate id") }
            if e.questionVariants.isEmpty { out.append("\(e.id): no question variants") }
            if e.shortAnswer.count > maxAnswerCharacters {
                out.append("\(e.id): answer is \(e.shortAnswer.count) characters; the watch shows at most \(maxAnswerCharacters) comfortably")
            }
            let words = e.modelPassage.split(separator: " ").count
            if words > maxPassageWords {
                out.append("\(e.id): model passage is \(words) words; each word costs prefill time on the watch (max \(maxPassageWords))")
            }
            if e.sources.contains(where: { $0.url.isEmpty }) { out.append("\(e.id): no source URL") }
        }
        for e in entries {
            for r in e.related where !ids.contains(r) { out.append("\(e.id): related entry \(r) does not exist") }
            for o in e.hazard?.overrides ?? [] where !ids.contains(o) { out.append("\(e.id): overridden entry \(o) does not exist") }
            if let h = e.hazard, h.triggers.isEmpty { out.append("\(e.id): hazard has no triggers") }
        }
        return out
    }
}
