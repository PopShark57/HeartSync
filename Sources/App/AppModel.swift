import Foundation
import Observation
import OSLog
import SwiftUI

/// Root object wiring the three transports to the single store, plus the derived metrics
/// HeartSync computes itself.
@MainActor
@Observable
final class AppModel {

    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "App")

    let store: HealthStore
    let settings: AppSettings
    let sessions: ComparisonSessionStore
    let bluetooth: BluetoothManager
    let healthKit: HealthKitManager
    let oura: OuraManager
    private let watchCompanion = WatchCompanionPublisher()
    private let transports: TransportActions

    /// The concrete services are the defaults; a test passes its own store and settings over
    /// temporary files and `TransportActions.inert` (or recording closures), so startup
    /// order, retention, derived metrics, and refresh can run without Bluetooth, HealthKit,
    /// or the network. Views still see the concrete managers.
    init(
        store: HealthStore? = nil,
        settings: AppSettings? = nil,
        sessions: ComparisonSessionStore? = nil,
        bluetooth: BluetoothManager? = nil,
        healthKit: HealthKitManager? = nil,
        oura: OuraManager? = nil,
        transports: TransportActions? = nil
    ) {
        let persist = !Self.debugDataIsolationEnabled
        let bluetooth = bluetooth ?? BluetoothManager()
        let healthKit = healthKit ?? HealthKitManager()
        let oura = oura ?? OuraManager()
        self.store = store ?? HealthStore(persistenceEnabled: persist)
        self.settings = settings ?? AppSettings(persistenceEnabled: persist)
        self.sessions = sessions ?? ComparisonSessionStore(persistenceEnabled: persist)
        self.bluetooth = bluetooth
        self.healthKit = healthKit
        self.oura = oura
        self.transports = transports ?? .live(bluetooth: bluetooth, healthKit: healthKit, oura: oura)
    }

    /// The calls `AppModel` makes on its three transports, and nothing else.
    ///
    /// A narrow seam rather than three protocols: each closure is one call the model makes,
    /// so a test can record it or delay it without a fake Bluetooth stack, and production
    /// forwards each one to the concrete manager unchanged.
    struct TransportActions {
        var configureBluetooth: @MainActor (
            HealthStore,
            _ onReading: @escaping @MainActor (Reading) -> Void,
            _ onReadings: @escaping @MainActor ([Reading]) -> Void,
            _ onLinkEnded: @escaping @MainActor () -> Void
        ) -> Void
        var reconnectBluetooth: @MainActor () -> Void
        /// Reconnects known devices once the history has loaded. The central is created at
        /// launch, before the source list exists, so this is the first moment it can.
        var resumeBluetoothAfterLoad: @MainActor () -> Void = {}
        var stopBluetoothScan: @MainActor () -> Void
        var configureHealthKit: @MainActor (
            HealthStore,
            _ onReadings: @escaping @MainActor ([Reading], [DataSource], Set<UUID>) -> Bool
        ) -> Void
        /// Installs HealthKit's background-delivery observer queries. Called at launch.
        var registerHealthKitBackgroundDelivery: @MainActor () -> Void = {}
        var restoreHealthKit: @MainActor () async -> Void
        var isHealthKitAuthorized: @MainActor () -> Bool
        var syncHealthKit: @MainActor () async -> Void
        var mirrorToHealthKit: @MainActor ([Reading]) -> Void
        var flushHealthKitWrites: @MainActor () async -> Void
        var configureOura: @MainActor (
            HealthStore,
            _ onReadings: @escaping @MainActor ([Reading], [DataSource], Set<UUID>) -> Bool
        ) async -> Void
        var hasOuraAuthorization: @MainActor () -> Bool
        /// `minimumInterval` is how recent the last committed sync may be before an
        /// unattended call skips; zero always attempts (subject to a rate-limit backoff).
        var syncOura: @MainActor (_ userInitiated: Bool, _ minimumInterval: TimeInterval) async -> Void
        /// Stops HealthKit imports before a reset and waits for the one in flight.
        var beginHealthKitReset: @MainActor () async -> Void = {}
        /// Resumes HealthKit imports; `true` clears the anchors first so history is re-read.
        var finishHealthKitReset: @MainActor (_ rereadHistory: Bool) async -> Void = { _ in }
        /// Cancels and awaits a running Oura sync, then removes its cache and readings.
        /// Reports whether the cache and credential changes were saved.
        var clearOura: @MainActor (_ keepingAuthorization: Bool) async -> Bool = { _ in true }
        /// Whether the iPhone's Bluetooth radio is on, so a wrist sync can say why nothing
        /// reconnected.
        var isBluetoothPoweredOn: @MainActor () -> Bool = { false }
        /// Starts Import stored on every connected, identified, idle ring, as the Devices
        /// tab's button does for one, and returns how many started.
        var importRingHistories: @MainActor () -> Int = { 0 }
        /// Starts one on-demand heart-rate measurement on a ring, for a stress check, and
        /// reports whether it started.
        var measureRingHeartRate: @MainActor (_ sourceID: String) -> Bool = { _ in false }
        /// Installs the handler for a ring's completed on-demand measurement.
        var observeRingMeasurements: @MainActor (
            _ handler: @escaping @MainActor (_ sourceID: String, R11MRingSession.RingValue) -> Void
        ) -> Void = { _ in }
        /// How the Health sync that ended at or after `since` went, for a wrist sync.
        var healthKitSyncOutcome: @MainActor (_ since: Date) -> WatchSyncReport.Outcome = { _ in .synced }
        /// How the Oura cycle that ended at or after `since` went, for a wrist sync.
        var ouraSyncOutcome: @MainActor (_ since: Date) -> WatchSyncReport.Outcome = { _ in .synced }

        static func live(
            bluetooth: BluetoothManager,
            healthKit: HealthKitManager,
            oura: OuraManager
        ) -> Self {
            Self(
                configureBluetooth: { store, onReading, onReadings, onLinkEnded in
                    bluetooth.configure(
                        store: store,
                        onReading: onReading,
                        onReadings: onReadings,
                        onLinkEnded: onLinkEnded
                    )
                },
                reconnectBluetooth: { bluetooth.reconnectKnownDevices() },
                resumeBluetoothAfterLoad: { bluetooth.reconnectKnownDevices() },
                stopBluetoothScan: { bluetooth.stopScan() },
                configureHealthKit: { store, onReadings in
                    healthKit.configure(store: store, onReadings: onReadings)
                },
                registerHealthKitBackgroundDelivery: { healthKit.registerBackgroundObservers() },
                restoreHealthKit: { await healthKit.restoreSessionIfNeeded() },
                isHealthKitAuthorized: { healthKit.availability == .authorized },
                syncHealthKit: { await healthKit.syncAll() },
                mirrorToHealthKit: { healthKit.enqueueWrites($0) },
                flushHealthKitWrites: { await healthKit.flushWrites() },
                configureOura: { store, onReadings in
                    await oura.configure(store: store, onReadings: onReadings)
                },
                hasOuraAuthorization: { oura.mayHaveAuthorization },
                syncOura: { userInitiated, minimumInterval in
                    if userInitiated {
                        await oura.sync()
                    } else {
                        await oura.syncIfDue(minimumInterval: minimumInterval)
                    }
                },
                beginHealthKitReset: { await healthKit.beginDataReset() },
                finishHealthKitReset: { await healthKit.finishDataReset(rereadingHistory: $0) },
                clearOura: { await oura.clearCachedData(keepingAuthorization: $0) },
                isBluetoothPoweredOn: { bluetooth.isPoweredOn },
                importRingHistories: { bluetooth.importStoredReadingsFromReadyRings() },
                measureRingHeartRate: { sourceID in
                    bluetooth.measure(.heartRate, sourceID: sourceID)
                    return bluetooth.ringSession(forSource: sourceID)?.activeMeasurement == .heartRate
                },
                observeRingMeasurements: { bluetooth.onRingMeasurement = $0 },
                healthKitSyncOutcome: { since in
                    WatchSyncOutcomes.healthKit(healthKit.syncSummary, since: since)
                },
                ouraSyncOutcome: { since in
                    WatchSyncOutcomes.oura(
                        committedAt: oura.lastSyncedAt,
                        issueCount: oura.endpointIssues.count,
                        rateLimitedUntil: oura.rateLimitedUntil,
                        since: since,
                        now: .now
                    )
                }
            )
        }

        /// Does nothing and reports nothing authorized.
        static let inert = Self(
            configureBluetooth: { _, _, _, _ in },
            reconnectBluetooth: {},
            stopBluetoothScan: {},
            configureHealthKit: { _, _ in },
            restoreHealthKit: {},
            isHealthKitAuthorized: { false },
            syncHealthKit: {},
            mirrorToHealthKit: { _ in },
            flushHealthKitWrites: {},
            configureOura: { _, _ in },
            hasOuraAuthorization: { false },
            syncOura: { _, _ in }
        )
    }

    enum StartupState: Equatable, Sendable {
        case loading
        case ready
        case temporarilyUnavailable(String)
    }

    private(set) var startupState: StartupState = .loading
    private(set) var startupNotice: String?

    /// The latest stress assessment, or why there is none. Nil until the first estimate pass.
    private(set) var stress: Result<StressModel.Assessment, StressModel.Unavailable>?

    /// A stress check the user started from a ring's Devices row.
    enum StressCheck: Equatable, Sendable {
        /// The ring is measuring heart rate for it.
        case measuring
        case scored(StressModel.Assessment)
        case unavailable(StressModel.Unavailable)
    }

    /// Stress checks by ring source ID.
    private(set) var stressChecks: [String: StressCheck] = [:]
    /// The summary of the user's own history the stress index compares with, reused for
    /// `StressModel.Baseline.lifetime`. Tied to `dataEpoch`, so a reset discards it.
    private var stressBaseline: StressModel.Baseline?
    private var stressBaselineEpoch = -1

    /// Live Bluetooth values waiting to commit as one transaction (improvement 52).
    private var bluetoothBuffer = BluetoothIngestBuffer()
    private var bluetoothFlushTask: Task<Void, Never>?
    private var hasLaunched = false
    private var derivedTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var ouraTimerTask: Task<Void, Never>?
    /// When the last wrist sync-all started, which bounds how often one can run.
    private var lastWatchSyncAll: Date?
    private var hasStarted = false
    /// True while `resetLocalData` runs; a second reset is refused.
    private(set) var isResettingData = false
    /// Advanced by every reset. Work that read history before a reset (the derived
    /// estimates, computed off the main actor) checks it before writing, so it cannot
    /// write back values computed from history that no longer exists.
    private var dataEpoch = 0
    /// Whether the user has chosen a retention period in this session, which is what lets a
    /// settings file that was reset or set aside delete history again.
    private var retentionChoiceIsUsers = false

    // MARK: - Lifecycle

    /// The part of startup that must happen at process launch, from
    /// `application(_:didFinishLaunchingWithOptions:)`, before any view exists
    /// (improvement 53).
    ///
    /// iOS relaunches the app in the background to hand back a restored Bluetooth link or to
    /// deliver new Health samples, and in either case expects the app to re-create its
    /// central manager and register its observer queries during launch. Both used to wait for
    /// the root view's `.task`, which is not a launch hook and may not run in the background.
    /// Nothing here reads history: Bluetooth values that arrive before the store loads wait
    /// in its bounded pre-load buffer, and the HealthKit handlers wait for `start()` to
    /// finish before draining.
    func launch() {
        guard !hasLaunched else { return }
        hasLaunched = true
        #if DEBUG
        guard !Self.debugDataIsolationEnabled else { return }
        #endif
        transports.configureBluetooth(
            store,
            { [weak self] reading in self?.bufferBluetooth(reading) },
            // A ring history import commits as one idempotent batch, after anything live
            // that was waiting, so a value is never committed behind an older one.
            { [weak self] readings in
                self?.flushBluetoothBuffer()
                self?.ingest(readings)
            },
            { [weak self] in self?.flushBluetoothBuffer() }
        )
        transports.observeRingMeasurements { [weak self] sourceID, value in
            self?.ringMeasured(sourceID: sourceID, value: value)
        }
        transports.registerHealthKitBackgroundDelivery()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        startupState = .loading

        #if DEBUG
        if Self.pairwiseDemoEnabled {
            let now = Date.now
            DebugAnalysisFixtures.populate(store: store, now: now)
            // Held in memory only: persistence is disabled in the demo, so this reports
            // "not saved" by design and nothing reaches the user's sessions archive.
            await sessions.save(DebugAnalysisFixtures.demoSession(now: now))
            startupState = .ready
            return
        }
        if Self.chartGalleryEnabled {
            // A month of in-memory readings for judging charts; nothing is saved and no
            // transport starts, as with the pairwise demo.
            DebugChartGallery.populate(store: store, estimateSourceID: Self.estimateSourceID, now: .now)
            startupState = .ready
            return
        }
        if let scenario = Self.uiTestScenario {
            switch scenario {
            case .loading:
                return
            case .startupUnavailable:
                startupState = .temporarilyUnavailable("readings: simulated protected-file access failure")
            case .sourcesUnavailable:
                startupState = .temporarilyUnavailable("sources: simulated protected-file access failure")
            case .corruptRecovery:
                startupNotice = "HeartSync recovered by preserving unreadable health data aside: readings: contents could not be decoded."
                startupState = .ready
            case .settingsUnavailable:
                settings.injectLoadFailureForUITesting("settings: simulated protected-file access failure")
                updateStartupPresentation()
            case .empty:
                startupState = .ready
            case .devices, .retention:
                DebugUITestFixtures.populateDevices(store: store, includeHistory: scenario == .retention)
                startupState = .ready
            case .removal:
                DebugUITestFixtures.populateRemoval(store: store)
                startupState = .ready
            case .ouraPartial:
                oura.injectPartialFailureForUITesting()
                startupState = .ready
            case .ouraCharts:
                oura.injectChartFixtureForUITesting()
                startupState = .ready
            }
            return
        }
        #endif

        watchCompanion.start(
            store: store,
            onRefresh: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.watchCompanion.publishNow()
                    // Watch messages may arrive while protected history is still loading.
                    guard self.startupState == .ready else { return }
                    await self.refreshForWatch()
                    self.watchCompanion.publishNow()
                }
            },
            onSyncAll: { [weak self] in
                await self?.syncAllFromWatch() ?? .unavailable()
            }
        )
        await settings.loadIfNeeded()
        await sessions.loadIfNeeded()
        await store.loadIfNeeded()
        guard store.loadState == .loaded else {
            // Do not attach live transports to an inconclusively loaded archive. Their readings
            // would have nowhere durable to go and could fill memory while the device is locked
            // or storage is temporarily unavailable. `refresh()` retries `start()` later.
            logger.error("Archive unavailable; delaying transport startup until it can be read")
            hasStarted = false
            let detail = store.unavailableCollections.joined(separator: "\n")
            startupState = .temporarilyUnavailable(
                detail.isEmpty ? (store.lastPersistenceError ?? "The health history database could not be opened.") : detail
            )
            return
        }
        // Builds predating the HealthKit self-source filter may already have persisted a
        // phantom `hk.<our bundle id>` device containing mirrored Bluetooth samples. The
        // query and conversion guards stop new copies; this migration removes the old
        // source and its readings so it cannot keep reporting perfect self-agreement.
        HealthKitManager.removePersistedSelfSource(from: store)
        // The store loads without pruning aged history, because the retention it starts with
        // is only a default. Apply the saved period first; this prunes once it is confirmed.
        applyRetentionSettings()
        store.prune()

        // Normally done at launch already; a test or a preview that calls `start()` directly
        // gets it here. The central now sees the loaded source list, so reconnect the rest.
        launch()
        transports.resumeBluetoothAfterLoad()
        transports.configureHealthKit(store) { [weak self] readings, sources, deletedIDs in
            self?.ingest(
                readings,
                updatingSources: sources,
                removingReadingIDs: deletedIDs
            ) ?? false
        }
        // Cold start always begins as `.notDetermined`; restore a prior Connect without
        // re-prompting so observers install and the sync below can run.
        await transports.restoreHealthKit()
        await transports.configureOura(store) { [weak self] readings, sources, withdrawnIDs in
            self?.ingest(
                readings,
                updatingSources: sources,
                removingReadingIDs: withdrawnIDs,
                replacingExisting: true
            ) ?? false
        }

        // No second sync here: restoring a granted session already synced Health and installed
        // its observers, and running `syncAll` again stopped and restarted all nine of them.

        startDerivedMetrics()
        startMaintenance()
        startOuraSchedule()
        updateStartupPresentation()
        watchCompanion.publishNow()
    }

    func retryStartup() async {
        if store.loadState != .loaded {
            hasStarted = false
            await start()
            return
        }
        await settings.loadIfNeeded()
        updateStartupPresentation()
    }

    private func updateStartupPresentation() {
        startupState = .ready
        var notices: [String] = []
        if !store.recoveredCorruptCollections.isEmpty {
            notices.append("HeartSync recovered by preserving unreadable health data aside: \(store.recoveredCorruptCollections.joined(separator: "; ")).")
        }
        if settings.recoveredCorruptArchive {
            notices.append("Settings were reset after preserving a corrupt settings archive.")
        } else if settings.loadState == .failed {
            notices.append("Settings are temporarily unavailable. Controls are read-only and changes will not be saved until Retry succeeds.")
        }
        if retentionIsPaused {
            notices.append("Deleting old readings is paused because your saved retention period could not be confirmed. Choose one in Settings to resume.")
        }
        startupNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
    }

    /// Called when the app returns to the foreground, and by pull-to-refresh.
    ///
    /// - Parameter userInitiated: true for a pull-to-refresh, which always asks Oura. The
    ///   foreground call is automatic: it goes through the same minimum interval as the timer
    ///   and honours a rate-limit backoff, because returning to the app several times in a
    ///   minute would otherwise repeat a 19-request cycle each time.
    func refresh(userInitiated: Bool = false) async {
        #if DEBUG
        guard !Self.pairwiseDemoEnabled, !Self.chartGalleryEnabled else { return }
        #endif
        guard hasStarted else {
            await start()
            return
        }
        // `start()` sets `hasStarted` first and then suspends while the store loads. A
        // refresh in that window would publish an "unavailable" watch snapshot and recompute
        // estimates against a store that has not loaded.
        guard startupState == .ready else { return }
        transports.reconnectBluetooth()
        if transports.isHealthKitAuthorized() {
            await transports.syncHealthKit()
        }
        applyRetentionSettings()
        if settings.snapshot.autoSyncOura || userInitiated, transports.hasOuraAuthorization() {
            await transports.syncOura(userInitiated, Self.minimumForegroundOuraInterval(settings.snapshot))
        }
        await recomputeDerivedMetrics()
        watchCompanion.publishNow()
    }

    /// A wrist "Refresh iPhone data" request: pull anything new from Apple Health and
    /// republish. It does not reconnect Bluetooth or ask Oura, because a watch can send this
    /// every fifteen seconds, possibly with the phone in the background, and none of that is
    /// needed to rebuild a wrist snapshot.
    func refreshForWatch() async {
        guard hasStarted, startupState == .ready else { return }
        if transports.isHealthKitAuthorized() {
            await transports.syncHealthKit()
        }
    }

    /// A wrist "Sync all sources" request: what the Devices tab's buttons do one by one.
    ///
    /// Reconnects known Bluetooth devices (a healthy link is left alone), starts Import
    /// stored on every identified, idle ring, re-reads Apple Health, and runs a full Oura
    /// sync as a pull-to-refresh does, then recomputes estimates and republishes. It is the
    /// user's own request, unlike `refreshForWatch`, so it asks every transport; runs are at
    /// least `WatchSyncReport.minimumInterval` apart so repeated taps cannot repeat Oura's
    /// request cycle.
    ///
    /// Returns when everything has finished or when `deadline` passes, whichever is first;
    /// work still running then carries on and reaches the watch in a later snapshot.
    func syncAllFromWatch(deadline: TimeInterval = WatchSyncReport.replyDeadline) async -> WatchSyncReport {
        #if DEBUG
        guard !Self.debugDataIsolationEnabled else { return .unavailable() }
        #endif
        // A request can wake the app and arrive while history is still loading.
        for _ in 0..<50 where hasStarted && startupState == .loading {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard hasStarted, startupState == .ready, store.loadState == .loaded else { return .unavailable() }
        let started = Date.now
        if let lastWatchSyncAll, started.timeIntervalSince(lastWatchSyncAll) < WatchSyncReport.minimumInterval {
            return .tooSoon(at: started)
        }
        lastWatchSyncAll = started

        let progress = WatchSyncProgress(WatchSyncReport(
            status: .stillRunning,
            finishedAt: started,
            health: .running,
            oura: .running
        ))
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await BackgroundWork.perform(named: "HeartSync watch sync") {
                await self.runSyncAll(since: started, progress: progress)
            }
        }
        // Whichever ends first answers; the sync itself carries on past the deadline.
        var timer: Task<Void, Never>?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let answer = ResumeOnce(continuation)
            Task { @MainActor in
                await work.value
                answer.resume()
            }
            timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(deadline))
                answer.resume()
            }
        }
        timer?.cancel()
        var report = progress.report
        report.finishedAt = .now
        if report.health != .running, report.oura != .running, progress.isFinished {
            report.status = .completed
        }
        return report
    }

    private func runSyncAll(since started: Date, progress: WatchSyncProgress) async {
        let enabledBluetooth = store.sources.count { $0.transport == .bluetooth && $0.isEnabled }
        progress.report.bluetoothDevices = min(enabledBluetooth, 64)
        progress.report.bluetoothPoweredOn = transports.isBluetoothPoweredOn()
        transports.reconnectBluetooth()
        progress.report.ringImports = min(transports.importRingHistories(), progress.report.bluetoothDevices)

        let healthAuthorized = transports.isHealthKitAuthorized()
        let ouraAuthorized = transports.hasOuraAuthorization()
        progress.report.health = healthAuthorized ? .running : .notConnected
        progress.report.oura = ouraAuthorized ? .running : .notConnected
        if healthAuthorized {
            await transports.syncHealthKit()
            progress.report.health = transports.healthKitSyncOutcome(started)
        }
        applyRetentionSettings()
        if ouraAuthorized {
            await transports.syncOura(true, 0)
            progress.report.oura = transports.ouraSyncOutcome(started)
        }
        progress.isFinished = true
        await recomputeDerivedMetrics()
        watchCompanion.publishNow()
    }

    /// The least time between unattended Oura syncs: the scheduled interval, never under the
    /// five-minute floor the timer already uses.
    nonisolated static func minimumForegroundOuraInterval(_ snapshot: SettingsSnapshot) -> TimeInterval {
        max(300, snapshot.ouraSyncInterval)
    }

    /// Pushes the user's retention preference into the store, and pins the compaction
    /// horizon to the shortest value the store allows.
    ///
    /// Retention and compaction are separate knobs: retention decides what is *deleted*,
    /// compaction decides what is *downsampled* while still inside retention. Compacting as
    /// early as the store permits preserves the windowed medians and pairwise verdicts that
    /// comparison and export consume. New aggregates retain count and standard deviation,
    /// while old aggregates report unavailable evidence as unknown; individual samples, the
    /// full distribution, and later correction remain permanently unavailable. This
    /// deliberately asks for the floor rather than scaling with retention. `HealthStore`
    /// clamps anything below `HealthStore.minimumCompactionAge`, which exists so a 14-day
    /// Oura resync still lands on raw rows.
    ///
    /// Called at startup and on every foreground so a settings change can never leave the
    /// store on a stale horizon; `SettingsView` also writes `store.retention` directly from
    /// its picker's `onChange`, and both paths are idempotent.
    func applyRetentionSettings() {
        store.compactionAge = HealthStore.minimumCompactionAge
        guard settingsRetentionIsTrusted else {
            // Settings that failed to load, were reset after corruption, or were set aside as
            // a newer schema report the default, not a choice. Deleting on it would remove
            // history for a period the user never picked.
            store.retention = TimeInterval(settings.snapshot.retentionDays) * 86_400
            store.suspendRetention()
            return
        }
        store.confirmRetention(days: settings.snapshot.retentionDays, userInitiated: retentionChoiceIsUsers)
    }

    /// True when `settings.snapshot.retentionDays` is something the user set.
    private var settingsRetentionIsTrusted: Bool {
        guard settings.loadState == .loaded else { return false }
        return !settings.recoveredCorruptArchive || retentionChoiceIsUsers
    }

    /// Deleting aged readings is on hold: the retention on record could not be confirmed.
    var retentionIsPaused: Bool {
        store.loadState == .loaded && !store.retentionIsConfirmed
    }

    /// The user's own choice of retention, from Settings. This is the only path that can
    /// lift a hold, because it is the only one that is certain to be a choice.
    @discardableResult
    func chooseRetention(days: Int) -> Bool {
        retentionChoiceIsUsers = true
        settings.snapshot.retentionDays = days
        store.compactionAge = HealthStore.minimumCompactionAge
        let confirmed = store.confirmRetention(days: days, userInitiated: true)
        updateStartupPresentation()
        return confirmed
    }

    func enterBackground() async {
        #if DEBUG
        guard !Self.pairwiseDemoEnabled, !Self.chartGalleryEnabled else { return }
        #endif
        transports.stopBluetoothScan()
        // Nothing waits in memory while the process may be suspended.
        flushBluetoothBuffer()
        // Held open with a background-task assertion: prune, compaction, and the checkpoint
        // can outlast the moment the scene changes phase, and a suspended process would leave
        // them half done.
        await BackgroundWork.perform(named: "HeartSync maintenance") {
            await transports.flushHealthKitWrites()
            await store.saveNow()
            await settings.saveNow()
        }
        watchCompanion.publishNow()
    }

    enum DataResetMode: Sendable {
        case clearForResync
        case forgetImportedHistory
    }

    /// Performs one coordinated reset and reports whether the database, settings, and Oura
    /// cache reached durable storage. Apple Health itself is never deleted.
    ///
    /// Exclusive with every import (improvement 47). HealthKit's observers are stopped and
    /// its drain in flight is awaited, and a running Oura sync is cancelled and awaited,
    /// before anything is deleted; both managers then drop any page fetched before the
    /// reset, so nothing from before it can be committed after it. Only then does HealthKit
    /// resume: from cleared anchors for a resync, or from the committed ones for "forget",
    /// so old Health history does not return and only later samples arrive.
    func resetLocalData(_ mode: DataResetMode) async -> Bool {
        guard !isResettingData else { return false }
        isResettingData = true
        defer { isResettingData = false }
        dataEpoch &+= 1

        await transports.beginHealthKitReset()
        // Live values waiting in the buffer are committed now, so they go with the rest.
        flushBluetoothBuffer()
        let ouraSaved = await transports.clearOura(mode == .clearForResync)
        // No suspension between the Oura clear returning and this delete, so no import can
        // slip in between them.
        let storeCleared = store.deleteAllReadings()
        await transports.finishHealthKitReset(mode == .clearForResync)

        await recomputeDerivedMetrics()
        let storeSaved = await store.saveNow()
        let settingsSaved = await settings.saveNow()
        return storeCleared && ouraSaved && storeSaved && settingsSaved
    }

    // MARK: - Ingest

    /// Holds a live Bluetooth value for at most `BluetoothIngestBuffer.flushInterval`, so a
    /// streaming strap commits a batch every couple of seconds instead of a transaction per
    /// value.
    private func bufferBluetooth(_ reading: Reading) {
        let now = Date.now
        if bluetoothBuffer.append(reading, at: now) {
            flushBluetoothBuffer()
            return
        }
        guard bluetoothFlushTask == nil else { return }
        bluetoothFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(BluetoothIngestBuffer.flushInterval))
            guard !Task.isCancelled else { return }
            self?.flushBluetoothBuffer()
        }
    }

    /// Commits every waiting Bluetooth value now, as one transaction.
    func flushBluetoothBuffer() {
        bluetoothFlushTask?.cancel()
        bluetoothFlushTask = nil
        let batch = bluetoothBuffer.drain()
        guard !batch.isEmpty else { return }
        ingest(batch)
    }

    /// The single routing seam for all three transports.
    ///
    /// Write-back mirrors the readings the store *accepted*, never the input batch: a batch
    /// of ten containing one new reading and nine already-known duplicates must put exactly
    /// one sample into Apple Health. The batch result returns the committed subset precisely
    /// so this filter can run over it while source updates and upstream deletions remain in
    /// the same transaction.
    @discardableResult
    private func ingest(
        _ readings: [Reading],
        updatingSources: [DataSource] = [],
        removingReadingIDs: Set<UUID> = [],
        replacingExisting: Bool = false
    ) -> Bool {
        let result = replacingExisting
            ? store.upsertBatch(
                readings: readings,
                updatingSources: updatingSources,
                removingReadingIDs: removingReadingIDs
            )
            : store.appendBatch(
                readings: readings,
                updatingSources: updatingSources,
                removingReadingIDs: removingReadingIDs
            )
        guard result.committed else { return false }
        let accepted = result.acceptedReadings
        guard !accepted.isEmpty else { return true }

        // Optional write-back into Apple Health, measured Bluetooth values only.
        if settings.snapshot.mirrorBluetoothToHealthKit, transports.isHealthKitAuthorized() {
            let mirrorable = accepted.filter { reading in
                reading.provenance == .measured
                    && store.source(id: reading.sourceID)?.transport == .bluetooth
            }
            // Queued, not saved one by one: the manager batches them into periodic saves.
            if !mirrorable.isEmpty { transports.mirrorToHealthKit(mirrorable) }
        }
        return true
    }

    // MARK: - Derived metrics

    /// Recomputes estimates on a slow timer. They depend on windows of data rather than
    /// single samples, so recomputing on every incoming reading would be wasteful and
    /// would produce a jittery display.
    private func startDerivedMetrics() {
        derivedTask?.cancel()
        derivedTask = Task { [weak self] in
            while !Task.isCancelled {
                // The model is named only for the duration of the call: holding it across the
                // sleep would keep a released model alive for up to five more minutes.
                guard await self?.runDerivedTick() != nil else { return }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func runDerivedTick() async {
        await recomputeDerivedMetrics()
    }

    /// Prune, compact, and checkpoint on a timer. HealthKit pages and Bluetooth batches no
    /// longer trigger this themselves: their transactions are already durable.
    private func startMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.maintenanceInterval))
                guard !Task.isCancelled else { return }
                guard await self?.runMaintenanceTick() != nil else { return }
            }
        }
    }

    private func runMaintenanceTick() async {
        await store.saveNow()
    }

    static let maintenanceInterval: TimeInterval = 900

    /// Computes HeartSync's estimates off the main actor (`DerivedEstimates`), then
    /// reconciles and writes them here.
    func recomputeDerivedMetrics() async {
        // Estimates are only reconciled against a loaded store: before that, "no estimate
        // is current" would be judged against nothing.
        guard store.loadState == .loaded || !store.persistenceEnabled else { return }
        let history = store.history
        let inputs = DerivedEstimates.Inputs(
            vo2MaxEnabled: settings.snapshot.vo2MaxEstimateEnabled,
            estimatedMaxHeartRate: settings.profile.estimatedMaxHeartRate,
            bloodPressureCalibration: settings.canEstimateBloodPressure ? settings.profile.bpCalibration : nil,
            estimateSourceID: Self.estimateSourceID,
            stressBaseline: stressBaselineEpoch == dataEpoch ? stressBaseline : nil
        )
        let now = Date.now
        let epoch = dataEpoch
        let result = await HealthHistory.offMain(priority: .utility) {
            DerivedEstimates.compute(history: history, inputs: inputs, now: now)
        }
        // Computed from a read taken before a reset: writing it would restore estimates of
        // history that no longer exists.
        guard epoch == dataEpoch else { return }
        stressBaseline = result.stressBaseline
        stressBaselineEpoch = epoch
        stress = result.stressAssessment
        applyDerivedEstimates(result, now: now)
    }

    // MARK: - Stress check

    /// Measures heart rate on a ring and then scores stress with it: the ring's firmware has
    /// no stress sensor of its own, so a fresh heart rate is what it can add. The score also
    /// uses whatever HRV, breathing, temperature, and SpO\u{2082} other sources reported.
    func checkStress(ringSourceID sourceID: String) {
        guard transports.measureRingHeartRate(sourceID) else { return }
        stressChecks[sourceID] = .measuring
    }

    /// A ring finished an on-demand measurement. Completes a stress check waiting on it.
    private func ringMeasured(sourceID: String, value: R11MRingSession.RingValue) {
        guard stressChecks[sourceID] == .measuring, value.measurement == .heartRate else { return }
        // The value is still in the two-second Bluetooth batch; the estimate must read it.
        flushBluetoothBuffer()
        Task { [weak self] in
            guard let self else { return }
            await self.recomputeDerivedMetrics()
            guard self.stressChecks[sourceID] == .measuring else { return }
            switch self.stress {
            case .success(let assessment):
                self.stressChecks[sourceID] = .scored(assessment)
            case .failure(let reason):
                self.stressChecks[sourceID] = .unavailable(reason)
            case nil:
                self.stressChecks[sourceID] = .unavailable(.noCurrentSignal)
            }
        }
    }

    /// Forgets a finished check, for example when the ring starts another measurement.
    func clearStressCheck(ringSourceID sourceID: String) {
        stressChecks[sourceID] = nil
    }

    private func applyDerivedEstimates(_ result: DerivedEstimates.Result, now: Date) {
        let startOfToday = Calendar.current.startOfDay(for: now)
        store.reconcileEstimates(
            kinds: [.vo2Max],
            keeping: Set(result.vo2Max.map(\.id)),
            currentSince: settings.snapshot.vo2MaxEstimateEnabled ? startOfToday : nil
        )
        // Scoped to the synthetic estimate source. A ring reports its blood pressure as an
        // estimate under its own source, and that must never be swept up here.
        store.reconcileEstimates(
            kinds: [.bloodPressureSystolic, .bloodPressureDiastolic],
            keeping: Set(result.bloodPressure.map(\.id)),
            currentSince: settings.canEstimateBloodPressure ? now.addingTimeInterval(-300) : nil,
            sourceID: Self.estimateSourceID
        )
        // The stress index for this five-minute slot: withdrawn when it can no longer be
        // computed (exercise, or the signals went stale), so it never outlives its evidence.
        store.reconcileEstimates(
            kinds: [.stress],
            keeping: Set(result.stress.map(\.id)),
            currentSince: now.addingTimeInterval(-300),
            sourceID: Self.estimateSourceID
        )
        let produced = result.all
        guard !produced.isEmpty else { return }
        // Estimates are revisable documents, not append-only measurements. Stable IDs make
        // an identical recomputation a no-op and let new inputs revise the same day/slot.
        // The estimate source is written in the same transaction, so a removed source cannot
        // leave the readings filed under "Unknown device".
        _ = store.upsertBatch(
            readings: produced,
            updatingSources: result.bloodPressure.isEmpty && result.stress.isEmpty ? [] : [Self.estimateSourceDescriptor]
        )
    }

    /// A synthetic source that owns values HeartSync modelled rather than read from a
    /// device, so they are never mistaken for a measurement in the source list.
    static let estimateSourceID = "heartsync.estimate"

    #if DEBUG
    /// Launch with `--pairwise-demo` to exercise every analysis state without touching
    /// the user's archive or starting HealthKit, Bluetooth, or Oura transports.
    enum UITestScenario: String {
        case loading
        case startupUnavailable
        case sourcesUnavailable
        case corruptRecovery
        case settingsUnavailable
        case empty
        case devices
        case retention
        case removal
        case ouraPartial
        case ouraCharts

        static var requested: Self? {
            let prefix = "--ui-test-"
            guard let argument = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix(prefix)
            }) else { return nil }
            return Self(rawValue: String(argument.dropFirst(prefix.count)))
        }
    }

    static let pairwiseDemoEnabled = ProcessInfo.processInfo.arguments.contains("--pairwise-demo")
    /// Launch with `--chart-gallery` for thirty days of in-memory chart fixtures
    /// (`DebugChartGallery`): four sources, gaps, estimates, and compacted windows.
    static let chartGalleryEnabled = ProcessInfo.processInfo.arguments.contains("--chart-gallery")
    static let uiTestScenario = UITestScenario.requested
    static let debugDataIsolationEnabled = pairwiseDemoEnabled || chartGalleryEnabled || uiTestScenario != nil
    #else
    static let pairwiseDemoEnabled = false
    static let chartGalleryEnabled = false
    static let debugDataIsolationEnabled = false
    #endif

    static var estimateSourceDescriptor: DataSource {
        DataSource(
            id: estimateSourceID,
            displayName: "HeartSync Estimate",
            transport: .manual,
            model: "Modelled, not measured"
        )
    }

    func ensureEstimateSourceExists() {
        guard store.source(id: Self.estimateSourceID) == nil else { return }
        store.upsert(Self.estimateSourceDescriptor)
    }

    // MARK: - Oura schedule

    private func startOuraSchedule() {
        ouraTimerTask?.cancel()
        ouraTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                // Named only for the read and for the sync, never across the sleep between.
                guard let interval = self?.ouraSyncSeconds else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard await self?.runScheduledOuraSync() != nil else { return }
            }
        }
    }

    private var ouraSyncSeconds: TimeInterval { max(300, settings.snapshot.ouraSyncInterval) }

    private func runScheduledOuraSync() async {
        guard settings.snapshot.autoSyncOura, transports.hasOuraAuthorization() else { return }
        // Unattended, so it honours the backoff a 429 installed and the minimum interval.
        // User-initiated refreshes bypass the interval and always attempt.
        await transports.syncOura(false, Self.minimumForegroundOuraInterval(settings.snapshot))
    }

    // MARK: - Device management

    /// Removes a source and its readings, database first.
    ///
    /// The store deletes before anything else is forgotten. If the write fails the source, the
    /// peripheral, and the Oura credential are all still there and the caller is told, instead
    /// of a device that vanished from the list and returned at the next launch.
    @discardableResult
    func removeSource(_ source: DataSource) -> HealthStore.SourceMutationResult {
        let result = store.removeSourceResult(id: source.id)
        guard !result.isFailure else { return result }
        if source.transport == .bluetooth {
            bluetooth.forget(sourceID: source.id)
        }
        if source.id == DataSource.ouraSourceID {
            oura.disconnect()
        }
        return result
    }

    /// Pulls date of birth from Health so the age-based estimate can be configured without
    /// collecting an unrelated sensitive characteristic.
    func importProfileFromHealth() {
        let birthDate = healthKit.readDateOfBirth()
        var profile = settings.profile
        if let birthDate { profile.birthDate = birthDate }
        settings.profile = profile
    }
}
