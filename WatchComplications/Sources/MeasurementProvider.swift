import WidgetKit
import Foundation

struct MeasurementEntry: TimelineEntry {
    let date: Date
    let value: WatchComplicationValue
}

struct MeasurementProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MeasurementEntry {
        preview(metric: .heartRate)
    }

    func snapshot(for configuration: MeasurementIntent, in context: Context) async -> MeasurementEntry {
        if context.isPreview { return preview(metric: configuration.metric) }
        return entry(metric: configuration.metric, date: .now)
    }

    func timeline(for configuration: MeasurementIntent, in context: Context) async -> Timeline<MeasurementEntry> {
        let current = entry(metric: configuration.metric, date: .now)
        var entries = [current]
        if let transition = current.value.staleTransition(after: current.date) {
            entries.append(MeasurementEntry(date: transition, value: current.value))
        }
        // WatchConnectivity requests reloads when the cache changes. Periodic reads are a
        // fallback only; WidgetKit controls the budget and actual delivery time.
        return Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(30 * 60)))
    }

    func recommendations() -> [AppIntentRecommendation<MeasurementIntent>] {
        ComplicationMetric.allCases.map {
            AppIntentRecommendation(intent: MeasurementIntent(metric: $0), description: $0.kind.title)
        }
    }

    private func entry(metric: ComplicationMetric, date: Date) -> MeasurementEntry {
        let snapshot = try? WatchComplicationStore().load()
        return MeasurementEntry(date: date, value: WatchComplicationValue(kind: metric.kind, snapshot: snapshot))
    }

    /// Synthetic values are restricted to the system's placeholder/gallery preview calls.
    private func preview(metric: ComplicationMetric) -> MeasurementEntry {
        let number: Double
        switch metric {
        case .heartRate: number = 72
        case .restingHeartRate: number = 58
        case .hrvSDNN: number = 42
        case .hrvRMSSD: number = 48
        case .spo2: number = 98
        case .respiratoryRate: number = 14
        case .bodyTemperature: number = 36.8
        }
        let now = Date.now
        let snapshot = WatchSnapshot(generatedAt: now, metrics: [WatchMetric(
            kind: metric.kind,
            readings: [WatchSourceReading(id: "preview", sourceName: String(localized: "Example source"),
                                         value: number, timestamp: now.addingTimeInterval(-60),
                                         provenance: .measured, isCompacted: false)],
            omittedSourceCount: 0,
            comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600)
        )])
        return MeasurementEntry(date: now, value: WatchComplicationValue(kind: metric.kind, snapshot: snapshot))
    }
}
