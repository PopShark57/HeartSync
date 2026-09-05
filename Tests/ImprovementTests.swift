import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("PLX status quality")
struct PLXStatusQualityTests {
    private func measurement(
        measurementStatus: UInt16? = nil,
        deviceStatus: UInt32? = nil
    ) -> PulseOximeterMeasurement {
        PulseOximeterMeasurement(
            spo2Percent: 97,
            pulseRateBPM: 72,
            pulseAmplitudeIndex: 4.5,
            timestamp: nil,
            measurementStatus: measurementStatus,
            deviceAndSensorStatus: deviceStatus
        )
    }

    @Test("Every meaningful measurement-status bit has the specified quality")
    func measurementStatusTable() {
        let cases: [(Int, PulseOximeterMeasurement.QualityReason, String)] = [
            (5, .measurementOngoing, "provisional"),
            (6, .earlyEstimatedData, "provisional"),
            (9, .dataFromStorage, "provisional"),
            (10, .demonstrationData, "invalid"),
            (11, .testingData, "invalid"),
            (12, .calibrationOngoing, "provisional"),
            (13, .measurementUnavailable, "invalid"),
            (14, .questionableMeasurement, "questionable"),
            (15, .invalidMeasurement, "invalid"),
        ]
        for (bit, reason, expected) in cases {
            let quality = measurement(measurementStatus: 1 << bit).quality(for: .continuous)
            #expect(quality.reasons == [reason], "measurement-status bit \(bit)")
            #expect(quality.title.lowercased() == expected, "measurement-status bit \(bit)")
        }
        // Validated/fully-qualified and reserved-clear states do not weaken a frame.
        #expect(measurement(measurementStatus: (1 << 7) | (1 << 8)).quality(for: .spotCheck) == .accepted)
    }

    @Test("Every defined device-status bit has the specified quality")
    func deviceStatusTable() {
        let provisional: [Int] = [0, 9]
        let questionable = Array(2...8) + [10]
        let invalid = [1] + Array(11...15)
        for bit in provisional {
            #expect(measurement(deviceStatus: 1 << bit).quality(for: .continuous).title == "Provisional")
        }
        for bit in questionable {
            #expect(measurement(deviceStatus: 1 << bit).quality(for: .continuous).title == "Questionable")
        }
        for bit in invalid {
            #expect(measurement(deviceStatus: 1 << bit).quality(for: .continuous).title == "Invalid")
        }
        #expect(
            measurement(deviceStatus: 1 << 15).quality(for: .continuous).reasons
                == [.sensorDisconnected]
        )
    }

    @Test("Only accepted PLX frames cross the durable manager policy")
    func durableAdmission() {
        let accepted = measurement()
        let questionable = measurement(deviceStatus: 1 << 5)
        let unavailable = measurement(measurementStatus: 1 << 13)

        let values = PulseOximeterIngestionPolicy.durableValues(
            from: accepted,
            sampleType: .continuous
        )
        #expect(values.map(\.kind) == [.spo2, .heartRate])
        #expect(values.allSatisfy { $0.metadata.quality == .accepted })
        #expect(values.allSatisfy { $0.metadata.pulseAmplitudeIndex == 4.5 })
        #expect(PulseOximeterIngestionPolicy.durableValues(
            from: questionable,
            sampleType: .continuous
        ).isEmpty)
        #expect(PulseOximeterIngestionPolicy.durableValues(
            from: unavailable,
            sampleType: .spotCheck
        ).isEmpty)
    }
}

@Suite("Bluetooth discovery state")
struct BluetoothDiscoveryStateTests {
    private let heartRate = BluetoothDiscoveryState.Candidate(
        id: "hr",
        metrics: [.heartRate, .hrvRMSSD, .hrvSDNN]
    )
    private let oxygen = BluetoothDiscoveryState.Candidate(
        id: "plx",
        metrics: [.spo2, .heartRate]
    )

