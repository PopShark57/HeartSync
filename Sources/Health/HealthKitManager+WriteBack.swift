@preconcurrency import HealthKit
import Foundation

/// Optional write-back of measured Bluetooth readings into Apple Health.
///
/// Only measured values from Bluetooth sources are ever queued (`AppModel.ingest` filters
/// them, and `plan` refuses anything else again): estimates, and anything that came from
/// Health or Oura, never enter the user's health record.
extension HealthKitManager {

    /// Longest a queued reading waits before the next save.
    nonisolated static let writeFlushInterval: TimeInterval = 30
    /// Cap on queued readings. At two readings a second per metric this is hours of
    /// outage, after which the oldest are dropped and counted rather than growing forever.
    nonisolated static let maximumPendingWrites = 5_000

    /// Everything needed to build one sample, as plain values. Kept apart from
    /// `HKQuantitySample` so the rules (what may be written, how it is identified) are
    /// testable without a device.
    struct WritePlan: Equatable, Sendable {
        var identifier: HKQuantityTypeIdentifier
        var unit: HKUnit
        var value: Double
        var start: Date
        var end: Date
        /// `HKMetadataKeySyncIdentifier`: a retried save of the same reading is recognised
        /// and ignored instead of duplicating the sample.
        var syncIdentifier: String
        var deviceName: String?
        var deviceModel: String?
    }

    /// The write for `reading`, or nil when it must not be written.
    static func writePlan(for reading: Reading, source: DataSource?, now: Date = .now) -> WritePlan? {
        guard reading.provenance == .measured else { return nil }
        guard source?.transport == .bluetooth else { return nil }
        guard reading.start <= reading.end,
              reading.start <= now,
              reading.end <= now,
              reading.start.timeIntervalSinceReferenceDate.isFinite,
              reading.end.timeIntervalSinceReferenceDate.isFinite
        else { return nil }
        guard let mapping = mappings.first(where: { $0.kind == reading.kind }),
              let type = mapping.quantityType,
              shareTypes.contains(type)
        else { return nil }
        return WritePlan(
            identifier: mapping.identifier,
            unit: mapping.unit,
            value: reading.value / mapping.scale,
            start: reading.start,
            end: reading.end,
            syncIdentifier: "heartsync.\(reading.id.uuidString)",
            deviceName: source?.displayName,
            deviceModel: source?.model
        )
    }

    nonisolated static func sample(from plan: WritePlan) -> HKQuantitySample? {
        guard let type = HKQuantityType.quantityType(forIdentifier: plan.identifier) else { return nil }
        // Attribute the value to the strap that produced it, not only to HeartSync.
        let device = HKDevice(
            name: plan.deviceName,
            manufacturer: nil,
            model: plan.deviceModel,
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: nil,
            udiDeviceIdentifier: nil
        )
        return HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: plan.unit, doubleValue: plan.value),
            start: plan.start,
            end: plan.end,
            device: device,
            metadata: [
                HKMetadataKeyWasUserEntered: false,
                HKMetadataKeySyncIdentifier: plan.syncIdentifier,
                HKMetadataKeySyncVersion: 1,
            ]
        )
    }

    /// Queues readings for the next batched save. Returns immediately.
    func enqueueWrites(_ readings: [Reading]) {
        guard !readings.isEmpty else { return }
        pendingWrites.append(contentsOf: readings)
        let excess = pendingWrites.count - Self.maximumPendingWrites
        if excess > 0 {
            pendingWrites.removeFirst(excess)
            writeBackDroppedCount += excess
            writeBackIssue = "Apple Health could not be reached for a while, so \(writeBackDroppedCount) readings were not saved to it."
        }
        guard writeFlushTask == nil else { return }
        writeFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.writeFlushInterval))
            guard !Task.isCancelled else { return }
            await self?.flushWrites()
        }
    }

    /// Saves everything queued in one call. Safe to call at any time, including from a
    /// background transition; concurrent calls fold into the one already running.
    func flushWrites() async {
        writeFlushTask?.cancel()
        writeFlushTask = nil
        guard !isFlushingWrites, !pendingWrites.isEmpty else { return }
        isFlushingWrites = true
        defer { isFlushingWrites = false }

        let batch = pendingWrites
        pendingWrites.removeAll()

        let now = Date.now
        var plans: [WritePlan] = []
        for reading in batch {
            if let plan = Self.writePlan(for: reading, source: store?.source(id: reading.sourceID), now: now) {
                plans.append(plan)
            }
        }
        guard !plans.isEmpty else { return }

        // Permission can be withdrawn in Settings at any time. Ask before saving, so a
        // revoked type is reported once instead of failing silently for every reading.
        var allowed: [WritePlan] = []
        var refused: Set<String> = []
        for plan in plans {
            guard let type = HKQuantityType.quantityType(forIdentifier: plan.identifier) else { continue }
            if healthStore.authorizationStatus(for: type) == .sharingAuthorized {
                allowed.append(plan)
            } else {
                refused.insert(plan.identifier.rawValue)
            }
        }
        if !refused.isEmpty {
            writeBackDroppedCount += plans.count - allowed.count
            writeBackIssue = "Apple Health is not allowing HeartSync to save some measurements. Allow writing in Settings › Health › Data Access & Devices › HeartSync."
        }
        let samples = allowed.compactMap(Self.sample(from:))
        guard !samples.isEmpty else { return }

        do {
            try await healthStore.save(samples)
            if refused.isEmpty { writeBackIssue = nil }
        } catch {
            logger.error("Write-back failed: \(error.localizedDescription, privacy: .public)")
            if Self.isWriteRefusal(error) {
                writeBackDroppedCount += samples.count
                writeBackIssue = "Apple Health refused to save HeartSync's measurements. Allow writing in Settings › Health › Data Access & Devices › HeartSync."
            } else {
                // A transient failure: keep the batch. The sync identifiers make the retry
                // idempotent even if part of it did reach Health.
                pendingWrites.insert(contentsOf: batch, at: 0)
                writeBackIssue = "Saving to Apple Health failed and will be retried. \(error.localizedDescription)"
                if writeFlushTask == nil {
                    writeFlushTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(Self.writeFlushInterval))
                        guard !Task.isCancelled else { return }
                        await self?.flushWrites()
                    }
                }
            }
        }
    }

    nonisolated static func isWriteRefusal(_ error: any Error) -> Bool {
        guard let healthError = error as? HKError else { return false }
        return healthError.code == .errorAuthorizationDenied
            || healthError.code == .errorAuthorizationNotDetermined
            || healthError.code == .errorHealthDataRestricted
    }
}
