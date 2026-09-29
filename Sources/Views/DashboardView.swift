import Charts
import Combine
import SwiftUI

/// The live side-by-side view: every metric, every device that reports it, in one column.
///
/// This is the app's primary screen. The agreement badge on each card is the secondary
/// read \u{2014} it annotates the same numbers rather than living on a separate screen \u{2014} and it
/// is built with the same epoch-aligned windowing the Compare tab uses, so the two screens
/// cannot contradict each other about the same devices at the same moment.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date.now
    /// Resolved off the render path. It used to be rebuilt inside `body`, and `body` re-ran
    /// on every Bluetooth reading, so one 1 Hz strap re-read the store once a second on the
    /// main actor from inside a view update.
    @State private var snapshot: DashboardSnapshot?
    @State private var lastLoadedAt: Date?
    @State private var lastRetryToken = 0
    /// Bumped by the retry button so the load key changes and the query runs again.
    @State private var retryToken = 0

    /// Clock for the freshness cutoff, not for the timestamps.
    ///
    /// `Text(_:format: .relative)` re-renders itself, so the old 1 Hz tick was not what
    /// kept "3 minutes ago" honest. What genuinely needs a clock is the 15-minute
    /// staleness cutoff and the roll-over into a new comparison bucket: without a tick, a
    /// device that stops reporting keeps its row until some other observed change
    /// invalidates the view. Thirty seconds bounds both errors well inside the shortest
    /// comparison window (60 s) at a thirtieth of the previous cost.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// What a reload depends on: new data, the freshness clock, and an explicit retry.
    private struct LoadKey: Hashable {
        var generation: Int
        var tick: Date
        var retryToken: Int
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.store.sources.isEmpty {
                    EmptyStateView(
                        systemImage: "sensor.tag.radiowaves.forward",
                        title: "No devices yet",
                        message: "Add a Bluetooth sensor, connect Apple Health, or link your Oura account to start collecting readings."
                    )
                } else if let snapshot {
                    if let failure = snapshot.queryFailure, snapshot.metrics.isEmpty {
                        // A failed read is not "waiting for data": that would be a claim
                        // about the user's devices this screen cannot support.
                        List {
                            HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                                .accessibilityIdentifier("now.unavailable")
                        }
                    } else if snapshot.metrics.isEmpty {
                        EmptyStateView(
                            systemImage: "hourglass",
                            title: "Waiting for data",
                            message: "Your devices are connected but haven't reported anything yet. Wearables often take a minute to start streaming."
                        )
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                sourcesHeader
                                // One column on iPhone; as many 320-point columns as fit on
                                // iPad or in landscape.
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)],
                                    spacing: 16
                                ) {
                                    ForEach(snapshot.metrics) { summary in
                                        MetricCard(
                                            summary: summary,
                                            isBluetoothStreaming: summary.rows.contains {
                                                streamingSourceIDs.contains($0.source.id)
                                            }
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                        }
                    }
                } else {
                    ProgressView()
                        .accessibilityIdentifier("now.loading")
                }
            }
            // One read per reload, at most once a second while readings stream in. Every
            // card is built from the same snapshot, so they all describe the same instant.
            .task(id: LoadKey(generation: model.store.changeToken, tick: now, retryToken: retryToken)) {
                let retried = retryToken != lastRetryToken
                let wait = LiveReloadPolicy.delay(
                    dataOnly: !retried,
                    elapsed: lastLoadedAt.map { Date.now.timeIntervalSince($0) },
                    minimumInterval: LiveReloadPolicy.liveScreenInterval
                )
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                let history = model.store.history
                let cache = snapshot?.sparklineCache ?? [:]
                let resolved = await HealthHistory.offMain {
                    DashboardSnapshot(history: history, now: .now, sparklineCache: cache)
                }
                guard !Task.isCancelled else { return }
                snapshot = resolved
                lastLoadedAt = .now
                lastRetryToken = retryToken
            }
            .background { HeartSyncAmbientBackground() }
            .navigationTitle("Now")
            // The large title shares the toolbar's row with Refresh instead of taking a
            // second band of its own above the content.
            .toolbarTitleDisplayMode(.inlineLarge)
            .heartSyncChrome()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.healthKit.isSyncing || model.oura.isSyncing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh")
                    }
                }
            }
            .refreshable { await model.refresh() }
            .onReceive(tick) { now = $0 }
        }
    }

    /// Bluetooth sources whose connection is currently streaming.
    private var streamingSourceIDs: Set<String> {
        Set(model.store.enabledSources.compactMap { source in
            guard source.transport == .bluetooth,
                  case .streaming = model.bluetooth.connectionState(forSource: source.id)
            else { return nil }
            return source.id
        })
    }

    /// Enabled sources with an active connection or authorization, each with what it may
    /// honestly claim. Only a streaming Bluetooth source is Live.
    private var sourceChips: [(source: DataSource, status: SourceChipStatus)] {
        let streaming = streamingSourceIDs
        return model.store.enabledSources.compactMap { source in
            let lastSyncedAt: Date?
            switch source.transport {
            case .bluetooth:
                guard model.bluetooth.connectionState(forSource: source.id).isActive else { return nil }
                lastSyncedAt = nil
            case .healthKit:
                guard model.healthKit.availability == .authorized else { return nil }
                lastSyncedAt = model.healthKit.lastSyncedAt
            case .oura:
                guard model.oura.status.isConnected else { return nil }
                lastSyncedAt = model.oura.lastSyncedAt
            case .manual:
                return nil
            }
            let status = SourceChipStatus.resolve(
                transport: source.transport,
                isStreaming: streaming.contains(source.id),
                lastSyncedAt: lastSyncedAt
            )
            return (source, status)
        }
    }

    /// Hidden entirely when nothing qualifies: an empty row under a title says nothing.
    ///
    /// No separate "Sources" heading: the chips sit directly under the title, where they
    /// read as the screen's subtitle, and the vertical room goes to the cards.
    @ViewBuilder
    private var sourcesHeader: some View {
        let chips = sourceChips
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassChipRow {
                    ForEach(chips, id: \.source.id) { chip in
                        SourceChip(source: chip.source, status: chip.status, now: now)
                    }
                }
                .padding(.vertical, 4)
            }
            // Chips scroll edge to edge; the first and last still line up with the cards.
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sources")
            .accessibilityIdentifier("now.sources")
        }
    }
}

