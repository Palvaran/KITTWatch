import Foundation

/// How a water-calculator reply is split on the watch's answer screen. The answer screen
/// keeps everything the user acts on: the headline, the default-duration notice, and
/// guide notes such as "In very hot weather, water needs can double." Show calculation
/// holds the arithmetic and the baseline it came from.
public struct WaterAnswerLayout: Equatable, Sendable {
    /// "Plan for 21 US gallons.", "You need 11 US gallons more.", "You have enough for the plan."
    public var headline: String
    /// Lines that stay on the answer screen, without bullet marks or parentheses.
    public var details: [String]
    /// The working ("3 people × 7 days × 1 gal per person per day = 21 gal") and the
    /// "Planning baseline from ..." line.
    public var calculation: [String]

    public init(text: String) {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        headline = lines.first ?? ""
        details = []
        calculation = []
        for line in lines.dropFirst() {
            if line.contains("×") || line.contains(" = ") || line.hasPrefix("Planning baseline from") {
                calculation.append(line)
            } else {
                details.append(Self.plain(line))
            }
        }
    }

    static func plain(_ line: String) -> String {
        var s = line
        if s.hasPrefix("• ") { s.removeFirst(2) }
        if s.hasPrefix("("), s.hasSuffix(")") { s = String(s.dropFirst().dropLast()) }
        return s
    }
}

extension AssistantMessage {
    /// KITT showed this entry because the question might involve it, not because it was
    /// sure ("(Shown first in case someone needs help now.)"). The other candidates are
    /// the user's alternatives and belong directly under the answer.
    public var isPrecaution: Bool {
        text.hasSuffix(KITTSession.precautionNote) || text.hasSuffix(KITTSession.urgentNote)
    }
}
