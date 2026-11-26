import Foundation

/// One spoken piece of a reply and the silence after it.
public struct SpokenSegment: Equatable, Sendable {
    public var text: String
    /// Seconds of silence before the next segment.
    public var pauseAfter: Double

    public init(_ text: String, pauseAfter: Double = 0) {
        self.text = text
        self.pauseAfter = pauseAfter
    }
}

/// What the watch says for a reply: segments with pauses between them, and whether the
/// reply is urgent (a wrist tap starts with the first instruction).
public struct SpokenReply: Equatable, Sendable {
    public var segments: [SpokenSegment]
    public var urgent: Bool

    public init(segments: [SpokenSegment], urgent: Bool = false) {
        self.segments = segments
        self.urgent = urgent
    }

    /// Everything that is said, without the pauses.
    public var text: String { segments.map(\.text).joined(separator: " ") }

    /// For the command line: "(tap) Leave the area now. [pause 0.6 s] Don't use a phone..."
    public var transcript: String {
        var out = urgent ? "(tap) " : ""
        for (i, s) in segments.enumerated() {
            out += s.text
            if i < segments.count - 1 {
                out += s.pauseAfter > 0 ? String(format: " [pause %.1f s] ", s.pauseAfter) : " "
            }
        }
        return out
    }
}

/// What the watch says aloud for a reply. The screen shows more than the voice should read
/// (the arithmetic, bullet marks, parentheses), and the voice must only offer choices that
/// are buttons on the answer screen, so a reply can be followed and answered without looking.
///
/// The choices mirror the watch's answer screen (ConversationView): the hazard question's
/// three answers, "This applies to us" under a precaution, KITT's own choice lists and a
/// precaution's alternatives are buttons under the answer. A guide answer's related topics
/// sit behind "Related topics", so they are not read.
public enum SpeechText {
    /// The line every voice reads under More › Voice, so voices can be compared by ear.
    /// The guide voice packs record it with the guide replies (guide-voice-lines exports it).
    public static let voiceSample = "Your household plan calls for nine gallons of water."
    /// The answer buttons under KITT's hazard question, in the order the watch shows them.
    public static let hazardAnswers = ["This applies to us", "Not in use", "Not sure"]
    /// Silence after an urgent reply's first instruction.
    public static let urgentPause = 0.6
    /// Silence before the choices, or before "The calculation is on screen."
    public static let choicePause = 0.5
    public static let calculationOnScreen = "The calculation is on screen."

    public static func reply(for message: AssistantMessage, pack: ContentPack, activeHazards: [String] = []) -> SpokenReply {
        // The answer: every line but the calculator's working and its baseline line, which
        // Show calculation holds.
        var answer: [String] = []
        var hasCalculation = false
        for raw in message.text.split(separator: "\n").map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("×") || line.contains(" = ") { hasCalculation = true; continue }
            if hasCalculation, line.hasPrefix("Planning baseline from") { continue }
            let plain = WaterAnswerLayout.plain(line)
            if !plain.isEmpty { answer.append(ended(plain)) }
        }
        if message.origin == .model { answer.insert("Unverified.", at: 0) }

        let entry = message.citations.first.flatMap { pack.entry(forCitation: $0) }
        let urgent = message.origin != .model && entry.map { $0.urgent || $0.hazard != nil } == true

        var segments: [SpokenSegment] = []
        let body = answer.joined(separator: " ")
        if urgent, let split = firstSentence(of: body) {
            // The first instruction stands alone, with the wrist tap, then a pause.
            segments.append(SpokenSegment(split.first, pauseAfter: urgentPause))
            if !split.rest.isEmpty { segments.append(SpokenSegment(split.rest)) }
        } else if !body.isEmpty {
            segments.append(SpokenSegment(body))
        }

        var after: [String] = []
        if hasCalculation { after.append(calculationOnScreen) }
        after.append(contentsOf: choices(for: message, pack: pack, activeHazards: activeHazards))
        if !after.isEmpty {
            if !segments.isEmpty { segments[segments.count - 1].pauseAfter = choicePause }
            segments.append(SpokenSegment(after.joined(separator: " ")))
        }

