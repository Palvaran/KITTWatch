import Foundation

/// Current household facts, folded from the event log.
///
/// Facts are household-wide, so the fold spans every conversation on the device.
/// Single-device builds fold in local append order. When the Mac and watch both
/// change the same fact while apart, milestone 3 must surface both values and ask
/// which to use; `conflicts` is the hook for that and stays empty until then.
public struct HouseholdState: Equatable, Sendable {
    public var people: People?
    public var storedWater: USGallons?
    public var planDays: Days?
    /// Which event last set each fact.
    public var setBy: [HouseholdFact.Key: UUID] = [:]

    public init() {}

    public static func fold(_ events: [ConversationEvent]) -> HouseholdState {
        var s = HouseholdState()
        for e in events {
            guard case let .householdFact(f) = e.payload else { continue }
            s.apply(f)
            s.setBy[f.key] = e.id
        }
        return s
    }

    public mutating func apply(_ f: HouseholdFact) {
        switch f.key {
        case .people: people = People(max(0, Int(f.value.rounded())))
        case .storedWater: storedWater = USGallons(max(0, f.value))
        case .planDays: planDays = Days(max(0, Int(f.value.rounded())))
        }
    }

    /// A plan if we know enough to compute one.
    public func waterPlan() -> WaterPlan? {
        guard let people, people.count > 0 else { return nil }
        return WaterPlan(people: people, days: planDays ?? WaterPlan.defaultDays, stored: storedWater)
    }
}
