import SwiftUI
import WidgetKit

@main
struct HeartSyncComplications: WidgetBundle {
    var body: some Widget {
        HeartSyncMeasurementWidget()
    }
}

struct HeartSyncMeasurementWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WatchComplicationStore.metricWidgetKind,
                               intent: MeasurementIntent.self, provider: MeasurementProvider()) { entry in
            MeasurementComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WatchComplicationLink.metric(entry.value.kind).url)
        }
        .configurationDisplayName("HeartSync Measurement")
        .description("A recent reading from iPhone. Choose heart rate, oxygen, HRV, breathing rate, or temperature. Tap for sources and measurement time.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct MeasurementComplicationView: View {
    let entry: MeasurementEntry
    @Environment(\.widgetFamily) private var family

    private var value: WatchComplicationValue { entry.value }
    private var isStale: Bool { value.isStale(at: entry.date) }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: rectangular
            case .accessoryInline:
                Text("\(Image(systemName: value.kind.systemImage)) \(value.kind.shortTitle) \(compactText)")
            case .accessoryCorner:
                Text(compactNumber)
                    .font(.title3.bold()).monospacedDigit()
                    .widgetCurvesContent()
                    .widgetLabel { Text("\(value.kind.shortTitle) · \(compactFootnote)") }
            default: circular
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Open HeartSync for sources and measurement time")
        .privacySensitive()
    }

    /// A gauge over the metric's nominal display range. The number sits in the centre and
    /// the label in the ring's opening: Older or Median when either applies, otherwise the
    /// metric's short name. An older reading shows an empty ring and a dash, as before,
    /// rather than a full-strength arc for a value that is no longer current.
    private var circular: some View {
        let range = value.kind.displayRange
        let shown = value.reading.flatMap { isStale ? nil : $0.value }
        return Gauge(value: min(max(shown ?? range.lowerBound, range.lowerBound), range.upperBound), in: range) {
            Text(circularLabel)
        } currentValueLabel: {
            Text(compactNumber)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }

    private var circularLabel: String {
        guard let reading = value.reading else { return value.kind.shortTitle }
        if isStale { return String(localized: "Older") }
        if reading.isCompacted { return String(localized: "Median") }
        if reading.provenance == .derived { return reading.provenance.title }
        return value.kind.shortTitle
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(value.kind.title, systemImage: value.kind.systemImage)
                .font(.caption).widgetAccentable().lineLimit(1)
            if let reading = value.reading {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value.kind.formatWithUnit(reading.value)).font(.headline).monospacedDigit()
                    if isStale { Text("Older").font(.caption2) }
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 3) {
                    Text(reading.timestamp, style: .relative)
                    Text("·")
                    if reading.isCompacted {
                        Text("Median")
                    } else if reading.provenance == .derived {
                        Text(reading.provenance.title)
                    } else {
                        Text(reading.sourceName)
                    }
                }
                .font(.caption2).lineLimit(1)
            } else {
                Text(value.emptyMessage).font(.headline)
                Text("Sync from iPhone").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactNumber: String {
        guard let reading = value.reading, !isStale else { return "—" }
        return value.kind.format(reading.value)
    }

    private var compactFootnote: String {
        guard let reading = value.reading else { return value.emptyMessage }
        if isStale { return String(localized: "Older") }
        if reading.isCompacted { return String(localized: "Median") }
        if reading.provenance == .derived { return reading.provenance.title }
        return value.kind.unit
    }

    private var compactText: String {
        guard let reading = value.reading else { return value.emptyMessage }
        if isStale { return String(localized: "Older reading") }
        let formatted = value.kind.formatWithUnit(reading.value)
        if reading.isCompacted { return "\(formatted) · \(String(localized: "Median"))" }
        if reading.provenance == .derived { return "\(formatted) · \(reading.provenance.title)" }
        return formatted
    }

    private var accessibilityText: String {
        guard let reading = value.reading else { return "\(value.kind.title). \(value.emptyMessage)." }
        let time = reading.timestamp.formatted(date: .abbreviated, time: .shortened)
        let age = isStale ? String(localized: "Older reading") : String(localized: "Recent reading")
        let aggregation = reading.isCompacted ? String(localized: "Compacted window median") : ""
        return "\(value.kind.title), \(value.kind.formatWithUnit(reading.value)). \(age). \(reading.provenance.title). \(aggregation) \(reading.sourceName). \(time)."
    }
}

#if DEBUG
/// A current, an older, and a compacted heart rate, so the gauge and its Older and Median
/// labels can be checked in Xcode. Preview-only: nothing here reaches the shared cache.
private enum ComplicationPreviewEntries {
    static func entry(value: Double, age: TimeInterval, compacted: Bool = false) -> MeasurementEntry {
        let now = Date.now
        let snapshot = WatchSnapshot(generatedAt: now, metrics: [WatchMetric(
            kind: .heartRate,
            readings: [WatchSourceReading(id: "preview", sourceName: "Example source", value: value,
                                         timestamp: now.addingTimeInterval(-age),
                                         provenance: .measured, isCompacted: compacted)],
            omittedSourceCount: 0,
            comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600)
        )])
        return MeasurementEntry(date: now, value: WatchComplicationValue(kind: .heartRate, snapshot: snapshot))
    }
}

#Preview("Circular gauge", as: .accessoryCircular) {
    HeartSyncMeasurementWidget()
} timeline: {
    ComplicationPreviewEntries.entry(value: 72, age: 60)
    ComplicationPreviewEntries.entry(value: 72, age: 6 * 3_600)
    ComplicationPreviewEntries.entry(value: 68, age: 120, compacted: true)
}
#endif