    @Test("A normal multi-service device waits for every service and subscription")
    func normalMultiService() {
        var state = BluetoothDiscoveryState(serviceIDs: ["180D", "1822"])
        state.finishService(id: "180D", candidates: [heartRate])
        #expect(state.resolution == .discovering)
        state.finishService(id: "1822", candidates: [oxygen])
        #expect(state.resolution == .enabling([.heartRate, .hrvRMSSD, .hrvSDNN, .spo2]))
        state.finishSubscription(id: "plx")
        #expect(state.resolution == .enabling([.heartRate, .hrvRMSSD, .hrvSDNN, .spo2]))
        state.finishSubscription(id: "hr")
        #expect(state.resolution == .ready(
            metrics: [.heartRate, .hrvRMSSD, .hrvSDNN, .spo2],
            warnings: []
        ))
    }

    @Test("No usable characteristic is unsupported, not streaming")
    func unsupported() {
        var state = BluetoothDiscoveryState(serviceIDs: ["180D"])
        state.finishService(id: "180D", candidates: [])
        #expect(state.resolution == .unsupported(details: []))
    }

    @Test("A failed service can coexist with one ready metric")
    func partialService() {
        var state = BluetoothDiscoveryState(serviceIDs: ["180D", "1822"])
        state.finishService(id: "180D", candidates: [heartRate])
        state.finishService(id: "1822", candidates: [], errorDescription: "attribute unavailable")
        state.finishSubscription(id: "hr")
        guard case .ready(let metrics, let warnings) = state.resolution else {
            Issue.record("Expected a partial ready result")
            return
        }
        #expect(metrics.contains(.heartRate))
        #expect(warnings.count == 1)
    }

    @Test("All subscription failures are actionable")
    func subscriptionFailure() {
        var state = BluetoothDiscoveryState(serviceIDs: ["180D"])
        state.finishService(id: "180D", candidates: [heartRate])
        state.finishSubscription(id: "hr", errorDescription: "notifications refused")
        #expect(state.resolution == .subscriptionFailed(
            details: ["Subscription hr: notifications refused"]
        ))
    }

    @Test("A disconnect or reconnect starts a fresh discovery generation")
    func reconnectStartsFresh() {
        var old = BluetoothDiscoveryState(serviceIDs: ["180D"])
        old.finishService(id: "180D", candidates: [heartRate])
        old.finishSubscription(id: "hr")
        #expect(old.resolution != .discovering)

        let reconnected = BluetoothDiscoveryState(serviceIDs: ["180D"])
        #expect(reconnected.resolution == .discovering)
    }

    @Test("Stream values, failures, stalls, and recovery have explicit transitions")
    func streamTransitions() {
        let ready = PeripheralConnectionState.ready([.heartRate, .hrvRMSSD], warning: nil)
        let streaming = ready.receiving(.heartRate)
        #expect(streaming == .streaming([.heartRate]))
        #expect(streaming.stalled("No values") == .streamStalled([.heartRate], "No values"))
        #expect(streaming.stalled("Read error").receiving(.hrvRMSSD) == .streaming([.hrvRMSSD]))
        #expect(PeripheralConnectionState.disconnected.isActive == false)
        #expect(PeripheralConnectionState.connecting.isActive)
    }
}

@Suite("HRV observation intervals")
struct HRVObservationIntervalTests {
    private let end = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A first packet reconstructs elapsed time and cannot claim five minutes")
    func firstPacketTiming() throws {
        var accumulator = HRVAccumulator()
        accumulator.add(intervals: Array(repeating: 1_000.0, count: 20), at: end)
        let candidate = accumulator.emissionIfReady(at: end)
        let emission = try #require(candidate)

        #expect(emission.observationStart == end.addingTimeInterval(-20))
        #expect(emission.observationEnd == end)
        #expect(emission.observationDuration == 20)
        #expect(!emission.includesSDNN)
        #expect(emission.readingMetadata.observationDuration == 20)
        #expect(emission.readingMetadata.acceptedBeatCount == 20)
    }

