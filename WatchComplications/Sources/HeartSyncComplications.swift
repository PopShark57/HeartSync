import SwiftUI
import WidgetKit

@main
struct HeartSyncComplications: WidgetBundle {
    var body: some Widget {
        HeartSyncMeasurementWidget()
        HeartSyncStressWidget()
    }
}

struct HeartSyncMeasurementWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WatchComplicationStore.metricWidgetKind,
                               intent: MeasurementIntent.self, provider: MeasurementProvider()) { entry in
            MeasurementComplicationView(entry: entry)
                .containerBackground(for: .widget) { ComplicationBackground(kind: entry.value.kind) }
                .widgetURL(WatchComplicationLink.metric(entry.value.kind).url)
        }
        .configurationDisplayName("HeartSync Measurement")
        .description("A recent reading from iPhone. Choose heart rate, oxygen, HRV, breathing rate, or temperature. Tap for sources and measurement time.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

/// HeartSync's stress index on the watch face. A separate widget, not a choice in the
/// measurement intent: the stress index is only ever an estimate, and every family says so.
/// Tapping opens the metric on the watch, where its caveat is shown. Its intent has no
/// parameter; it exists so the complication list has a named row (`StressProvider.recommendations`).
struct HeartSyncStressWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WatchComplicationStore.stressWidgetKind,
                               intent: StressIntent.self, provider: StressProvider()) { entry in
            MeasurementComplicationView(entry: entry)
                .containerBackground(for: .widget) { ComplicationBackground(kind: entry.value.kind) }
                .widgetURL(WatchComplicationLink.metric(entry.value.kind).url)
        }
        .configurationDisplayName("HeartSync Stress")
        .description("HeartSync's stress estimate from iPhone, a score out of 100 against your own baseline. An estimate, not a measurement or a medical assessment.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

/// The metric's own hue behind a complication where the system draws a background (the
/// Smart Stack). Watch faces remove it.
struct ComplicationBackground: View {
    let kind: MetricKind

    var body: some View {
        LinearGradient(colors: [kind.tint.opacity(0.45), kind.tint.opacity(0.14)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct MeasurementComplicationView: View {
    let entry: MeasurementEntry
    @Environment(\.widgetFamily) private var family

    private var value: WatchComplicationValue { entry.value }
    private var isStale: Bool { value.isStale(at: entry.date) }

    /// The metric's identity hue (`MetricKind.tint`), grey once there is no current value.
    /// It names the metric and never judges the value: the ring is one hue from light to
    /// full, the same for every reading, and stress gets no band. Full-colour faces draw it;
    /// tinted and vibrant faces recolour the `widgetAccentable` parts themselves.
    private var hue: Color {
        value.reading == nil || isStale ? .gray : value.kind.tint
    }

    private var hueGradient: Gradient {
        Gradient(colors: [hue.mix(with: .white, by: 0.5), hue])
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular: rectangular
            case .accessoryInline:
                Text("\(Image(systemName: value.kind.systemImage)) \(value.kind.shortTitle) \(compactText)")
            case .accessoryCorner:
                Text(compactNumber)
                    .font(.title3.bold()).monospacedDigit()
                    .foregroundStyle(hue.mix(with: .white, by: 0.25))
                    .widgetAccentable()
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
                .foregroundStyle(hue.mix(with: .white, by: 0.25))
        } currentValueLabel: {
            Text(compactNumber)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(hueGradient)
        .widgetAccentable()
    }

    private var circularLabel: String {
        guard let reading = value.reading else { return value.kind.shortTitle }
        if isStale { return String(localized: "Older") }
        if reading.isCompacted { return String(localized: "Median") }
        if reading.provenance == .estimated {
            return String(localized: "complication.estimate.short", defaultValue: "Est.",
                          comment: "Short label in a circular watch complication's opening: the value is HeartSync's estimate, not a measurement")
        }
        if reading.provenance == .derived { return reading.provenance.title }
        return value.kind.shortTitle
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(value.kind.title, systemImage: value.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(hue.mix(with: .white, by: 0.25))
                .widgetAccentable().lineLimit(1)
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
                    } else if reading.provenance != .measured {
                        Text(reading.provenance.title)
                    } else {
                        Text(reading.sourceName)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
        if reading.provenance != .measured { return reading.provenance.title }
        return value.kind.unit
    }

    private var compactText: String {
        guard let reading = value.reading else { return value.emptyMessage }
        if isStale { return String(localized: "Older reading") }
        let formatted = value.kind.formatWithUnit(reading.value)
        if reading.isCompacted { return "\(formatted) · \(String(localized: "Median"))" }
        if reading.provenance != .measured { return "\(formatted) · \(reading.provenance.title)" }
        return formatted
    }

    private var accessibilityText: String {
        guard let reading = value.reading else { return "\(value.kind.title). \(value.emptyMessage)." }
        let time = reading.timestamp.formatted(date: .abbreviated, time: .shortened)
        let age = isStale ? String(localized: "Older reading") : String(localized: "Recent reading")
        let aggregation = reading.isCompacted ? String(localized: "Compacted window median") : ""
        let caveat = reading.provenance == .estimated
            ? String(localized: "complication.estimate.spoken", defaultValue: "HeartSync's estimate, not a measurement.",
                     comment: "Spoken after an estimated value on a watch complication, such as the stress index")
            : ""
        return "\(value.kind.title), \(value.kind.formatWithUnit(reading.value)). \(age). \(reading.provenance.title). \(caveat) \(aggregation) \(reading.sourceName). \(time)."
    }
}

#if DEBUG
/// A current, an older, and a compacted heart rate, so the gauge and its Older and Median
/// labels can be checked in Xcode, and a current and an older stress estimate. Preview-only:
/// nothing here reaches the shared cache.
private enum ComplicationPreviewEntries {
    static func entry(kind: MetricKind = .heartRate, value: Double, age: TimeInterval,
                      provenance: Provenance = .measured, compacted: Bool = false) -> MeasurementEntry {
        let now = Date.now
        let snapshot = WatchSnapshot(generatedAt: now, metrics: [WatchMetric(
            kind: kind,
            readings: [WatchSourceReading(id: "preview", sourceName: "Example source", value: value,
                                         timestamp: now.addingTimeInterval(-age),
                                         provenance: provenance, isCompacted: compacted)],
            omittedSourceCount: 0,
            comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600)
        )])
        return MeasurementEntry(date: now, value: WatchComplicationValue(kind: kind, snapshot: snapshot))
    }
}

#Preview("Circular gauge", as: .accessoryCircular) {
    HeartSyncMeasurementWidget()
} timeline: {
    ComplicationPreviewEntries.entry(value: 72, age: 60)
    ComplicationPreviewEntries.entry(value: 72, age: 6 * 3_600)
    ComplicationPreviewEntries.entry(value: 68, age: 120, compacted: true)
}

#Preview("Stress, circular", as: .accessoryCircular) {
    HeartSyncStressWidget()
} timeline: {
    ComplicationPreviewEntries.entry(kind: .stress, value: 32, age: 120, provenance: .estimated)
    ComplicationPreviewEntries.entry(kind: .stress, value: 32, age: 3_600, provenance: .estimated)
}

#Preview("Stress, rectangular", as: .accessoryRectangular) {
    HeartSyncStressWidget()
} timeline: {
    ComplicationPreviewEntries.entry(kind: .stress, value: 58, age: 120, provenance: .estimated)
}
#endif
