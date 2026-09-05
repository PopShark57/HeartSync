import SwiftUI
import WidgetKit

@main
struct HeartSyncComplications: WidgetBundle {
    var body: some Widget {
        HeartSyncMeasurementWidget()
        HeartSyncWorkoutWidget()
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

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Text(value.kind.shortTitle).font(.caption2).widgetAccentable()
                Text(compactNumber)
                    .font(.title3.bold()).monospacedDigit()
                Text(compactFootnote).font(.caption2)
            }
            .lineLimit(1).minimumScaleFactor(0.65)
        }
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

private struct WorkoutEntry: TimelineEntry { let date: Date }

private struct WorkoutProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorkoutEntry { WorkoutEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (WorkoutEntry) -> Void) {
        completion(WorkoutEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkoutEntry>) -> Void) {
        completion(Timeline(entries: [WorkoutEntry(date: .now)], policy: .never))
    }
}

struct HeartSyncWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HeartSyncWorkout", provider: WorkoutProvider()) { _ in
            WorkoutComplicationView()
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WatchComplicationLink.workout.url)
        }
        .configurationDisplayName("HeartSync Workout")
        .description("Open your workout controls. Recording starts only when you tap Start in HeartSync.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

private struct WorkoutComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("Workout", systemImage: "figure.run")
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label("HeartSync", systemImage: "figure.run").font(.headline).widgetAccentable()
                    Text("Open workout").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryCorner:
                Image(systemName: "figure.run").font(.title2)
                    .widgetLabel { Text("Workout") }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "figure.run").font(.title2).widgetAccentable()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HeartSync workout")
        .accessibilityHint("Open workout controls. Does not start recording.")
    }
}
