import SwiftUI

struct WatchDashboardView: View {
    let connection: CompanionSession
    var openCompare: () -> Void

    var body: some View {
        List {
            Button(action: openCompare) {
                Label("Compare devices", systemImage: "square.split.2x1")
                    .font(.headline)
            }
            .watchGlassButton()
            .listRowBackground(Color.clear)
            .accessibilityHint("Open comparison charts for metrics reported by two or more sources")

            if let snapshot = connection.snapshot {
                Section {
                    if snapshot.availability == .unavailable {
                        Label("iPhone data unavailable", systemImage: "lock.iphone")
                        Text("Unlock your iPhone and open HeartSync, then refresh.")
                            .font(.caption)
                    } else if snapshot.metrics.isEmpty {
                        Label("No readings yet", systemImage: "heart.text.square")
                        Text("Connect Apple Health or a sensor in HeartSync on iPhone.")
                            .font(.caption)
                    } else {
                        ForEach(snapshot.metrics) { metric in
                            NavigationLink {
                                WatchMetricDetailView(metric: metric, generatedAt: snapshot.generatedAt)
                            } label: {
                                WatchMetricRow(metric: metric)
                            }
                            .listRowBackground(WatchCardBackground(tint: metric.kind.tint))
                        }
                    }
                } header: {
                    Text("From iPhone")
                } footer: {
                    VStack(alignment: .leading) {
                        Text("Snapshot updated")
                        Text(snapshot.generatedAt, style: .relative)
                        Text("Readings have their own timestamps.")
                    }
                }
            } else {
                Section("From iPhone") {
                    Label("Welcome to HeartSync", systemImage: "heart.fill")
                    Text("Open HeartSync on your paired iPhone to receive your latest readings.")
                        .font(.caption)
                }
            }

            Section {
                Button {
                    connection.requestSyncAll()
                } label: {
                    Label(connection.isSyncingAll ? "Syncing…" : "Sync all sources", systemImage: "arrow.triangle.2.circlepath")
                }
                .watchGlassButton()
                .listRowBackground(Color.clear)
                .disabled(connection.isSyncingAll || !connection.isReachable)
                .accessibilityHint("Asks iPhone to sync Apple Health and Oura, reconnect Bluetooth devices, and import readings stored on rings")
                Button {
                    connection.requestRefresh()
                } label: {
                    Label(connection.isRequesting ? "Requesting…" : "Refresh iPhone data", systemImage: "arrow.clockwise")
                }
                .watchGlassButton()
                .listRowBackground(Color.clear)
                .disabled(connection.isRequesting || !connection.isReachable)
                .accessibilityHint("Sends the readings iPhone already has, after a quick Apple Health check")
                Text(connection.status).font(.caption).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                if let report = connection.lastSyncReport {
                    WatchSyncReportView(report: report)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle("HeartSync")
        .containerBackground(WatchTheme.backdrop, for: .navigation)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    connection.requestSyncAll()
                } label: {
                    if connection.isSyncingAll {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(connection.isSyncingAll || !connection.isReachable)
                .accessibilityLabel(connection.isSyncingAll ? "Syncing all sources" : "Sync all sources")
                .accessibilityHint("Asks iPhone to sync Apple Health and Oura, reconnect Bluetooth devices, and import readings stored on rings")
            }
        }
    }
}

/// What the iPhone reported for the last sync-all, one line per source, with the time it
/// answered. The readings themselves arrive in the next snapshot.
private struct WatchSyncReportView: View {
    let report: WatchSyncReport

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(report.lines, id: \.self) { line in
                Text(line)
            }
            Text("Last sync request \(report.finishedAt, style: .relative) ago")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }
}

private struct WatchMetricRow: View {
    let metric: WatchMetric
    /// Always On: the value stays; tints and secondary lines dim.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(alignment: .leading, spacing: 4) {
                Label(metric.kind.title, systemImage: metric.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(isLuminanceReduced ? AnyShapeStyle(.secondary) : AnyShapeStyle(metric.kind.tint))
                if let reading = metric.readings.first {
                    Text(metric.kind.formatWithUnit(reading.value))
                        .font(.title3.bold()).monospacedDigit()
                        .minimumScaleFactor(0.7).lineLimit(1)
                        // As on the complications: hidden when the wearer's privacy
                        // settings redact sensitive data.
                        .privacySensitive()
                    Group {
                        Text(reading.sourceName).lineLimit(2)
                        HStack {
                            Text(reading.provenance.title)
                            if reading.isStale(kind: metric.kind, now: timeline.date) {
                                Text("Older reading").foregroundStyle(.orange)
                            }
                        }
                    }
                    .font(.caption2)
                    .opacity(isLuminanceReduced ? 0.6 : 1)
                }
                // Always On hides the trend.
                if !isLuminanceReduced, let chart = metric.chart, !chart.series.isEmpty {
                    WatchTrendChart(kind: metric.kind, chart: chart, lookback: metric.comparison.lookback, compact: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct WatchMetricDetailView: View {
    let metric: WatchMetric
    let generatedAt: Date
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @AppStorage(WatchRangeSelection.storageKey) private var selectedRange: WatchChartRange = .standard

    var body: some View {
        List {
            trendSection
            comparisonSection
            ForEach(metric.readings) { reading in
                Section(reading.sourceName) {
                    Text(metric.kind.formatWithUnit(reading.value))
                        .font(.title2.bold()).monospacedDigit()
                        .privacySensitive()
                    Label(reading.provenance.title, systemImage: reading.provenance.systemImage)
                        .font(.caption)
                    Text(reading.timestamp, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                    if reading.isCompacted {
                        Text("Compacted window median").font(.caption).foregroundStyle(.secondary)
                    }
                    if reading.provenance == .estimated {
                        Text("Modelled estimate, not a measurement. Never use this value for medical decisions or device agreement.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if metric.omittedSourceCount > 0 {
                Text("\(metric.omittedSourceCount) more sources on iPhone. Comparison includes all enabled sources.")
                    .font(.caption)
            }
        }
        .navigationTitle(metric.kind.shortTitle)
        .containerBackground(WatchTheme.backdrop, for: .navigation)
    }

    /// Nil from an iPhone build without period choice; the single chart is then shown.
    private var available: [WatchChartRange]? { metric.availableRanges }

    /// The chosen period, or the nearest one this metric has (a daily metric has no 1H or 3H).
    private var range: WatchChartRange? {
        available.flatMap { WatchChartRange.resolved(selectedRange, among: $0) }
    }

    private var chart: WatchChart? {
        if let range { return metric.periodChart(range) }
        return available == nil ? metric.chart : nil
    }

    private var comparison: WatchComparison {
        range.map(metric.periodComparison) ?? metric.comparison
    }

    private var periodText: String {
        range?.spokenTitle ?? WatchChartProjection.periodText(metric.comparison.lookback)
    }

    @ViewBuilder
    private var trendSection: some View {
        Section {
            if let available, !available.isEmpty {
                WatchRangePicker(selection: $selectedRange, available: available)
                    .listRowBackground(Color.clear)
            }
            if let chart, !chart.series.isEmpty {
                if isLuminanceReduced {
                    Text("Trend hidden in Always On.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    WatchTrendChart(kind: metric.kind, chart: chart, lookback: comparison.lookback)
                    WatchChartLegend(chart: chart)
                }
            } else if range != nil {
                Text("No readings from the shown sources in this period.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if available != nil {
                Text("Open HeartSync on iPhone to send this period.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Update HeartSync on iPhone to see trends here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text(periodText)
        } footer: {
            Text("Window medians. Tap or touch and hold the chart to see a window's values. Gaps are missing data. Dashed lines are estimates.")
        }
    }

    @ViewBuilder
    private var comparisonSection: some View {
        Section("Comparison at sync") {
            WatchVerdictLabel(comparison: comparison)
            Text("\(comparison.readyPairs) ready \u{00B7} \(comparison.incompletePairs) incomplete")
                .font(.caption)
            if let chart, let pair = chart.pair {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pair.sourceA) \u{2212} \(pair.sourceB)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text("Mean difference \(WatchChartProjection.signed(pair.meanBias, kind: metric.kind))")
                    Text("95% between \(WatchChartProjection.signed(pair.lowerLimit, kind: metric.kind)) and \(WatchChartProjection.signed(pair.upperLimit, kind: metric.kind))")
                    Text(pair.withinTolerance ? "Mean gap inside tolerance" : "Mean gap outside tolerance")
                        .foregroundStyle(pair.withinTolerance ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    Text("\(pair.pairedWindows) paired windows")
                }
                .font(.caption2).monospacedDigit()
                .privacySensitive()
                .accessibilityElement(children: .combine)
                if !isLuminanceReduced {
                    WatchDifferenceChart(kind: metric.kind, chart: chart, pair: pair)
                }
            }
            // Longer periods are refreshed less often than the snapshot, so say when this
            // period's figures were computed.
            Text("\(periodText) \u{00B7} through \((chart?.end ?? generatedAt).formatted(date: .omitted, time: .shortened))")
                .font(.caption)
            Text("At least five paired windows are needed. Estimates are excluded. Agreement does not establish medical accuracy. Full analysis is on iPhone.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview("Metric detail") {
    let snapshot = WatchPreviewFixtures.snapshot()
    NavigationStack {
        WatchMetricDetailView(metric: snapshot.metrics[0], generatedAt: snapshot.generatedAt)
    }
}
#endif
