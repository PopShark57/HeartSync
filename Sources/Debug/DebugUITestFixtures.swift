#if DEBUG
import Foundation

@MainActor
enum DebugUITestFixtures {
    static func populateDevices(store: HealthStore, includeHistory: Bool) {
        let source = DataSource(
            id: "11111111-1111-1111-1111-111111111111",
            displayName: "Demo Wrist Sensor",
            transport: .bluetooth,
            model: "Fixture 1",
            bodyLocation: .wrist,
            sensingTechnology: .opticalPPG
        )
        store.upsert(source)
        guard includeHistory else { return }
        let now = Date.now
        for day in 8...12 {
            _ = store.append(Reading(
                id: UUID(stableFrom: "ui-retention-\(day)"),
                sourceID: source.id,
                kind: .heartRate,
                value: 70 + Double(day % 3),
                start: now.addingTimeInterval(-Double(day) * 86_400)
            ))
        }
    }
}
#endif
