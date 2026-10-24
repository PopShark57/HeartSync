import Combine
import SwiftUI

/// The Mac's Now: the iPhone's cards, built from the mirror with the same snapshot.
///
/// Every value is a reading the phone stored and sent, so nothing here is live: a card shows
/// a device's value with its age, and a verdict only when two devices shared a window in the
/// last quarter hour, exactly as on the phone. What the Mac cannot know is whether a strap is
/// still streaming, so there are no Live chips; the header says when the mirror last heard
/// from the phone instead.
struct MacNowView: View {
    @Environment(AppModel.self) private var model
    var openSync: () -> Void = {}
    @State private var now = Date.now
    @State private var snapshot: DashboardSnapshot?
    @State private var lastLoadedAt: Date?
    @State private var lastRetryToken = 0
    @State private var retryToken = 0
    @State private var brief = NowBriefController()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

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
                        Label(model.mirror.pairing == nil ? "Not paired with an iPhone" : "Nothing mirrored yet", systemImage: "iphone.and.arrow.forward")
                    } description: {
                        Text("Open HeartSync on your iPhone on the same network, then pair to copy its history here.")
                    } actions: {
                        Button("Pair with iPhone…", action: openSync)
                            .accessibilityIdentifier("mac.now.pair")
                    }
                } else if let snapshot {
                    if let failure = snapshot.queryFailure, snapshot.metrics.isEmpty {
                        List {
                            HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                        }
                    } else if snapshot.metrics.isEmpty {
                        ContentUnavailableView {
                            Label("No recent readings", systemImage: "hourglass")
                        } description: {
                            Text("The mirror holds no reading from the last week.")
                        } actions: {
                            NavigationLink("View history") { CompareView() }
                            Button("iPhone Sync", action: openSync)
                        }
                    } else {
                        let facts = NowBriefFacts.build(metrics: snapshot.metrics, stressBand: nil, now: now)
                        let unavailability = NowBriefGenerator.unavailability
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                NowBriefSection(controller: brief, facts: facts, now: now, unavailability: unavailability)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)],
                                    spacing: 16
                                ) {
                                    ForEach(snapshot.metrics) { summary in
                                        MetricCard(summary: summary, isBluetoothStreaming: false, stressDrivers: nil)
                                    }
                                }
                            }
                            .padding(20)
                        }
                        .task(id: brief.request(facts: facts, unavailability: unavailability, now: now)) {
                            await brief.refresh(facts, unavailability: unavailability)
                        }
                    }
                } else {
                    ProgressView()
                }
            }
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
            .navigationSubtitle(subtitle)
            .onReceive(tick) { now = $0 }
        }
    }

    private var subtitle: String {
        let mirror = model.mirror
        guard let pairing = mirror.pairing else { return String(localized: "Not paired") }
        if mirror.connectedPhone != nil { return String(localized: "From \(pairing.peer.name) · connected") }
        if let synced = mirror.lastSyncedAt {
            return String(localized: "From \(pairing.peer.name) · synced \(synced.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "From \(pairing.peer.name)")
    }
}
