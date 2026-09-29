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
            _ onReadings: @escaping @MainActor ([Reading]) -> Void
        ) -> Void
        var reconnectBluetooth: @MainActor () -> Void
        var stopBluetoothScan: @MainActor () -> Void
        var configureHealthKit: @MainActor (
            HealthStore,
            _ onReadings: @escaping @MainActor ([Reading], [DataSource], Set<UUID>) -> Bool
        ) -> Void
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

        static func live(
            bluetooth: BluetoothManager,
            healthKit: HealthKitManager,
            oura: OuraManager
        ) -> Self {
            Self(
                configureBluetooth: { store, onReading, onReadings in
                    bluetooth.configure(store: store, onReading: onReading, onReadings: onReadings)
                },
                reconnectBluetooth: { bluetooth.reconnectKnownDevices() },
                stopBluetoothScan: { bluetooth.stopScan() },
                configureHealthKit: { store, onReadings in
                    healthKit.configure(store: store, onReadings: onReadings)
                },
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
                }
            )
        }

        /// Does nothing and reports nothing authorized.
        static let inert = Self(
            configureBluetooth: { _, _, _ in },
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

    private var derivedTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var ouraTimerTask: Task<Void, Never>?
    private var hasStarted = false
    /// Whether the user has chosen a retention period in this session, which is what lets a
    /// settings file that was reset or set aside delete history again.
    private var retentionChoiceIsUsers = false

    // MARK: - Lifecycle

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

        watchCompanion.start(store: store) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.watchCompanion.publishNow()
                // Watch messages may arrive while protected history is still loading.
                guard self.startupState == .ready else { return }
                await self.refreshForWatch()
                self.watchCompanion.publishNow()
            }
        }
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

        transports.configureBluetooth(
            store,
            { [weak self] reading in
                self?.ingest([reading])
            },
            // A ring history import commits as one idempotent batch.
            { [weak self] readings in
                self?.ingest(readings)
            }
        )
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
        recomputeDerivedMetrics()
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
    func resetLocalData(_ mode: DataResetMode) async -> Bool {
        let storeCleared = store.deleteAllReadings()
        let ouraSaved: Bool
        switch mode {
        case .clearForResync:
            healthKit.resetAnchors()
            ouraSaved = await oura.clearCachedData(keepingAuthorization: true)
        case .forgetImportedHistory:
            // Keeping HealthKit anchors means old imported Health history does not
            // immediately return; future samples after the committed anchors still do.
            ouraSaved = await oura.clearCachedData(keepingAuthorization: false)
        }
        recomputeDerivedMetrics()
        let storeSaved = await store.saveNow()
        let settingsSaved = await settings.saveNow()
        return storeCleared && ouraSaved && storeSaved && settingsSaved
    }

    // MARK: - Ingest

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
                guard self?.runDerivedTick() != nil else { return }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func runDerivedTick() {
        recomputeDerivedMetrics()
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

    func recomputeDerivedMetrics() {
        // Estimates are only reconciled against a loaded store: before that, "no estimate
        // is current" would be judged against nothing.
        guard store.loadState == .loaded || !store.persistenceEnabled else { return }
        let vo2 = vo2MaxEstimates()
        let bloodPressure = bloodPressureEstimateReadings() ?? []
        let produced = vo2 + bloodPressure

        let startOfToday = Calendar.current.startOfDay(for: .now)
        store.reconcileEstimates(
            kinds: [.vo2Max],
            keeping: Set(vo2.map(\.id)),
            currentSince: settings.snapshot.vo2MaxEstimateEnabled ? startOfToday : nil
        )
        // Scoped to the synthetic estimate source. A ring reports its blood pressure as an
        // estimate under its own source, and that must never be swept up here.
        store.reconcileEstimates(
            kinds: [.bloodPressureSystolic, .bloodPressureDiastolic],
            keeping: Set(bloodPressure.map(\.id)),
            currentSince: settings.canEstimateBloodPressure ? Date.now.addingTimeInterval(-300) : nil,
            sourceID: Self.estimateSourceID
        )
        guard !produced.isEmpty else { return }
        // Estimates are revisable documents, not append-only measurements. Stable IDs make
        // an identical recomputation a no-op and let new inputs revise the same day/slot.
        // The estimate source is written in the same transaction, so a removed source cannot
        // leave the readings filed under "Unknown device".
        _ = store.upsertBatch(
            readings: produced,
            updatingSources: bloodPressure.isEmpty ? [] : [Self.estimateSourceDescriptor]
        )
    }

    /// A VO\u{2082} max estimate per source that reports resting heart rate but no measured
    /// VO\u{2082} max of its own.
    ///
    /// Sources that measure VO\u{2082} max directly (an Apple Watch does) are skipped: replacing
    /// or duplicating a real measurement with a model would be worse data, and comparing a
    /// device against an estimate derived from itself is circular.
    private func vo2MaxEstimates() -> [Reading] {
        guard settings.snapshot.vo2MaxEstimateEnabled else { return [] }
        guard let maxHR = settings.profile.estimatedMaxHeartRate else { return [] }

        let window = DateInterval(start: .now.addingTimeInterval(-7 * 86_400), end: .now)
        var result: [Reading] = []

        // One read of each kind for all sources, not one per source.
        let measuredSources = Set(
            store.readings(kind: .vo2Max, in: window)
                .filter { $0.provenance == .measured }
                .map(\.sourceID)
        )
        let restingReadings = store.readings(kind: .restingHeartRate, in: window)

        for source in store.enabledSources {
            // Skip sources that already measure it.
            if measuredSources.contains(source.id) { continue }

            guard let latest = restingReadings.last(where: { $0.sourceID == source.id }) else { continue }
            guard let value = Estimators.vo2Max(
                restingHeartRate: latest.value,
                maxHeartRate: maxHR
            ) else { continue }

            // One estimate per source per day; the id makes repeats collapse.
            let day = Calendar.current.startOfDay(for: latest.end)
            result.append(Reading(
                id: UUID(stableFrom: "derived.vo2.\(source.id).\(Int(day.timeIntervalSince1970))"),
                sourceID: source.id,
                kind: .vo2Max,
                value: value,
                start: day,
                end: day.addingTimeInterval(86_400),
                provenance: .estimated,
                metadata: ReadingMetadata(modelledBy: ReadingMetadata.heartSyncModel)
            ))
        }
        return result
    }

    /// The blood-pressure trend index, when the user has enabled it and calibrated it.
    private func bloodPressureEstimateReadings() -> [Reading]? {
        guard settings.canEstimateBloodPressure,
              let calibration = settings.profile.bpCalibration
        else { return nil }

        // Anchor on the most recent heart rate from any enabled source, since the index
        // describes the user's state rather than any one device's opinion of it.
        let recent = DateInterval(start: .now.addingTimeInterval(-600), end: .now)
        let hrWindows = ComparisonEngine.windows(from: store.readings(kind: .heartRate, in: recent), kind: .heartRate)
        guard let latestHR = hrWindows.last?.consensus else { return nil }

        let rmssdWindows = ComparisonEngine.windows(
            from: store.readings(kind: .hrvRMSSD, in: DateInterval(start: .now.addingTimeInterval(-3600), end: .now)),
            kind: .hrvRMSSD
        )
        let latestRMSSD = rmssdWindows.last?.consensus

        guard let estimate = Estimators.bloodPressure(
            calibration: calibration,
            currentHeartRate: latestHR,
            currentRMSSD: latestRMSSD
        ) else { return nil }

        // Quantise the timestamp to five minutes so repeated recomputation within a window
        // updates one reading rather than accumulating dozens.
        let slot = Int(Date.now.timeIntervalSince1970 / 300)
        let stamp = Date(timeIntervalSince1970: Double(slot) * 300)
        let metadata = ReadingMetadata(modelledBy: ReadingMetadata.heartSyncModel)

        return [
            Reading(
                id: UUID(stableFrom: "derived.bp.sys.\(slot)"),
                sourceID: Self.estimateSourceID,
                kind: .bloodPressureSystolic,
                value: estimate.systolic,
                start: stamp,
                provenance: .estimated,
                metadata: metadata
            ),
            Reading(
                id: UUID(stableFrom: "derived.bp.dia.\(slot)"),
                sourceID: Self.estimateSourceID,
                kind: .bloodPressureDiastolic,
                value: estimate.diastolic,
                start: stamp,
                provenance: .estimated,
                metadata: metadata
            ),
        ]
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
