#if DEBUG
import Foundation

/// Deterministic, read-only-at-runtime fixtures for visual QA of the comparison workflow.
/// Values are fixed while timestamps are anchored near launch so every metric appears in
/// the default 24-hour range.
@MainActor
enum DebugAnalysisFixtures {
    static let sourceAID = "demo.chest-strap"
    static let sourceBID = "demo.optical-ring"

    static func populate(store: HealthStore, now: Date = .now) {
        guard store.source(id: sourceAID) == nil else { return }

        store.upsert(DataSource(
            id: sourceAID,
            displayName: "Demo Chest Strap",
            transport: .bluetooth,
            model: "ECG reference-style sensor"
        ))
        store.upsert(DataSource(
            id: sourceBID,
            displayName: "Demo Optical Ring",
            transport: .oura,
            model: "Optical wearable"
        ))

        let minute = ComparisonEngine.floorToWindow(now.addingTimeInterval(-12 * 60), size: 60)
        for index in 0..<8 {
            let stamp = minute.addingTimeInterval(Double(index) * 60)
            append(store, sourceAID, .heartRate, 70 + Double(index % 3), stamp)
            append(store, sourceBID, .heartRate, 71 + Double(index % 3), stamp.addingTimeInterval(8))
        }

        // Stable bias with one point just outside the resulting limits of agreement.
        for index in 0..<6 {
            let stamp = minute.addingTimeInterval(Double(index) * 60)
            append(store, sourceAID, .spo2, 98, stamp)
            append(store, sourceBID, .spo2, index == 5 ? 91 : 95, stamp.addingTimeInterval(10))
        }

        // Only three paired five-minute windows: collecting, not agreement.
        let fiveMinutes = ComparisonEngine.floorToWindow(now.addingTimeInterval(-20 * 60), size: 300)
        for index in 0..<3 {
            let stamp = fiveMinutes.addingTimeInterval(Double(index) * 300)
            append(store, sourceAID, .hrvRMSSD, 42 + Double(index), stamp)
            append(store, sourceBID, .hrvRMSSD, 50 - Double(index), stamp.addingTimeInterval(20), .derived)
        }

        // Alternating direction: a visible noisy relationship rather than stable bias.
        for index in 0..<6 {
            let stamp = minute.addingTimeInterval(Double(index) * 60)
            append(store, sourceAID, .bodyTemperature, 36.8, stamp)
            let delta = index.isMultiple(of: 2) ? 0.5 : -0.5
            append(store, sourceBID, .bodyTemperature, 36.8 + delta, stamp.addingTimeInterval(5))
        }

        // Both sources report respiratory rate in the range, but never in the same bucket.
        let earlier = ComparisonEngine.floorToWindow(now.addingTimeInterval(-50 * 60), size: 60)
        let later = ComparisonEngine.floorToWindow(now.addingTimeInterval(-20 * 60), size: 60)
        for index in 0..<3 {
            append(store, sourceAID, .respiratoryRate, 14 + Double(index) * 0.2,
                   earlier.addingTimeInterval(Double(index) * 60))
            append(store, sourceBID, .respiratoryRate, 15 + Double(index) * 0.2,
                   later.addingTimeInterval(Double(index) * 60))
        }
    }

    private static func append(
        _ store: HealthStore,
        _ sourceID: String,
        _ kind: MetricKind,
        _ value: Double,
        _ date: Date,
        _ provenance: Provenance = .measured
    ) {
        _ = store.append(Reading(
            id: UUID(stableFrom: "demo.\(sourceID).\(kind.rawValue).\(Int(date.timeIntervalSince1970))"),
            sourceID: sourceID,
            kind: kind,
            value: value,
            start: date,
            provenance: provenance
        ))
    }
}
#endif
