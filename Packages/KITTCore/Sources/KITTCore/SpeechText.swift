import Foundation

/// What the watch says aloud for a reply. The screen shows more than the voice should
/// read (the arithmetic, the bullet marks), and the voice must say what the screen
/// offers as buttons, so a reply can be followed and answered without looking.
public enum SpeechText {
    /// The answer buttons under KITT's hazard question, in the order the watch shows them.
    public static let hazardAnswers = ["This applies to us", "Not in use", "Not sure"]

    /// - Parameter activeHazards: hazards flagged in the conversation now. A precaution
    ///   for one of them has no "This applies to us" button, so none is read.
    public static func make(for message: AssistantMessage, pack: ContentPack, activeHazards: [String] = []) -> String {
        var sentences: [String] = []
        for raw in message.text.split(separator: "\n").map(String.init) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // The calculator's working ("3 people × 7 days × 1 gal ... = 21 gal") is for
            // reading. The line above it already says the total.
            if line.contains("×") || line.contains(" = ") { continue }
            if line.hasPrefix("• ") { line.removeFirst(2) }
            if line.hasPrefix("("), line.hasSuffix(")") { line = String(line.dropFirst().dropLast()) }
            if !line.isEmpty { sentences.append(ended(line)) }
        }

        let confirmable = message.suggestedHazard.map { !activeHazards.contains($0) && pack.entry($0)?.hazard != nil } ?? false
        if message.asksHazardQuestion, confirmable {
            sentences.append("Answer: " + list(hazardAnswers, joiner: "or") + ".")
        } else {
            if confirmable { sentences.append("If this applies to you, tap \(hazardAnswers[0]).") }
            let titles = message.suggestions.compactMap { pack.entry($0)?.title }
            if !titles.isEmpty {
                // "Is it one of these?" is followed directly by the choices. After a reply
                // shown as a precaution, the others are what the user may have meant.
                let choosing = message.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
                if choosing {
                    sentences.append(list(titles, joiner: "or") + ".")
                } else if message.isPrecaution {
                    sentences.append("Or did you mean: " + list(titles, joiner: "or") + "?")
                } else {
                    sentences.append("Related: " + list(titles, joiner: "and") + ".")
                }
            }
        }

        let spoken = sentences.joined(separator: " ")
        return message.origin == .model ? "Unverified. " + spoken : spoken
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
