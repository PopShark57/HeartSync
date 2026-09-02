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
