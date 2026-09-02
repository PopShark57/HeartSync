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

    /// Clock for the freshness cutoff, not for the timestamps.
    ///
    /// `Text(_:format: .relative)` re-renders itself, so the old 1 Hz tick was not what
    /// kept "3 minutes ago" honest. What genuinely needs a clock is the 15-minute
    /// staleness cutoff and the roll-over into a new comparison bucket: without a tick, a
    /// device that stops reporting keeps its row until some other observed change
    /// invalidates the view. Thirty seconds bounds both errors well inside the shortest
    /// comparison window (60 s) at a thirtieth of the previous cost.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        // Resolved once per update and handed down. Every card reading its own live values
        // would rescan the archive per metric per card, and `latestBySource` is relative to
        // `now`, so repeated calls would also disagree about what "current" means within a
        // single frame.
        let snapshot = DashboardSnapshot(store: model.store, now: now)

        NavigationStack {
            Group {
                if model.store.sources.isEmpty {
                    EmptyStateView(
                        systemImage: "sensor.tag.radiowaves.forward",
                        title: "No devices yet",
                        message: "Add a Bluetooth sensor, connect Apple Health, or link your Oura account to start collecting readings."
                    )
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

// MARK: - Snapshot

/// A source paired with its most recent reading, before the row is shaped.
private struct LiveReading {
    var source: DataSource
    var reading: Reading
}

/// One device's current reading of one metric.
private struct SourceReadingRow: Identifiable {
    var source: DataSource
    var value: Double
    var provenance: Provenance
    var timestamp: Date
    /// Offset from the window consensus, present only when this exact reading sits inside
    /// the aligned window the verdict came from. Nil is not "no difference"; it means the
    /// reading was never compared.
    var deltaFromWindowConsensus: Double?

    var id: String { source.id }
}

/// The agreement verdict for one metric, drawn from a single epoch-aligned window.
private struct WindowComparison {
    var severity: DiscrepancySeverity
    var spread: Double
    var sourceCount: Int
    var windowSize: TimeInterval
}

/// Everything one card draws, resolved before the card is built.
private struct MetricSummary: Identifiable {
    var kind: MetricKind
    var rows: [SourceReadingRow]
    /// Window consensus when the devices were comparable, otherwise the most recent single
    /// reading. Never a mean of values taken minutes apart.
    var headline: Double?
    /// Non-nil only when two or more measured sources shared the current (or immediately
    /// preceding) aligned window.
    var comparison: WindowComparison?
    /// Why no verdict is shown, when more than one source reported but they were not
    /// comparable. Mutually exclusive with `comparison`.
    var notComparedDetail: String?

    var id: MetricKind { kind }
}

/// One resolved pass over the store for the live screen.
///
/// Building every card from a single bounded read keeps the screen O(recent readings)
/// instead of O(archive \u{00d7} metrics \u{00d7} cards), and makes every card describe the same instant.
@MainActor
private struct DashboardSnapshot {
    let metrics: [MetricSummary]

    /// Readings older than this are not "now" and are dropped from the rows, matching
    /// `ComparisonEngine.latestBySource`'s own default.
    private static let liveWindow: TimeInterval = 15 * 60

    /// How far back this screen reads.
    ///
    /// The rows only ever show the last `liveWindow`, but the agreement verdict needs the
    /// current *and* the immediately preceding epoch-aligned bucket, and the longest
    /// comparison window is a full day. Two of those is the bound. It is still a bounded
    /// read: the previous implementation scanned the whole archive once per metric per
    /// card, every second.
    private static let lookback: TimeInterval =
        2 * (MetricKind.allCases.map(\.comparisonWindow).max() ?? 86_400)

    /// Display order of `MetricKind`, precomputed so the comparator is O(1) and total.
    private static let displayOrder: [MetricKind: Int] = Dictionary(
        uniqueKeysWithValues: MetricKind.allCases.enumerated().map { ($0.element, $0.offset) }
    )

    init(store: HealthStore, now: Date) {
        // A minute of forward tolerance so a reading whose timestamp is slightly ahead of
        // the tick is not excluded from its own current window.
        let interval = DateInterval(
            start: now.addingTimeInterval(-Self.lookback),
            end: now.addingTimeInterval(60)
        )
        let byKind = Dictionary(grouping: store.readings(in: interval), by: \.kind)

        self.metrics = byKind
            .compactMap { kind, readings in
                Self.summary(kind: kind, readings: readings, store: store, now: now)
            }
            .sorted { lhs, rhs in
                if lhs.kind.isContinuous != rhs.kind.isContinuous { return lhs.kind.isContinuous }
                return Self.order(of: lhs.kind) < Self.order(of: rhs.kind)
            }
    }

    private static func order(of kind: MetricKind) -> Int {
        displayOrder[kind] ?? MetricKind.allCases.count
    }

    /// Builds one card's worth of state, or nil when nothing recent enough exists.
    ///
    /// The verdict comes from `ComparisonEngine.windows` with the metric's own comparison
    /// window and the engine's default exclusion of estimates, which is exactly what the
    /// Compare tab does. Only the current bucket or the one immediately before it can
    /// produce a verdict on a screen called "Now".
    private static func summary(
        kind: MetricKind,
        readings: [Reading],
        store: HealthStore,
        now: Date
    ) -> MetricSummary? {
        let latest = ComparisonEngine.latestBySource(
            from: readings,
            kind: kind,
            now: now,
            staleAfter: liveWindow
        )
        guard !latest.isEmpty else { return nil }

        // Sources with something live to show, resolved once so the verdict below can be
        // checked against what the card actually displays.
        let visible = latest.compactMap { sourceID, reading -> LiveReading? in
            guard let source = store.source(id: sourceID) else { return nil }
            return LiveReading(source: source, reading: reading)
        }
        guard !visible.isEmpty else { return nil }
        let visibleIDs = Set(visible.map(\.source.id))

        let windowSize = kind.comparisonWindow
        let windows = ComparisonEngine.windows(from: readings, kind: kind)
        // Shape the window to the rows this card actually displays. A third source can
        // still have data in this bucket but already be stale; allowing its hidden value
        // into the consensus/spread would make the badge describe a different set of
        // devices than the card beneath it.
        let shared = windows.reversed().compactMap { window -> ComparisonWindow? in
            let onScreen = window.values.filter { visibleIDs.contains($0.sourceID) }
            guard onScreen.count >= 2 else { return nil }
            return ComparisonWindow(
                kind: window.kind,
                start: window.start,
                duration: window.duration,
                values: onScreen
            )
        }.first
        let currentBucket = ComparisonEngine.floorToWindow(now, size: windowSize)
        let isCurrent = (shared?.start ?? .distantPast) >= currentBucket.addingTimeInterval(-windowSize)
        let aligned = isCurrent ? shared : nil

        let rows = visible
            .map { live in
                SourceReadingRow(
                    source: live.source,
                    value: live.reading.value,
                    provenance: live.reading.provenance,
                    timestamp: live.reading.end,
                    deltaFromWindowConsensus: delta(for: live.reading, in: aligned, kind: kind)
                )
            }
            .sorted { $0.source.displayName < $1.source.displayName }

        let comparison = aligned.map { window in
            WindowComparison(
                severity: window.severity,
                spread: window.spread,
                sourceCount: window.values.count,
                windowSize: windowSize
            )
        }

        return MetricSummary(
            kind: kind,
            rows: rows,
            headline: aligned?.consensus ?? rows.max { $0.timestamp < $1.timestamp }?.value,
            comparison: comparison,
            notComparedDetail: comparison == nil
                ? notComparedDetail(
                    rows: rows,
                    sharedWindow: shared,
                    sharedWindowIsCurrent: isCurrent,
                    kind: kind,
                    now: now
                )
                : nil
        )
    }

    /// The row's offset from the window consensus, or nil when this reading was not part of
    /// the compared window.
    ///
    /// Three conditions, all required: an aligned window exists, this source contributed to
    /// it, and *this* reading falls inside it. A reading from a later or earlier bucket
    /// would be differenced against a consensus it never participated in, which is the
    /// timing artefact the windowing exists to remove. Estimates are excluded because they
    /// never enter a comparison.
    private static func delta(
        for reading: Reading,
        in window: ComparisonWindow?,
        kind: MetricKind
    ) -> Double? {
        guard let window,
              reading.provenance != .estimated,
              let consensus = window.consensus,
              window.value(for: reading.sourceID) != nil,
              ComparisonEngine.floorToWindow(reading.midpoint, size: kind.comparisonWindow) == window.start
        else { return nil }
        return reading.value - consensus
    }

    /// Plain-language reason a card shows values but no verdict.
    ///
    /// Returns nil when only one source reported, because a single device has nothing to
    /// disagree with and the absence of a badge is already the honest answer.
    private static func notComparedDetail(
        rows: [SourceReadingRow],
        sharedWindow: ComparisonWindow?,
        sharedWindowIsCurrent: Bool,
        kind: MetricKind,
        now: Date
    ) -> String? {
        guard rows.count >= 2 else { return nil }
        let length = WindowLabel.length(kind.comparisonWindow)

        let measured = rows.filter { $0.provenance != .estimated }
        guard measured.count >= 2 else {
            return "Only one of these values was measured. Estimated values are never compared with a device."
        }

        if let sharedWindow {
            guard sharedWindowIsCurrent else {
                let age = WindowLabel.elapsed(now.timeIntervalSince(sharedWindow.end))
                return "The last \(length) window these devices shared ended \(age) ago, so there is nothing current to compare."
            }
            return "Fewer than two of the devices in the current \(length) window are still reporting, so no current comparison is shown."
        }

        guard let oldest = measured.map(\.timestamp).min(),
              let newest = measured.map(\.timestamp).max()
        else { return nil }
        let apart = WindowLabel.elapsed(newest.timeIntervalSince(oldest))
        let lastReport = WindowLabel.elapsed(now.timeIntervalSince(oldest))
        return "Readings are up to \(apart) apart \u{2014} one device last reported \(lastReport) ago \u{2014} so no shared \(length) window covers them both."
    }
}

// MARK: - Card

/// One metric, with every reporting source stacked beneath a consensus value.
///
/// Takes a resolved summary rather than the model: everything on this card came from the
/// screen's single snapshot, so drawing it costs no store reads.
private struct MetricCard: View {
    var summary: MetricSummary

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
                            .font(.system(size: 34, weight: .bold, design: .rounded))
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
