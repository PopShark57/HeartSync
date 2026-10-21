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
    var openSetup: () -> Void = {}
    var openHistory: () -> Void = {}
    @State private var now = Date.now
    /// Resolved off the render path. It used to be rebuilt inside `body`, and `body` re-ran
    /// on every Bluetooth reading, so one 1 Hz strap re-read the store once a second on the
    /// main actor from inside a view update.
    @State private var snapshot: DashboardSnapshot?
    @State private var lastLoadedAt: Date?
    @State private var lastRetryToken = 0
    /// Bumped by the retry button so the load key changes and the query runs again.
    @State private var retryToken = 0
    /// The on-device summary above the cards, with the facts it was written from.
    @State private var brief: NowBriefDisplay?
    @State private var lastBriefAttempt: Date?

    private struct BriefRequest: Hashable {
        var facts: NowBriefFacts?
        var period: Int
    }

    private static let briefInterval: TimeInterval = 180

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
                    ContentUnavailableView {
                        Label("No devices yet", systemImage: "sensor.tag.radiowaves.forward")
                    } description: {
                        Text("Start with Apple Health for your Watch, or add a Bluetooth sensor. Oura setup is optional.")
                    } actions: {
                        Button("Set up Apple Health or Bluetooth", action: openSetup)
                            .accessibilityIdentifier("now.setup")
                    }
                } else if let snapshot {
                    if let failure = snapshot.queryFailure, snapshot.metrics.isEmpty {
                        // A failed read is not "waiting for data": that would be a claim
                        // about the user's devices this screen cannot support.
                        List {
                            HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                                .accessibilityIdentifier("now.unavailable")
                        }
                    } else if snapshot.metrics.isEmpty {
                        ContentUnavailableView {
                            Label(emptyTitle, systemImage: "hourglass")
                        } description: {
                            Text(emptyMessage)
                        } actions: {
                            Button("Manage sources", action: openSetup)
                            Button("View history", action: openHistory)
                            if model.store.enabledSources.isEmpty {
                                Button("Resume sources") {
                                    for source in model.store.sources { _ = model.store.setEnabled(true, forSource: source.id) }
                                    model.bluetooth.reconnectKnownDevices()
                                    Task { await model.refresh() }
                                }
                            } else if model.store.enabledSources.contains(where: { $0.transport == .bluetooth }) {
                                Button("Reconnect sensors") { model.bluetooth.reconnectKnownDevices() }
                            }
                        }
                    } else {
                        let facts = NowBriefFacts.build(metrics: snapshot.metrics, stressBand: stressBand, now: now)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if let brief, brief.isValid(for: facts, now: now, available: NowBriefGenerator.isAvailable) {
                                    NowBriefView(text: brief.text, generatedAt: brief.generatedAt)
                                }
                                if let issue = model.derivedHistoryIssue {
                                    Label(issue, systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                    Button("Retry estimates") { Task { await model.recomputeDerivedMetrics() } }
                                }
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
                                            },
                                            stressDrivers: summary.kind == .stress ? stressDrivers : nil
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                        }
                        // Keyed by what the brief would say, not by every reading.
                        .task(id: BriefRequest(facts: facts, period: Int(now.timeIntervalSince1970 / Self.briefInterval))) { await refreshBrief(facts) }
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

    private var emptyTitle: String {
        model.store.enabledSources.isEmpty ? "Sources are paused" : "No recent readings"
    }

    private var emptyMessage: String {
        if model.store.enabledSources.isEmpty { return "Resume collection when you are ready. Your saved history is still available." }
        let sensors = model.store.enabledSources.filter { $0.transport == .bluetooth }
        if sensors.contains(where: { !model.bluetooth.connectionState(forSource: $0.id).isActive }) {
            return "A Bluetooth sensor is disconnected. Bring it nearby and reconnect, or open your saved history."
        }
        if (model.store.readingCountOutcome.value ?? 0) > 0 { return "Your recent cards are empty. Open Compare to browse older history, or manage your sources." }
        return "Waiting for the first reading. Check source status and import progress in Devices."
    }

    private var stressBand: StressModel.Band? {
        guard case .success(let assessment) = model.stress else { return nil }
        return assessment.band
    }

    /// Asks the on-device model for a new brief when the facts changed, no more often than
    /// `briefInterval`. Obsolete prose loses display permission immediately.
    private func refreshBrief(_ facts: NowBriefFacts?) async {
        if brief?.isValid(for: facts, now: .now, available: NowBriefGenerator.isAvailable) != true { brief = nil }
        guard let facts, NowBriefGenerator.isAvailable else { return }
        let wait = lastBriefAttempt.map { max(1, Self.briefInterval - Date.now.timeIntervalSince($0)) } ?? 1
        do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        guard !Task.isCancelled else { return }
        lastBriefAttempt = .now
        guard let text = await NowBriefGenerator.generate(facts), !Task.isCancelled else { return }
        brief = NowBriefDisplay(text: text, facts: facts, generatedAt: .now)
    }

    /// What moved the current stress level most, when the latest assessment scored.
    private var stressDrivers: String? {
        guard case .success(let assessment) = model.stress else { return nil }
        return assessment.driverSummary
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
