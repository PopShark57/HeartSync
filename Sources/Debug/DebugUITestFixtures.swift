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

    /// Two Bluetooth sensors with twelve readings each, so a removal test can show that
    /// cancelling changes nothing and confirming deletes exactly one source's rows.
    static let removalSourceIDs = [
        "22222222-2222-2222-2222-222222222222",
        "33333333-3333-3333-3333-333333333333",
    ]

    static func populateRemoval(store: HealthStore) {
        let names = ["Demo Chest Strap", "Demo Finger Sensor"]
        let now = Date.now
        for (index, id) in removalSourceIDs.enumerated() {
            store.upsert(DataSource(id: id, displayName: names[index], transport: .bluetooth))
            for minute in 0..<12 {
                _ = store.append(Reading(
                    id: UUID(stableFrom: "ui-removal-\(id)-\(minute)"),
                    sourceID: id,
                    kind: .heartRate,
                    value: 64 + Double(minute % 4),
                    start: now.addingTimeInterval(-Double(minute + 1) * 60)
                ))
            }
        }
    }
}
#endif
