import Combine
import SwiftUI

/// The live side-by-side view: every metric, every device that reports it, in one column.
///
/// This is the app's primary screen. The agreement badge on each card is the secondary
/// read \u{2014} it annotates the same numbers rather than living on a separate screen.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var now = Date.now

    /// Redraw once a second so relative timestamps and "live" badges stay honest, without
    /// tying the refresh to the reading stream.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Group {
                if model.store.sources.isEmpty {
                    EmptyStateView(
                        systemImage: "sensor.tag.radiowaves.forward",
                        title: "No devices yet",
                        message: "Add a Bluetooth sensor, connect Apple Health, or link your Oura account to start collecting readings."
                    )
                } else if visibleMetrics.isEmpty {
                    EmptyStateView(
                        systemImage: "hourglass",
                        title: "Waiting for data",
                        message: "Your devices are connected but haven't reported anything yet. Wearables often take a minute to start streaming."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            summaryHeader
                            ForEach(visibleMetrics) { kind in
                                MetricCard(kind: kind, now: now)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Now")
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

    /// Metrics with at least one live-ish reading, ordered so the fast-moving vitals lead.
    private var visibleMetrics: [MetricKind] {
        let all = model.store.availableMetrics
        let withData = all.filter { !model.liveValues(kind: $0).isEmpty }
        return withData.sorted { lhs, rhs in
            if lhs.isContinuous != rhs.isContinuous { return lhs.isContinuous }
            return MetricKind.allCases.firstIndex(of: lhs)! < MetricKind.allCases.firstIndex(of: rhs)!
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
        return HStack(spacing: 8) {
            ForEach(connected) { source in
                HStack(spacing: 5) {
                    SourceDot(color: source.color, size: 8)
                    Text(source.displayName)
                        .font(.caption)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(source.color.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

/// One metric, with every reporting source stacked beneath a consensus value.
private struct MetricCard: View {
    @Environment(AppModel.self) private var model
    var kind: MetricKind
    var now: Date

    var body: some View {
        let latest = model.liveValues(kind: kind)
        let sources = latest.keys
            .compactMap { model.store.source(id: $0) }
            .sorted { $0.displayName < $1.displayName }
        let values = latest.values.map(\.value)
        let consensus = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let spread = (values.max() ?? 0) - (values.min() ?? 0)
        let severity = values.count >= 2 ? kind.agreement.severity(forDelta: spread) : .agreeing

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(kind.title, systemImage: kind.systemImage)
                    .font(.headline)
                    .foregroundStyle(kind.tint)
                Spacer()
                if let consensus {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(kind.format(consensus))
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .monospacedDigit()
                        Text(kind.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if sources.count >= 2 {
                AgreementBadge(severity: severity, spread: spread, kind: kind, sourceCount: sources.count)
            }

            VStack(spacing: 6) {
                ForEach(sources) { source in
                    if let reading = latest[source.id] {
                        SourceValueRow(
                            source: source,
                            kind: kind,
                            value: reading.value,
                            provenance: reading.provenance,
                            timestamp: reading.end,
                            deltaFromConsensus: sources.count >= 2 && consensus != nil
                                ? reading.value - consensus! : nil
                        )
                    }
                }
            }

            if sources.contains(where: { $0.id == AppModel.estimateSourceID }),
               kind == .bloodPressureSystolic || kind == .bloodPressureDiastolic {
                EstimateDisclaimer(text: Estimators.BloodPressureEstimate.disclaimer)
            }

            NavigationLink {
                MetricDetailView(kind: kind)
            } label: {
                HStack {
                    Text("History and agreement")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .metricCard()
    }
}