    @Test("The reconstructed interval lands in its real comparison window")
    func comparisonPlacement() throws {
        let boundary = Date(timeIntervalSince1970: 1_700_000_100)
        let receipt = boundary.addingTimeInterval(20)
        var accumulator = HRVAccumulator()
        let intervals = (0..<20).map { $0.isMultiple(of: 2) ? 950.0 : 1_050.0 }
        accumulator.add(intervals: intervals, at: receipt)
        let candidate = accumulator.emissionIfReady(at: receipt)
        let emission = try #require(candidate)
        let reading = Reading(
            sourceID: "sensor",
            kind: .hrvRMSSD,
            value: emission.metrics.rmssd,
            start: emission.observationStart,
            end: emission.observationEnd,
            provenance: .derived,
            metadata: emission.readingMetadata
        )

        let window = try #require(
            ComparisonEngine.windows(from: [reading], kind: .hrvRMSSD).first
        )
        #expect(window.start == boundary)
    }

    @Test("A packet shorter than twenty seconds cannot emit")
    func shortCapture() {
        var accumulator = HRVAccumulator()
        accumulator.add(intervals: Array(repeating: 750.0, count: 20), at: end)
        #expect(accumulator.emissionIfReady(at: end) == nil)
    }

    @Test("SDNN appears only after a complete five-minute observation")
    func fiveMinuteCapture() throws {
        var accumulator = HRVAccumulator()
        accumulator.add(intervals: Array(repeating: 1_000.0, count: 300), at: end)
        let candidate = accumulator.emissionIfReady(at: end)
        let emission = try #require(candidate)
        #expect(emission.observationDuration == 300)
        #expect(emission.includesSDNN)
    }

    @Test("Reset discards the old observation interval")
    func reset() {
        var accumulator = HRVAccumulator()
        accumulator.add(intervals: Array(repeating: 1_000.0, count: 300), at: end)
        accumulator.reset()
        #expect(accumulator.bufferedBeats == 0)
        #expect(accumulator.bufferedDuration == 0)
        #expect(accumulator.emissionIfReady(at: end) == nil)
    }
}

@Suite("HealthKit sync outcomes")
@MainActor
struct HealthKitSyncOutcomeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Outcome aggregation distinguishes complete, partial, failed, permission, and budget")
    func aggregation() {
        typealias Result = HealthKitManager.TypeSyncResult
        typealias Summary = HealthKitManager.HealthKitSyncSummary
        #expect(Summary.aggregate([.complete("HR")], at: now).outcome == .complete)
        #expect(Summary.aggregate([.failed("HR", "error")], at: now).outcome == .failed)
        #expect(Summary.aggregate([.permissionUnknown("HR", "hidden")], at: now).outcome == .permissionUnknown)
        #expect(Summary.aggregate([.budgetDeferred("HR")], at: now).outcome == .budgetDeferred)
        #expect(Summary.aggregate([
            Result.complete("HR"),
            Result.permissionUnknown("SpO2", "hidden"),
            Result.failed("SDNN", "error"),
        ], at: now).outcome == .partial)
    }

    @Test("One HealthKit writer retains multiple physical-device descriptors")
    func writerIdentity() throws {
        let mapping = try #require(HealthKitManager.mappings.first { $0.kind == .heartRate })
        let descriptors = [
            HealthKitManager.SampleDescriptor(
                id: UUID(),
                sourceBundleIdentifier: "com.vendor.writer",
                sourceName: "Vendor",
                deviceModel: "Model A",
                rawValue: 70,
                start: now,
                end: now
            ),
            HealthKitManager.SampleDescriptor(
                id: UUID(),
                sourceBundleIdentifier: "com.vendor.writer",
                sourceName: "Vendor",
                deviceModel: "Model B",
                rawValue: 72,
                start: now,
                end: now
            ),
        ]
        let converted = HealthKitManager.convert(descriptors: descriptors, mapping: mapping)
        let source = try #require(converted.sources.first)

        #expect(converted.sources.count == 1)
        #expect(source.id == "hk.com.vendor.writer")
        #expect(source.identifiesHealthKitWriter == true)
        #expect(source.observedDeviceModels == ["Model A", "Model B"])
        #expect(source.hasMultipleReportedDevices)
        #expect(source.model?.contains("Multiple reported devices") == true)
    }

    @Test("Oura through Health and Oura Cloud are marked as related transports")
    func upstreamRelationship() throws {
        let mapping = try #require(HealthKitManager.mappings.first { $0.kind == .heartRate })
        let descriptor = HealthKitManager.SampleDescriptor(
            id: UUID(),
            sourceBundleIdentifier: "com.ouraring.oura",
            sourceName: "Oura",
            deviceModel: nil,
            rawValue: 64,
            start: now,
            end: now
        )
        let healthSource = try #require(
            HealthKitManager.convert(descriptors: [descriptor], mapping: mapping).sources.first
        )
        let cloudSource = DataSource(
            id: DataSource.ouraSourceID,
            displayName: "Oura Cloud",
            transport: .oura,
            upstreamDeviceRelationshipID: "oura.account.default"
        )

        #expect(healthSource.model == nil)
        #expect(healthSource.likelyRepresentsSameDevice(as: cloudSource))
    }
}

