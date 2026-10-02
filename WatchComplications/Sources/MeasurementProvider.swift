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
        return ComplicationTimeline.entry(kind: configuration.metric.kind, date: .now)
    }

    func timeline(for configuration: MeasurementIntent, in context: Context) async -> Timeline<MeasurementEntry> {
        ComplicationTimeline.timeline(kind: configuration.metric.kind)
    }

    func recommendations() -> [AppIntentRecommendation<MeasurementIntent>] {
        ComplicationMetric.allCases.map {
            AppIntentRecommendation(intent: MeasurementIntent(metric: $0), description: $0.kind.title)
        }
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
        return ComplicationTimeline.preview(kind: metric.kind, value: number, provenance: .measured,
                                            sourceName: String(localized: "Example source"))
    }
}

/// The stress complication has nothing to configure: it always shows HeartSync's own score.
struct StressProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MeasurementEntry {
        preview()
    }

    func snapshot(for configuration: StressIntent, in context: Context) async -> MeasurementEntry {
        context.isPreview ? preview() : ComplicationTimeline.entry(kind: .stress, date: .now)
    }

    func timeline(for configuration: StressIntent, in context: Context) async -> Timeline<MeasurementEntry> {
        ComplicationTimeline.timeline(kind: .stress)
    }

    /// The one row the watch face's complication list shows for this widget, named as an
    /// estimate like every other place the score appears.
    func recommendations() -> [AppIntentRecommendation<StressIntent>] {
        [AppIntentRecommendation(
            intent: StressIntent(),
            description: String(localized: "complication.stress.listName", defaultValue: "Stress (estimate)",
                                comment: "Name of the stress complication in the watch face's complication list")
        )]
    }

    /// Synthetic, and an estimate like every real stress value.
    private func preview() -> MeasurementEntry {
        ComplicationTimeline.preview(kind: .stress, value: 32, provenance: .estimated,
                                     sourceName: String(localized: "HeartSync estimate"))
    }
}

/// Reading the shared cache and scheduling entries, the same for every complication.
enum ComplicationTimeline {
    static func entry(kind: MetricKind, date: Date) -> MeasurementEntry {
        let snapshot = try? WatchComplicationStore().load()
        return MeasurementEntry(date: date, value: WatchComplicationValue(kind: kind, snapshot: snapshot))
    }

    static func timeline(kind: MetricKind) -> Timeline<MeasurementEntry> {
        let current = entry(kind: kind, date: .now)
        var entries = [current]
        if let transition = current.value.staleTransition(after: current.date) {
            entries.append(MeasurementEntry(date: transition, value: current.value))
        }
        // WatchConnectivity requests reloads when the cache changes. Periodic reads are a
        // fallback only; WidgetKit controls the budget and actual delivery time.
        return Timeline(entries: entries, policy: .after(current.date.addingTimeInterval(30 * 60)))
    }

    /// Synthetic values are restricted to the system's placeholder/gallery preview calls and
    /// never reach the shared cache.
    static func preview(kind: MetricKind, value: Double, provenance: Provenance, sourceName: String) -> MeasurementEntry {
        let now = Date.now
        let snapshot = WatchSnapshot(generatedAt: now, metrics: [WatchMetric(
            kind: kind,
            readings: [WatchSourceReading(id: "preview", sourceName: sourceName,
                                         value: value, timestamp: now.addingTimeInterval(-60),
                                         provenance: provenance, isCompacted: false)],
            omittedSourceCount: 0,
            comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600)
        )])
        return MeasurementEntry(date: now, value: WatchComplicationValue(kind: kind, snapshot: snapshot))
    }
}
