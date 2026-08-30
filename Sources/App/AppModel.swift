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

    let store = HealthStore()
    let settings = AppSettings()
    let bluetooth = BluetoothManager()
    let healthKit = HealthKitManager()
    let oura = OuraManager()

    /// Bumped whenever readings change, so views can key expensive recomputation off a
    /// single value instead of diffing thousands of readings.
    private(set) var dataVersion = 0

    private var derivedTask: Task<Void, Never>?
    private var ouraTimerTask: Task<Void, Never>?
    private var hasStarted = false

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        await settings.loadIfNeeded()
        await store.loadIfNeeded()
        store.retention = TimeInterval(settings.snapshot.retentionDays) * 86_400

        bluetooth.configure(store: store) { [weak self] reading in
            self?.ingest([reading])
        }
        healthKit.configure(store: store) { [weak self] readings in
            self?.ingest(readings)
        }
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
        bluetooth.reconnectKnownDevices()
        if healthKit.availability == .authorized {
            await healthKit.syncAll()
        }
        if settings.snapshot.autoSyncOura, oura.hasAuthorization {
            await oura.sync()
        }
        recomputeDerivedMetrics()
    }

    func enterBackground() async {
        bluetooth.stopScan()
        await store.saveNow()
        await settings.saveNow()
    }

    // MARK: - Ingest

    private func ingest(_ readings: [Reading], replacingExisting: Bool = false) {
        let accepted = replacingExisting
            ? store.upsert(contentsOf: readings)
            : store.append(contentsOf: readings)
        guard accepted > 0 else { return }
        dataVersion &+= 1

        // Optional write-back into Apple Health, measured Bluetooth values only.
        if settings.snapshot.mirrorBluetoothToHealthKit, healthKit.availability == .authorized {
            let mirrorable = readings.filter { reading in
                reading.provenance == .measured
                    && store.source(id: reading.sourceID)?.transport == .bluetooth
            }
            guard !mirrorable.isEmpty else { return }
            Task { [healthKit] in
                for reading in mirrorable { await healthKit.write(reading) }
            }
        }
    }

    // MARK: - Derived metrics

    /// Recomputes estimates on a slow timer. They depend on windows of data rather than
    /// single samples, so recomputing on every incoming reading would be wasteful and
    /// would produce a jittery display.
    private func startDerivedMetrics() {
        derivedTask?.cancel()
        derivedTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.recomputeDerivedMetrics()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func recomputeDerivedMetrics() {
        var produced: [Reading] = []
        produced += vo2MaxEstimates()
        if let bp = bloodPressureEstimateReadings() { produced += bp }
        guard !produced.isEmpty else { return }
        if store.append(contentsOf: produced) > 0 { dataVersion &+= 1 }
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
                    await self.oura.sync()
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
        dataVersion &+= 1
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

    // MARK: - Queries for views

    func windows(kind: MetricKind, in range: DateInterval) -> [ComparisonWindow] {
        ComparisonEngine.windows(from: store.readings(kind: kind, in: range), kind: kind, range: range)
    }

    func discrepancies(in range: DateInterval) -> [Discrepancy] {
        ComparisonEngine.allDiscrepancies(from: store.readings(in: range), range: range)
            .filter { $0.severity >= settings.snapshot.discrepancyThreshold }
    }

    func liveValues(kind: MetricKind) -> [String: Reading] {
        ComparisonEngine.latestBySource(from: store.readings(kind: kind), kind: kind)
    }
}
