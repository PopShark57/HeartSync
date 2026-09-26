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
                            LazyVStack(spacing: 16) {
                                summaryHeader
                                ForEach(snapshot.metrics) { summary in
                                    MetricCard(summary: summary)
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
                snapshot = DashboardSnapshot(store: model.store, now: .now)
                lastLoadedAt = .now
                lastRetryToken = retryToken
            }
            .background { HeartSyncAmbientBackground() }
            .navigationTitle("Now")
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

    private var summaryHeader: some View {
        let connected = model.store.enabledSources.filter { source in
            switch source.transport {
            case .bluetooth: model.bluetooth.connectionState(forSource: source.id).isActive
            case .healthKit: model.healthKit.availability == .authorized
            case .oura:      model.oura.status.isConnected
            case .manual:    false
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Live sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(connected) { source in
                        HStack(spacing: 6) {
                            SourceDot(color: source.color, size: 8)
                            Text(source.displayName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(source.color.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(source.color.opacity(0.22), lineWidth: 0.8))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(source.displayName), connected")
                    }
                }
            }
        }
        .padding(.top, 6)
    }
}

// MARK: - Card

/// One metric, with every reporting source stacked beneath a consensus value.
///
/// Takes a resolved summary rather than the model: everything on this card came from the
/// screen's single snapshot, so drawing it costs no store reads.
private struct MetricCard: View {
    var summary: MetricSummary

    /// Keeps the larger Now numerals while still tracking Dynamic Type (fixed 34pt does not).
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(summary.kind.title, systemImage: summary.kind.systemImage)
                    .font(.headline)
                    .foregroundStyle(summary.kind.tint)
                Spacer()
                if let headline = summary.headline {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(summary.kind.format(headline))
                            .font(.system(size: headlineSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
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
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(summary.kind.tint.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(summary.kind.tint)
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
