import Foundation

/// Water-storage planning with explicit units.
/// Baseline: at least 1 US gallon per person per day (Ready.gov / FEMA, CDC).
/// The baseline lives in the guide entry; the planner only does arithmetic on it.
public struct WaterPlan: Equatable, Codable, Sendable {
    public var people: People
    public var days: Days
    public var rate: GallonsPerPersonDay
    public var stored: USGallons?

    public init(people: People, days: Days,
                rate: GallonsPerPersonDay = WaterPlan.baselineRate,
                stored: USGallons? = nil) {
        self.people = people
        self.days = days
        self.rate = rate
        self.stored = stored
    }

    public static let baselineRate = GallonsPerPersonDay(1)
    public static let defaultDays = Days(3)

    public var required: USGallons { rate * (people, days) }

    /// How much more to store. Zero when already covered.
    public var shortfall: USGallons? {
        guard let stored else { return nil }
        return stored >= required ? .zero : required - stored
    }

    /// How much is stored beyond the plan, if any.
    public var surplus: USGallons? {
        guard let stored, stored > required else { return nil }
        return stored - required
    }

    /// "3 people × 3 days × 1 gal per person per day = 9 gal"
    public var workingLine: String {
        "\(people.label) × \(days.label) × \(rate.label) = \(required.label)"
    }

    /// "9 gal needed − 4 gal stored = 5 gal more"
    public var shortfallLine: String? {
        guard let stored, let shortfall else { return nil }
        if let surplus { return "\(stored.label) stored covers \(required.label), \(surplus.label) to spare" }
        return "\(required.label) needed − \(stored.label) stored = \(shortfall.label) more"
    }
}