@Suite("Backward-compatible profile privacy")
struct ProfilePrivacyTests {
    @Test("An old settings payload with biological sex still decodes without storing it")
    func oldSexKeyIsIgnored() throws {
        let data = Data(#"""
        {
          "birthDate": "2023-11-14T22:13:20Z",
          "heightCM": 180,
          "weightKG": 75,
          "sex": "female"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(UserProfile.self, from: data)
        #expect(profile.heightCM == 180)
        #expect(profile.weightKG == 75)
        let reencoded = try JSONEncoder().encode(profile)
        #expect(!String(decoding: reencoded, as: UTF8.self).contains("\"sex\""))
    }

    @Test("Oura personal-info decoding also discards the unused characteristic")
    func oldOuraSexKeyIsIgnored() throws {
        let data = Data(#"{"id":"user","biological_sex":"female","email":"person@example.com"}"#.utf8)
        let value = try JSONDecoder().decode(OuraClient.PersonalInfo.self, from: data)
        #expect(value.id == "user")
        #expect(value.email == "person@example.com")
        let reencoded = try JSONEncoder().encode(value)
        #expect(!String(decoding: reencoded, as: UTF8.self).contains("biological_sex"))
    }
}

@Suite("Transactional database migration", .serialized)
@MainActor
struct TransactionalDatabaseTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeartSync-improvements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("Version-one JSON archives migrate to SQLite without loss")
    func legacyMigration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ReadingArchive(directory: directory)
        let source = DataSource(
            id: "legacy-source",
            displayName: "Legacy source",
            transport: .bluetooth,
            observedMetrics: [.heartRate]
        )
        let reading = Reading(
            id: UUID(stableFrom: "legacy-reading"),
            sourceID: source.id,
            kind: .heartRate,
            value: 72,
            start: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: .measured
        )
        #expect(await archive.write([source], to: ReadingArchive.File.sources))
        #expect(await archive.write([reading], to: ReadingArchive.File.readings))

        let databaseURL = directory.appendingPathComponent("health.sqlite3")
        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: databaseURL,
            archive: archive
        )
        await store.loadIfNeeded()

        #expect(store.loadState == .loaded)
        #expect(store.sources.map(\.id) == [source.id])
        #expect(store.readings == [reading])

        let relaunched = HealthStore(
            persistenceEnabled: true,
            databaseURL: databaseURL,
            archive: archive
        )
        await relaunched.loadIfNeeded()
        #expect(relaunched.sources.map(\.id) == [source.id])
        #expect(relaunched.readings == [reading])
    }

