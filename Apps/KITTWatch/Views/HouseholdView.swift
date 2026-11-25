import SwiftUI
import KITTCore

/// Household inputs, kept apart from the published guide. Changes are saved as events
/// and the plan below updates immediately.
struct HouseholdView: View {
    @EnvironmentObject private var model: AppModel
    @State private var people = 3
    @State private var stored = 0.0
    @State private var days = 3
    @State private var loaded = false

    var body: some View {
        Form {
            Section("People") {
                Stepper("\(people)", value: $people, in: 1...12)
            }
            Section("Water on hand") {
                Stepper(USGallons(stored).label, value: $stored, in: 0...200, step: 0.5)
            }
            Section("Plan length") {
                Stepper(Days(days).label, value: $days, in: 1...30)
            }
            Section("Plan") {
                let plan = WaterPlan(people: People(people), days: Days(days), stored: USGallons(stored))
                Text(plan.workingLine).font(.footnote)
                if let line = plan.shortfallLine { Text(line).font(.footnote) }
                Text("Baseline: 1 gal per person per day. Children, nursing mothers, sick people, and hot weather need more.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Household")
        .onAppear {
            guard !loaded else { return }
            let s = model.household
            people = s.people?.count ?? 3
            stored = s.storedWater?.value ?? 0
            days = s.planDays?.count ?? WaterPlan.defaultDays.count
            loaded = true
        }
        .onDisappear(perform: save)
    }

    /// Save only what changed, so the log records real edits.
    private func save() {
        let s = model.household
        var changes: [(HouseholdFact.Key, Double)] = []
        if s.people?.count != people { changes.append((.people, Double(people))) }
        if (s.storedWater?.value ?? 0) != stored { changes.append((.storedWater, stored)) }
        if (s.planDays?.count ?? WaterPlan.defaultDays.count) != days { changes.append((.planDays, Double(days))) }
        model.setFacts(changes)
    }
}
