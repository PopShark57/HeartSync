import Foundation
import Observation

/// The Mac app's composition root: a mirror store, local display settings, and the service
/// that pairs with an iPhone and receives its history.
///
/// Named `AppModel`, like the iPhone's, because the shared screens (Compare, metric detail,
/// the pair analysis, saved sessions) read `@Environment(AppModel.self)`. It offers the part
/// of the iPhone model's surface those screens use (`store`, `settings`, `sessions`,
/// `bluetooth.hrvQuality`) and nothing that collects data: the Mac has no transports.
@MainActor
@Observable
final class AppModel {
    /// The mirror. Written only by `MacMirrorService`, from what the iPhone sends; never
    /// pruned or compacted here, because the phone already did both.
    let store: HealthStore
    /// Display choices for this Mac's comparison screens (hidden sources, the alert
    /// threshold). Kept on the Mac rather than synced, so hiding a device here changes
    /// nothing on the phone.
    let settings: AppSettings
    /// Saved comparison sessions made on this Mac.
    let sessions: ComparisonSessionStore
    let bluetooth = MirroredBluetoothState()
    let mirror: MacMirrorService

    enum StartupState: Equatable, Sendable {
        case loading
        case ready
        case temporarilyUnavailable(String)
    }

    private(set) var startupState: StartupState = .loading
    private var hasStarted = false
    private let runServices: Bool

    /// The source the phone files HeartSync's own blood-pressure and stress estimates under
    /// (the iPhone `AppModel.estimateSourceID`), so the shared cards can label them.
    static let estimateSourceID = "heartsync.estimate"

    #if DEBUG
    /// `--mirror-demo`: the chart gallery's month of data in an in-memory mirror.
    static let mirrorDemoEnabled = ProcessInfo.processInfo.arguments.contains("--mirror-demo")
    #else
    static let mirrorDemoEnabled = false
    #endif

    init(
        store: HealthStore? = nil,
        settings: AppSettings? = nil,
        sessions: ComparisonSessionStore? = nil,
        mirror: MacMirrorService? = nil,
        runServices: Bool = true
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let fixture = arguments.contains("--mirror-empty") || arguments.contains("--mirror-unavailable")
        self.runServices = runServices && !testing && !fixture
        let persist = !Self.mirrorDemoEnabled && !testing && !fixture
        self.store = store ?? HealthStore(persistenceEnabled: persist)
        self.settings = settings ?? AppSettings(persistenceEnabled: persist)
        self.sessions = sessions ?? ComparisonSessionStore(persistenceEnabled: persist)
        self.mirror = mirror ?? MacMirrorService(macName: MacMirrorDeviceIdentity.deviceName)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        startupState = .loading
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--mirror-unavailable") {
            startupState = .temporarilyUnavailable("Synthetic unavailable storage for UI testing.")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--mirror-empty") {
            startupState = .ready
            return
        }
        if Self.mirrorDemoEnabled {
            // A month of in-memory readings, as if mirrored, for judging the Mac's screens.
            // Nothing is saved and nothing listens on the network.
            DebugChartGallery.populate(store: store, estimateSourceID: Self.estimateSourceID, now: .now)
            startupState = .ready
            return
        }
        #endif
        await settings.loadIfNeeded()
        await sessions.loadIfNeeded()
        await store.loadIfNeeded()
        guard store.loadState == .loaded else {
            hasStarted = false
            let detail = store.unavailableCollections.joined(separator: "\n")
            startupState = .temporarilyUnavailable(
                detail.isEmpty ? (store.lastPersistenceError ?? "The mirror database could not be opened.") : detail
            )
            return
        }
        if runServices { await mirror.start(store: store) }
        startupState = .ready
    }
}

/// What the shared screens ask of Bluetooth. A live strap's HRV quality belongs to the
/// phone's connection and is not part of the mirrored history, so the Mac has none.
struct MirroredBluetoothState {
    var hrvQuality: [UUID: HRVQuality] { [:] }
}
