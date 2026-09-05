import SwiftUI
import WatchKit
import WidgetKit
import OSLog

@main
struct HeartSyncWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    private var connection: CompanionSession { delegate.connection }
    @State private var selectedPage = 0
    @State private var metricPath: [MetricKind] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedPage) {
                NavigationStack(path: $metricPath) {
                    WatchDashboardView(connection: connection) { selectedPage = 1 }
                        .navigationDestination(for: MetricKind.self) { kind in
                            if let snapshot = connection.snapshot,
                               let metric = snapshot.metrics.first(where: { $0.kind == kind }) {
                                WatchMetricDetailView(metric: metric, generatedAt: snapshot.generatedAt)
                            } else {
                                Text("No readings yet. Open HeartSync on iPhone to refresh.")
                                    .navigationTitle(kind.shortTitle)
                            }
                        }
                }
                .tag(0)
                NavigationStack {
                    WatchWorkoutView(workout: delegate.workout)
                }
                .tag(1)
            }
            .tabViewStyle(.verticalPage)
            .tint(.pink)
            .onOpenURL { url in
                guard let destination = WatchComplicationLink(url: url) else { return }
                switch destination {
                case .metric(let kind):
                    selectedPage = 0
                    metricPath = [kind]
                case .workout:
                    selectedPage = 1
                }
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--watch-demo") {
                    connection.installPreview(WatchPreviewFixtures.snapshot())
                    return
                }
                #endif
                connection.start()
            }
            .onChange(of: delegate.workout.phase) { _, phase in
                if phase == .starting || phase == .running { selectedPage = 1 }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { connection.resume() }
            }
        }
    }
}

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let workout = WatchWorkoutManager()
    let connection = CompanionSession()
    private var connectivityTasks: Set<WKWatchConnectivityRefreshBackgroundTask> = []

    override init() {
        super.init()
        connection.onSnapshotReceived = { snapshot in
            do {
                if try WatchComplicationStore().save(snapshot) {
                    WidgetCenter.shared.reloadTimelines(ofKind: WatchComplicationStore.metricWidgetKind)
                }
            } catch {
                Logger(subsystem: "com.heartsync.HeartSyncChecker.watchkitapp", category: "Complications")
                    .error("Complication cache unavailable; a later context delivery will retry.")
            }
        }
        connection.onBackgroundReady = { [weak self] in
            guard let self else { return }
            for task in self.connectivityTasks { task.setTaskCompletedWithSnapshot(false) }
            self.connectivityTasks.removeAll()
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                connectivityTasks.insert(connectivity)
                connectivity.expirationHandler = { [weak self, weak connectivity] in
                    Task { @MainActor in
                        guard let connectivity else { return }
                        self?.connectivityTasks.remove(connectivity)
                        connectivity.setTaskCompletedWithSnapshot(false)
                    }
                }
            } else if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
                snapshot.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        if !connectivityTasks.isEmpty {
            connection.start()
            connection.completeBackgroundDeliveryIfReady()
        }
    }

    func handleActiveWorkoutRecovery() {
        Task { await workout.recover() }
    }
}