        return SpokenReply(segments: segments.map { SpokenSegment(spoken($0.text), pauseAfter: $0.pauseAfter) },
                           urgent: urgent)
    }

    /// The reply as one string, pauses left out.
    public static func make(for message: AssistantMessage, pack: ContentPack, activeHazards: [String] = []) -> String {
        reply(for: message, pack: pack, activeHazards: activeHazards).text
    }

    /// Choices the answer screen shows as buttons, as one or two sentences.
    static func choices(for message: AssistantMessage, pack: ContentPack, activeHazards: [String]) -> [String] {
        var out: [String] = []
        let confirmable = message.suggestedHazard.map { !activeHazards.contains($0) && pack.entry($0)?.hazard != nil } ?? false
        if message.noticeQuestion != nil {
            // "What does the notice say?" Its four answers are the buttons.
            return ["Answer: " + list(WaterNotice.answers, joiner: "or") + "."]
        }
        if message.asksHazardQuestion, confirmable {
            // The hazard question's answers are the only thing to choose.
            return ["Answer: " + list(hazardAnswers, joiner: "or") + "."]
        }
        if confirmable { out.append("If this applies to you, tap \(hazardAnswers[0]).") }
        if message.needsFact != nil { out.append("Tap Set household.") }

        let titles = message.suggestions.compactMap { pack.entry($0)?.title }
        if !titles.isEmpty {
            let choosing = message.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
            if message.isPrecaution {
                out.append("Or did you mean: " + list(titles, joiner: "or") + "?")
            } else if message.origin == .app {
                out.append(choosing ? list(titles, joiner: "or") + "." : "Related: " + list(titles, joiner: "and") + ".")
            }
            // A guide answer's related topics are behind the Related topics button: not read.
        }
        return out
    }

    // MARK: Pronunciation

    /// Text as it should be heard: "911" as "nine one one", "103°F" as "103 degrees
    /// Fahrenheit", "Ready.gov" as "Ready dot gov", and parentheses as a pause.
    public static func spoken(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\b911\b"#, with: "nine one one", options: .regularExpression)
        // "59°F to 86°F" -> "59 to 86 degrees Fahrenheit"
        s = s.replacingOccurrences(of: #"(\d+(?:\.\d+)?)\s?°\s?F (to|and) (\d+(?:\.\d+)?)\s?°\s?F\b"#,
                                   with: "$1 $2 $3 degrees Fahrenheit", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d)\s?°\s?F\b"#, with: "$1 degrees Fahrenheit", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d)\s?°\s?C\b"#, with: "$1 degrees Celsius", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\d)\s?°"#, with: "$1 degrees", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b([A-Za-z]+)\.gov\b"#, with: "$1 dot gov", options: .regularExpression)
        // "hot, red skin (dry or damp), or" -> "hot, red skin, dry or damp, or"
        s = s.replacingOccurrences(of: #"\s*\(\s*"#, with: ", ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\)"#, with: ",", options: .regularExpression)
        s = s.replacingOccurrences(of: #",\s*([,.;:?!])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^,\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #",$"#, with: ".", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Helpers

    /// The first sentence and the rest. A full stop only ends a sentence before a space, so
    /// "1.5 liters" and "Ready.gov" stay whole.
    static func firstSentence(of text: String) -> (first: String, rest: String)? {
        guard let r = text.range(of: #"[.!?](?=\s)"#, options: .regularExpression) else { return nil }
        let first = String(text[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (first, rest)
    }

    private static func ended(_ s: String) -> String {
        guard let last = s.last, !".?!:".contains(last) else { return s }
        return s + "."
    }

    /// "A", "A or B", "A, B, or C".
    private static func list(_ items: [String], joiner: String) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(joiner) \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", \(joiner) " + items.last!
        }
    }
}