    @Test("An injected transaction failure cannot commit readings without source metadata")
    func transactionRollback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ReadingArchive(directory: directory)
        let databaseURL = directory.appendingPathComponent("health.sqlite3")
        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: databaseURL,
            archive: archive
        )
        await store.loadIfNeeded()
        store.upsert(DataSource(
            id: "sensor",
            displayName: "Sensor",
            transport: .bluetooth
        ))
        store.injectDatabaseFailureOnNextCommitForTesting()
        let reading = Reading(
            sourceID: "sensor",
            kind: .heartRate,
            value: 70,
            start: Date(timeIntervalSinceNow: -1)
        )

        #expect(store.append(reading) == false)
        #expect(store.readingCount == 0)
        #expect(store.source(id: "sensor")?.observedMetrics.isEmpty == true)
        #expect(store.lastPersistenceError != nil)

        let relaunched = HealthStore(
            persistenceEnabled: true,
            databaseURL: databaseURL,
            archive: archive
        )
        await relaunched.loadIfNeeded()
        #expect(relaunched.readingCount == 0)
        #expect(relaunched.source(id: "sensor")?.observedMetrics.isEmpty == true)
    }

    @Test("A new source and its reading roll back as one generation")
    func sourceAndReadingBatchRollback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: directory.appendingPathComponent("health.sqlite3"),
            archive: ReadingArchive(directory: directory)
        )
        await store.loadIfNeeded()
        let source = DataSource(id: "new-source", displayName: "New", transport: .healthKit)
        let reading = Reading(
            sourceID: source.id,
            kind: .heartRate,
            value: 68,
            start: Date(timeIntervalSinceNow: -1)
        )

        store.injectDatabaseFailureOnNextCommitForTesting()
        let result = store.appendBatch(readings: [reading], updatingSources: [source])
        #expect(result.committed == false)
        #expect(result.acceptedReadings.isEmpty)
        #expect(store.source(id: source.id) == nil)
        #expect(store.readingCount == 0)
    }

    @Test("A sample added and deleted in one upstream generation ends absent")
    func additionDeletionOrdering() {
        let store = HealthStore(persistenceEnabled: false)
        let source = DataSource(id: "writer", displayName: "Writer", transport: .healthKit)
        let reading = Reading(
            id: UUID(stableFrom: "added-then-deleted"),
            sourceID: source.id,
            kind: .heartRate,
            value: 69,
            start: Date(timeIntervalSinceNow: -1)
        )

        let result = store.appendBatch(
            readings: [reading],
            updatingSources: [source],
            removingReadingIDs: [reading.id]
        )
        #expect(result.committed)
        #expect(store.readingCount == 0)
    }

    @Test("A failed destructive transaction cannot report success or clear memory")
    func destructiveRollback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: directory.appendingPathComponent("health.sqlite3"),
            archive: ReadingArchive(directory: directory)
        )
        await store.loadIfNeeded()
        store.upsert(DataSource(id: "sensor", displayName: "Sensor", transport: .bluetooth))
        #expect(store.append(Reading(
            sourceID: "sensor",
            kind: .heartRate,
            value: 70,
            start: Date(timeIntervalSinceNow: -1)
        )))

        store.injectDatabaseFailureOnNextCommitForTesting()
        #expect(store.deleteAllReadings() == false)
        #expect(store.readingCount == 1)
        #expect(store.source(id: "sensor")?.observedMetrics == [.heartRate])
    }

    @Test("A pending migration is retried after relaunch instead of adopting an empty database")
    func pendingMigrationSurvivesRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ReadingArchive(directory: directory)
        let source = DataSource(id: "pending-source", displayName: "Pending", transport: .bluetooth)
        let reading = Reading(
            id: UUID(stableFrom: "pending-reading"),
            sourceID: source.id,
            kind: .heartRate,
            value: 65,
            start: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(await archive.write([source], to: ReadingArchive.File.sources))
        #expect(await archive.write([reading], to: ReadingArchive.File.readings))
        let databaseURL = directory.appendingPathComponent("health.sqlite3")

        // Opening creates the database and its durable pending marker. Simulate process
        // termination before the legacy archives can be read.
        _ = HealthStore(persistenceEnabled: true, databaseURL: databaseURL, archive: archive)

        let relaunched = HealthStore(
            persistenceEnabled: true,
            databaseURL: databaseURL,
            archive: archive
        )
        await relaunched.loadIfNeeded()
        #expect(relaunched.loadState == .loaded)
        #expect(relaunched.sources.map(\.id) == [source.id])
        #expect(relaunched.readings == [reading])
    }
}