/// One source in the Sources header, with a status it can support.
private struct SourceChip: View {
    var source: DataSource
    var status: SourceChipStatus
    var now: Date

    var body: some View {
        let title = status.title(relativeTo: now)
        HStack(spacing: 6) {
            SourceDot(color: source.color, size: 8)
            Text(source.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(title)
                .font(.caption2.weight(status == .live ? .semibold : .regular))
                .foregroundStyle(status == .live ? AnyShapeStyle(source.color) : AnyShapeStyle(.secondary))
            if let battery = source.batteryPercent {
                BatteryMeter(percent: battery, isCharging: source.batteryIsCharging ?? false, width: 18)
                Text("\(battery)%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(battery <= 15 && source.batteryIsCharging != true ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .heartSyncGlassCapsule(tint: source.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(title))
    }

    private func accessibilityText(_ title: String) -> String {
        var parts = [source.displayName, title.lowercased()]
        if let battery = source.batteryPercent {
            parts.append(BatteryBadge.spoken(percent: battery, isCharging: source.batteryIsCharging ?? false).lowercased())
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Card

/// One metric, with every reporting source stacked beneath a consensus value.
///
/// Takes a resolved summary rather than the model: everything on this card came from the
/// screen's single snapshot, so drawing it costs no store reads.
private struct MetricCard: View {
    var summary: MetricSummary
    /// A Bluetooth source on this card is streaming right now.
    var isBluetoothStreaming: Bool

    /// Keeps the larger Now numerals while still tracking Dynamic Type (fixed 34pt does not).
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(summary.kind.title)
                } icon: {
                    // Pulses only for a genuinely streaming Bluetooth heart rate. SF Symbol
                    // effects follow Reduce Motion on their own.
                    Image(systemName: summary.kind.systemImage)
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            isActive: summary.kind == .heartRate && isBluetoothStreaming
                        )
                }
                .font(.headline)
                .foregroundStyle(summary.kind.tint)
                Spacer()
                if let headline = summary.headline {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(summary.kind.format(headline))
                            .font(.system(size: headlineSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText(value: headline))
                            .animation(reduceMotion ? nil : .snappy, value: headline)
                        Text(summary.kind.unit)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(headlineAccessibilityLabel(headline))
                }
            }

            if let comparison = summary.comparison {
                VStack(alignment: .leading, spacing: 4) {
                    AgreementBadge(
                        severity: comparison.severity,
                        spread: comparison.spread,
                        kind: summary.kind,
                        sourceCount: comparison.sourceCount
                    )
                    Text("\(comparison.sourceCount) devices measured in the same \(WindowLabel.length(comparison.windowSize)) window.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let detail = summary.notComparedDetail {
                ComparisonUnavailableNote(detail: detail)
            }

            if let sparkline = summary.sparkline {
                SparklineView(
                    sparkline: sparkline,
                    sources: Dictionary(summary.rows.map { ($0.source.id, $0.source) }, uniquingKeysWith: { first, _ in first })
                )
            }

            VStack(spacing: 2) {
                ForEach(summary.rows) { row in
                    SourceValueRow(
                        source: row.source,
                        kind: summary.kind,
                        value: row.value,
                        provenance: row.provenance,
                        timestamp: row.timestamp,
                        deltaFromWindowConsensus: row.deltaFromWindowConsensus
                    )
                }
            }

            if summary.rows.contains(where: { $0.source.id == AppModel.estimateSourceID }),
               summary.kind == .bloodPressureSystolic || summary.kind == .bloodPressureDiastolic {
                EstimateDisclaimer(text: Estimators.BloodPressureEstimate.disclaimer)
            }

            NavigationLink {
                MetricDetailView(kind: summary.kind)
            } label: {
                HStack {
                    Text("History and agreement")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                // Apple's minimum hit target is 44 × 44 points.
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .heartSyncGlassCapsule(tint: summary.kind.tint, interactive: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(summary.kind.tint)
            .accessibilityLabel("History and agreement for \(summary.kind.title)")
        }
        .metricCard(tint: summary.kind.tint)
    }

    /// Says which number this is, because the headline means different things depending on
    /// whether the devices could be compared.
    private func headlineAccessibilityLabel(_ value: Double) -> String {
        let formatted = summary.kind.formatWithUnit(value)
        return summary.comparison == nil
            ? "\(summary.kind.title), latest reading \(formatted)"
            : "\(summary.kind.title), window consensus \(formatted)"
    }
}

// MARK: - Sparkline

/// An axis-free trend: the gap rules of every other chart (`ChartSegmentation`), windowed
/// medians only, a monotone line that cannot overshoot, and a pinned domain so a quiet
/// stretch stays empty. It is not interactive; the full chart is one tap away.
private struct SparklineView: View {
    var sparkline: Sparkline
    var sources: [String: DataSource]

    var body: some View {
        Chart {
            ForEach(sparkline.series) { series in
                let color = sources[series.sourceID]?.color ?? .secondary
                let isolated = series.isolated
                ForEach(Array(series.points.enumerated()), id: \.offset) { index, point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(sparkline.kind.title, point.value),
                        series: .value(
                            "Series",
                            ChartSegmentation.key(series: series.sourceID, segment: series.segments[index])
                        )
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .foregroundStyle(color)
                    if isolated.contains(index) {
                        PointMark(x: .value("Time", point.date), y: .value(sparkline.kind.title, point.value))
                            .symbolSize(14)
                            .foregroundStyle(color)
                    }
                }
            }
        }
        .chartXScale(domain: sparkline.start...sparkline.through)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: HeartSyncTheme.Chart.sparklineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sparkline.spokenSummary(names: sources.mapValues(\.displayName)))
        .accessibilityIdentifier("now.sparkline.\(sparkline.kind.rawValue)")
    }
}
