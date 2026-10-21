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
    @State private var now = Date.now
    @State private var snapshot: DashboardSnapshot?
    @State private var lastLoadedAt: Date?
    @State private var lastRetryToken = 0
    @State private var retryToken = 0
    @State private var brief: GeneratedBrief?

    private struct GeneratedBrief: Equatable {
        var text: String
        var key: String
        var generatedAt: Date
    }

    private static let briefInterval: TimeInterval = 180
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
                    EmptyStateView(
                        systemImage: "iphone.and.arrow.forward",
                        title: model.mirror.pairing == nil ? "Not paired with an iPhone" : "Nothing mirrored yet",
                        message: model.mirror.pairing == nil
                            ? "Choose iPhone Sync in the sidebar and pair with HeartSync on your iPhone."
                            : "Open HeartSync on the iPhone, on the same network, to copy its history here."
                    )
                } else if let snapshot {
                    if let failure = snapshot.queryFailure, snapshot.metrics.isEmpty {
                        List {
                            HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                        }
                    } else if snapshot.metrics.isEmpty {
                        EmptyStateView(
                            systemImage: "hourglass",
                            title: "No recent readings",
                            message: "The mirror holds no reading from the last week. Older history is on the Compare screen."
                        )
                    } else {
                        let facts = NowBriefFacts.build(metrics: snapshot.metrics, stressBand: nil, now: now)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if let brief {
                                    NowBriefView(text: brief.text, generatedAt: brief.generatedAt)
                                }
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
                        .task(id: facts?.key) { await refreshBrief(facts) }
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

    private func refreshBrief(_ facts: NowBriefFacts?) async {
        guard let facts, facts.key != brief?.key, NowBriefGenerator.isAvailable else { return }
        let wait = brief.map { max(2, Self.briefInterval - Date.now.timeIntervalSince($0.generatedAt)) } ?? 1
        try? await Task.sleep(for: .seconds(wait))
        guard !Task.isCancelled, let text = await NowBriefGenerator.generate(facts), !Task.isCancelled else { return }
        brief = GeneratedBrief(text: text, key: facts.key, generatedAt: .now)
    }
}