@Suite("Pairwise uncertainty")
struct PairwiseUncertaintyTests {
    private let boundary = Date(timeIntervalSince1970: 1_700_000_100)

    @Test("Strong evidence exposes confidence intervals while sparse evidence does not")
    func evidenceGradeAndConfidence() throws {
        var readings: [Reading] = []
        for index in 0..<30 {
            let timestamp = boundary.addingTimeInterval(Double(index) * 125)
            readings.append(Reading(
                sourceID: "a",
                kind: .heartRate,
                value: 70 + Double(index % 3),
                start: timestamp
            ))
            readings.append(Reading(
                sourceID: "b",
                kind: .heartRate,
                value: 72 + Double(index % 2),
                start: timestamp
            ))
        }
        let range = DateInterval(
            start: boundary.addingTimeInterval(-1),
            end: boundary.addingTimeInterval(4_000)
        )
        let strong = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: .heartRate,
            sourceA: "a",
            sourceB: "b",
            range: range
        )
        let statistics = try #require(strong.statistics)
        #expect(strong.evidence.grade == .strong)
        #expect(statistics.meanBiasConfidenceInterval != nil)
        #expect(statistics.lowerLimitConfidenceInterval != nil)
        #expect(statistics.upperLimitConfidenceInterval != nil)

        let sparse = ComparisonEngine.pairwiseAnalysis(
            from: Array(readings.prefix(8)),
            kind: .heartRate,
            sourceA: "a",
            sourceB: "b",
            range: range
        )
        #expect(sparse.evidence.grade == .limited)
        #expect(sparse.statistics == nil)
    }
}

@Suite("Revisable derived estimates")
@MainActor
struct RevisableEstimateTests {
    @Test("A stable estimate updates, an identical recomputation is silent, and disable removes it")
    func upsertAndReconcile() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(
            id: "source",
            displayName: "Source",
            transport: .bluetooth
        ))
        let id = UUID(stableFrom: "derived.vo2.source.today")
        let first = Reading(
            id: id,
            sourceID: "source",
            kind: .vo2Max,
            value: 40,
            start: Date(timeIntervalSinceNow: -60),
            provenance: .estimated
        )
        var revised = first
        revised.value = 42

        #expect(store.upsert(contentsOf: [first]) == [first])
        #expect(store.upsert(contentsOf: [revised]) == [revised])
        #expect(store.readings.count == 1)
        #expect(store.readings.first?.value == 42)
        #expect(store.upsert(contentsOf: [revised]).isEmpty)
        #expect(store.reconcileEstimates(kinds: [.vo2Max], keeping: []) == 1)
        #expect(store.readings.isEmpty)
    }

    @Test("An expired cuff calibration makes blood-pressure estimation ineligible")
    func expiredCalibration() {
        let expired = UserProfile.BPCalibration(
            systolic: 120,
            diastolic: 80,
            referenceRestingHR: 60,
            referenceRMSSD: 40,
            takenAt: Date(timeIntervalSinceNow: -UserProfile.BPCalibration.validity - 1)
        )
        #expect(expired.isExpired)
    }
}
