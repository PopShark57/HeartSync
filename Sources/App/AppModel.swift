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

    let store = HealthStore(persistenceEnabled: !AppModel.debugDataIsolationEnabled)
    let settings = AppSettings(persistenceEnabled: !AppModel.debugDataIsolationEnabled)
    let bluetooth = BluetoothManager()
    let healthKit = HealthKitManager()
    let oura = OuraManager()
    private let watchCompanion = WatchCompanionPublisher()

    enum StartupState: Equatable, Sendable {
        case loading
        case ready
        case temporarilyUnavailable(String)
    }

    private(set) var startupState: StartupState = .loading
    private(set) var startupNotice: String?

    private var derivedTask: Task<Void, Never>?
    private var ouraTimerTask: Task<Void, Never>?
    private var hasStarted = false

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        startupState = .loading

        #if DEBUG
        if Self.pairwiseDemoEnabled {
            DebugAnalysisFixtures.populate(store: store)
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
            case .ouraPartial:
                oura.injectPartialFailureForUITesting()
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
                await self.refresh()
                self.watchCompanion.publishNow()
            }
        }
        await settings.loadIfNeeded()
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
        applyRetentionSettings()

        bluetooth.configure(store: store) { [weak self] reading in
            self?.ingest([reading])
        }
        healthKit.configure(
            store: store,
            onReadings: { [weak self] readings, sources, deletedIDs in
                self?.ingest(
                    readings,
                    updatingSources: sources,
                    removingReadingIDs: deletedIDs
                ) ?? false
            }
        )
        // Cold start always begins as `.notDetermined`; restore a prior Connect without
        // re-prompting so observers install and the sync below can run.
        await healthKit.restoreSessionIfNeeded()
        await oura.configure(store: store) { [weak self] readings, sources, withdrawnIDs in
            self?.ingest(
                readings,
                updatingSources: sources,
                removingReadingIDs: withdrawnIDs,
                replacingExisting: true
            ) ?? false
        }

        // Re-attach to devices already granted, without prompting again.
        if healthKit.availability == .authorized {
            await healthKit.syncAll()
        }

        startDerivedMetrics()
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
        startupNotice = notices.isEmpty ? nil : notices.joined(separator: " ")
    }

    /// Called when the app returns to the foreground.
    func refresh() async {
        #if DEBUG
        guard !Self.pairwiseDemoEnabled else { return }
        #endif
        guard hasStarted else {
            await start()
            return
        }
        bluetooth.reconnectKnownDevices()
        if healthKit.availability == .authorized {
            await healthKit.syncAll()
        }
        applyRetentionSettings()
        if settings.snapshot.autoSyncOura, oura.hasAuthorization {
            await oura.sync()
        }
        recomputeDerivedMetrics()
        watchCompanion.publishNow()
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
        store.retention = TimeInterval(settings.snapshot.retentionDays) * 86_400
        store.compactionAge = HealthStore.minimumCompactionAge
    }

    func enterBackground() async {
        #if DEBUG
        guard !Self.pairwiseDemoEnabled else { return }
        #endif
        bluetooth.stopScan()
        await store.saveNow()
        await settings.saveNow()
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
        if settings.snapshot.mirrorBluetoothToHealthKit, healthKit.availability == .authorized {
            let mirrorable = accepted.filter { reading in
                reading.provenance == .measured
                    && store.source(id: reading.sourceID)?.transport == .bluetooth
            }
            if !mirrorable.isEmpty {
                Task { [healthKit] in
                    for reading in mirrorable { await healthKit.write(reading) }
                }
            }
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
                // `guard let` rather than `self?`: once the model is gone the loop must end,
                // not keep waking every 300 seconds to do nothing. Same shape as
                // `startOuraSchedule`.
                guard let self else { return }
                self.recomputeDerivedMetrics()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func recomputeDerivedMetrics() {
        let vo2 = vo2MaxEstimates()
        let bloodPressure = bloodPressureEstimateReadings() ?? []
        let produced = vo2 + bloodPressure

        let startOfToday = Calendar.current.startOfDay(for: .now)
        store.reconcileEstimates(
            kinds: [.vo2Max],
            keeping: Set(vo2.map(\.id)),
            currentSince: settings.snapshot.vo2MaxEstimateEnabled ? startOfToday : nil
        )
        store.reconcileEstimates(
            kinds: [.bloodPressureSystolic, .bloodPressureDiastolic],
            keeping: Set(bloodPressure.map(\.id)),
            currentSince: settings.canEstimateBloodPressure ? Date.now.addingTimeInterval(-300) : nil
        )
        guard !produced.isEmpty else { return }
        // Estimates are revisable documents, not append-only measurements. Stable IDs make
        // an identical recomputation a no-op and let new inputs revise the same day/slot.
        store.upsert(contentsOf: produced)
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

        for source in store.enabledSources {
            // Skip sources that already measure it.
            let measured = store.readings(kind: .vo2Max, in: window)
                .contains { $0.sourceID == source.id && $0.provenance == .measured }
            if measured { continue }

            let restingSamples = store.readings(kind: .restingHeartRate, in: window)
                .filter { $0.sourceID == source.id }
            guard let latest = restingSamples.last else { continue }
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
                provenance: .estimated
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

        return [
            Reading(
                id: UUID(stableFrom: "derived.bp.sys.\(slot)"),
                sourceID: Self.estimateSourceID,
                kind: .bloodPressureSystolic,
                value: estimate.systolic,
                start: stamp,
                provenance: .estimated
            ),
            Reading(
                id: UUID(stableFrom: "derived.bp.dia.\(slot)"),
                sourceID: Self.estimateSourceID,
                kind: .bloodPressureDiastolic,
                value: estimate.diastolic,
                start: stamp,
                provenance: .estimated
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
        case ouraPartial

        static var requested: Self? {
            let prefix = "--ui-test-"
            guard let argument = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix(prefix)
            }) else { return nil }
            return Self(rawValue: String(argument.dropFirst(prefix.count)))
        }
    }

    static let pairwiseDemoEnabled = ProcessInfo.processInfo.arguments.contains("--pairwise-demo")
    static let uiTestScenario = UITestScenario.requested
    static let debugDataIsolationEnabled = pairwiseDemoEnabled || uiTestScenario != nil
    #else
    static let pairwiseDemoEnabled = false
    static let debugDataIsolationEnabled = false
    #endif

    func ensureEstimateSourceExists() {
        guard store.source(id: Self.estimateSourceID) == nil else { return }
        store.upsert(DataSource(
            id: Self.estimateSourceID,
            displayName: "HeartSync Estimate",
            transport: .manual,
            model: "Modelled, not measured"
        ))
    }

    // MARK: - Oura schedule

    private func startOuraSchedule() {
        ouraTimerTask?.cancel()
        ouraTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = max(300, self.settings.snapshot.ouraSyncInterval)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                if self.settings.snapshot.autoSyncOura, self.oura.hasAuthorization {
                    // syncIfDue, not sync: this is the unattended cadence, so it must honour
                    // the backoff a 429 installed. User-initiated refreshes still call sync()
                    // directly and always attempt.
                    await self.oura.syncIfDue()
                }
            }
        }
    }

    // MARK: - Device management

    func removeSource(_ source: DataSource) {
        if source.transport == .bluetooth {
            bluetooth.forget(sourceID: source.id)
        }
        if source.id == DataSource.ouraSourceID {
            guard oura.disconnect() else { return }
        }
        store.remove(sourceID: source.id)
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
