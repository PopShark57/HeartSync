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

    let store = HealthStore(persistenceEnabled: !AppModel.pairwiseDemoEnabled)
    let settings = AppSettings()
    let bluetooth = BluetoothManager()
    let healthKit = HealthKitManager()
    let oura = OuraManager()

    private var derivedTask: Task<Void, Never>?
    private var ouraTimerTask: Task<Void, Never>?
    private var hasStarted = false

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        #if DEBUG
        if Self.pairwiseDemoEnabled {
            DebugAnalysisFixtures.populate(store: store)
            return
        }
        #endif

        await settings.loadIfNeeded()
        await store.loadIfNeeded()
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
            onReadings: { [weak self] readings in
                self?.ingest(readings)
            },
            onDeletedSampleIDs: { [weak self] ids in
                self?.removeDeletedHealthKitSamples(ids)
            }
        )
        await oura.configure(store: store) { [weak self] readings in
            self?.ingest(readings, replacingExisting: true)
        }

        // Re-attach to devices already granted, without prompting again.
        if healthKit.availability == .authorized {
            await healthKit.syncAll()
        }

        startDerivedMetrics()
        startOuraSchedule()
    }

    /// Called when the app returns to the foreground.
    func refresh() async {
        #if DEBUG
        guard !Self.pairwiseDemoEnabled else { return }
        #endif
        bluetooth.reconnectKnownDevices()
        if healthKit.availability == .authorized {
            await healthKit.syncAll()
        }
        applyRetentionSettings()
        if settings.snapshot.autoSyncOura, oura.hasAuthorization {
            await oura.sync()
        }
        recomputeDerivedMetrics()
    }

    /// Pushes the user's retention preference into the store, and pins the compaction
    /// horizon to the shortest value the store allows.
    ///
    /// Retention and compaction are separate knobs: retention decides what is *deleted*,
    /// compaction decides what is *downsampled* while still inside retention. Compacting as
    /// early as the store permits preserves the windowed medians and pairwise verdicts that
    /// comparison and export consume, while permanently discarding raw sample counts and
    /// within-window spread. This deliberately asks for the floor rather than scaling with
    /// retention; the Settings copy discloses that irreversible tradeoff. `HealthStore`
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
    }

    // MARK: - Ingest

    /// The single routing seam for all three transports.
    ///
    /// Write-back mirrors the readings the store *accepted*, never the input batch: a batch
    /// of ten containing one new reading and nine already-known duplicates must put exactly
    /// one sample into Apple Health. `append(contentsOf:)`/`upsert(contentsOf:)` return the
    /// stored subset precisely so this filter can run over it.
    private func ingest(_ readings: [Reading], replacingExisting: Bool = false) {
        let accepted = replacingExisting
            ? store.upsert(contentsOf: readings)
            : store.append(contentsOf: readings)
        guard !accepted.isEmpty else { return }

        // Optional write-back into Apple Health, measured Bluetooth values only.
        if settings.snapshot.mirrorBluetoothToHealthKit, healthKit.availability == .authorized {
            let mirrorable = accepted.filter { reading in
                reading.provenance == .measured
                    && store.source(id: reading.sourceID)?.transport == .bluetooth
            }
            guard !mirrorable.isEmpty else { return }
            Task { [healthKit] in
                for reading in mirrorable { await healthKit.write(reading) }
            }
        }
    }

    /// Drops readings whose HealthKit samples the user deleted in Health.
    ///
    /// A HealthKit-sourced `Reading.id` *is* the `HKSample` uuid, and `HKDeletedObject.uuid`
    /// reports that same value, so deleted ids map onto stored readings directly with no
    /// lookup table. Deletion is deliberately silent for the user: a sample removed upstream
    /// must stop contributing to comparisons, but an analysis already exported keeps whatever
    /// it was exported with.
    private func removeDeletedHealthKitSamples(_ sampleIDs: [UUID]) {
        guard !sampleIDs.isEmpty else { return }
        let removed = store.remove(readingIDs: sampleIDs)
        guard removed > 0 else { return }
        logger.info("Removed \(removed, privacy: .public) reading(s) deleted from Apple Health")
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
        var produced: [Reading] = []
        produced += vo2MaxEstimates()
        if let bp = bloodPressureEstimateReadings() { produced += bp }
        guard !produced.isEmpty else { return }
        store.append(contentsOf: produced)
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
    static let pairwiseDemoEnabled = ProcessInfo.processInfo.arguments.contains("--pairwise-demo")
    #else
    static let pairwiseDemoEnabled = false
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

    /// Pulls age and sex from Health so the estimators have what they need without the
    /// user re-entering it.
    func importProfileFromHealth() {
        let characteristics = healthKit.readCharacteristics()
        var profile = settings.profile
        if let birthDate = characteristics.birthDate { profile.birthDate = birthDate }
        if let sex = characteristics.sex { profile.sex = sex }
        settings.profile = profile
    }
}
