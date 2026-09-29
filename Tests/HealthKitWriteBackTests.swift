@preconcurrency import HealthKit
import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("HealthKit date of birth")
struct HealthKitDateOfBirthTests {

    @Test("Health's Gregorian birth date is read as Gregorian, whatever calendar the phone uses")
    func dateOfBirthIsGregorian() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 1990
        components.month = 6
        components.day = 15

        let date = try #require(HealthKitManager.dateOfBirth(from: components))

        let read = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        #expect(read.year == 1990)
        #expect(read.month == 6)
        #expect(read.day == 15)

        var profile = UserProfile()
        profile.birthDate = date
        #expect(profile.age != nil)

        // What `Calendar.current.date(from:)` did on a Buddhist-calendar phone: year 1990 is
        // 1447 CE, `UserProfile.age` rejects it, and the age-based estimates disappear.
        let buddhist = try #require(Calendar(identifier: .buddhist).date(from: components))
        #expect(buddhist != date)
        profile.birthDate = buddhist
        #expect(profile.age == nil)
    }
}

@Suite("HealthKit write-back")
@MainActor
struct HealthKitWriteBackTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func strap(transport: SourceTransport = .bluetooth) -> DataSource {
        DataSource(id: "strap", displayName: "Chest strap", transport: transport, model: "Polar H10 (firmware 3.1.1)")
    }

    private func reading(
        _ kind: MetricKind = .heartRate,
        value: Double = 72,
        provenance: Provenance = .measured,
        offset: TimeInterval = -10
    ) -> Reading {
        Reading(
            sourceID: "strap", kind: kind, value: value,
            start: now.addingTimeInterval(offset), provenance: provenance
        )
    }

    @Test("A measured Bluetooth reading is planned with a sync identifier and its device")
    func plansAttributableIdempotentWrite() throws {
        let measured = reading()
        let plan = try #require(HealthKitManager.writePlan(for: measured, source: strap(), now: now))

        #expect(plan.identifier == .heartRate)
        #expect(plan.value == 72)
        #expect(plan.syncIdentifier == "heartsync.\(measured.id.uuidString)")
        #expect(plan.deviceName == "Chest strap")
        #expect(plan.deviceModel == "Polar H10 (firmware 3.1.1)")

        let sample = try #require(HealthKitManager.sample(from: plan))
        #expect(sample.metadata?[HKMetadataKeySyncIdentifier] as? String == plan.syncIdentifier)
        #expect(sample.metadata?[HKMetadataKeySyncVersion] as? Int == 1)
        #expect(sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool == false)
        #expect(sample.device?.name == "Chest strap")
        #expect(sample.device?.model == "Polar H10 (firmware 3.1.1)")

        // The same reading always plans the same identifier, so a retried save cannot duplicate.
        let again = try #require(HealthKitManager.writePlan(for: measured, source: strap(), now: now))
        #expect(again.syncIdentifier == plan.syncIdentifier)
    }

    @Test("Oxygen saturation is written as Health's fraction")
    func oxygenSaturationIsScaledBack() throws {
        let plan = try #require(HealthKitManager.writePlan(for: reading(.spo2, value: 97), source: strap(), now: now))
        #expect(plan.value == 0.97)
    }

    @Test("Estimates, Health and Oura values, and unknown sources are never written")
    func refusesWhatMustNotEnterTheHealthRecord() {
        #expect(HealthKitManager.writePlan(for: reading(provenance: .estimated), source: strap(), now: now) == nil)
        #expect(HealthKitManager.writePlan(for: reading(provenance: .derived), source: strap(), now: now) == nil)
        #expect(HealthKitManager.writePlan(for: reading(), source: strap(transport: .healthKit), now: now) == nil)
        #expect(HealthKitManager.writePlan(for: reading(), source: strap(transport: .oura), now: now) == nil)
        #expect(HealthKitManager.writePlan(for: reading(), source: nil, now: now) == nil)
        // A metric outside the share list.
        #expect(HealthKitManager.writePlan(for: reading(.respiratoryRate, value: 14), source: strap(), now: now) == nil)
        // A timestamp in the future.
        #expect(HealthKitManager.writePlan(for: reading(offset: 600), source: strap(), now: now) == nil)
    }

    @Test("Readings are queued and saved in one batch, not one by one")
    func queuesInsteadOfSavingEach() {
        let manager = HealthKitManager()
        manager.enqueueWrites([reading(), reading(value: 73), reading(value: 74)])
        manager.enqueueWrites([reading(value: 75)])
        #expect(manager.pendingWrites.count == 4)
        manager.writeFlushTask?.cancel()
    }

    @Test("The queue is bounded, and dropping is reported instead of silent")
    func queueIsBounded() {
        let manager = HealthKitManager()
        let many = (0..<(HealthKitManager.maximumPendingWrites + 25)).map { reading(value: 60 + Double($0 % 30)) }
        manager.enqueueWrites(many)
        #expect(manager.pendingWrites.count == HealthKitManager.maximumPendingWrites)
        #expect(manager.writeBackDroppedCount == 25)
        #expect(manager.writeBackIssue != nil)
        manager.writeFlushTask?.cancel()
    }

    @Test("A refusal to save is a named, persistent message")
    func refusalIsClassified() {
        let denied = HKError(.errorAuthorizationDenied)
        let unavailable = HKError(.errorDatabaseInaccessible)
        #expect(HealthKitManager.isWriteRefusal(denied))
        #expect(!HealthKitManager.isWriteRefusal(unavailable))
    }
}
