import Foundation
import Testing
@testable import HeartSyncChecker

/// Apple Watch Blood Oxygen that Health records under the paired iPhone (`HealthKitWatchRelay`).
///
/// The redesigned U.S. feature calculates on the iPhone, so Health writes the sample with the
/// iPhone as its source and the watch as its device. These pin that such a sample lands in the
/// watch's own row when one watch matches, stays under its writer otherwise, and that a writer
/// row stored before the rule moves its raw history once.
@Suite("HealthKit watch measurements relayed by the iPhone")
@MainActor
struct HealthKitWatchRelayTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let phoneBundle = "com.apple.health.11111111-1111-1111-1111-111111111111"
    private let watchBundle = "com.apple.health.22222222-2222-2222-2222-222222222222"
    private var phoneID: String { "hk.\(phoneBundle)" }
    private var watchID: String { "hk.\(watchBundle)" }

    private func spo2Mapping() throws -> HealthKitManager.TypeMapping {
        try #require(HealthKitManager.mappings.first { $0.kind == .spo2 })
    }

    private func heartRateMapping() throws -> HealthKitManager.TypeMapping {
        try #require(HealthKitManager.mappings.first { $0.kind == .heartRate })
    }

    /// A sample the iPhone wrote about a watch measurement, as the redesigned feature does.
    private func relayed(
        rawValue: Double = 0.96,
        hardware: String? = "Watch7,12",
        productType: String? = "iPhone17,2",
        bundle: String? = nil,
        offset: TimeInterval = 0
    ) -> HealthKitManager.SampleDescriptor {
        HealthKitManager.SampleDescriptor(
            id: UUID(),
            sourceBundleIdentifier: bundle ?? phoneBundle,
            sourceName: "Sergey's iPhone",
            deviceModel: "Watch",
            rawValue: rawValue,
            start: epoch.addingTimeInterval(offset),
            end: epoch.addingTimeInterval(offset),
            sourceProductType: productType,
            deviceHardwareVersion: hardware
        )
    }

    /// A sample the watch wrote itself.
    private func watchOwn(rawValue: Double = 64, productType: String = "Watch7,12") -> HealthKitManager.SampleDescriptor {
        HealthKitManager.SampleDescriptor(
            id: UUID(),
            sourceBundleIdentifier: watchBundle,
            sourceName: "Sergey's Apple Watch Ultra 4",
            deviceModel: "Watch",
            rawValue: rawValue,
            start: epoch,
            end: epoch,
            sourceProductType: productType,
            deviceHardwareVersion: productType
        )
    }

    private func watchSource(
        id: String? = nil,
        name: String = "Sergey's Apple Watch Ultra 4",
        productTypes: Set<String>? = nil
    ) -> DataSource {
        var source = DataSource(
            id: id ?? watchID,
            displayName: name,
            transport: .healthKit,
            model: "Watch",
            observedMetrics: [.heartRate, .restingHeartRate],
            observedDeviceModels: ["Watch"],
            identifiesHealthKitWriter: true
        )
        source.writerProductTypes = productTypes
        return source
    }

    /// The iPhone row an earlier build stored from relayed samples: it reports only "Watch".
    private func legacyPhoneSource() -> DataSource {
        DataSource(
            id: phoneID,
            displayName: "Sergey's iPhone",
            transport: .healthKit,
            model: "Watch",
            observedMetrics: [.heartRate, .spo2],
            observedDeviceModels: ["Watch"],
            identifiesHealthKitWriter: true
        )
    }

    // MARK: - Recognising a relayed sample

    @Test("Only Apple's Health on an iPhone writing about a watch device counts as a relay")
    func relayRecognition() {
        #expect(HealthKitWatchRelay.isRelayedWatchMeasurement(
            sourceBundleIdentifier: phoneBundle, sourceProductType: "iPhone17,2",
            deviceModel: "Watch", deviceHardwareVersion: nil
        ))
        #expect(HealthKitWatchRelay.isRelayedWatchMeasurement(
            sourceBundleIdentifier: phoneBundle, sourceProductType: "iPhone17,2",
            deviceModel: nil, deviceHardwareVersion: "Watch7,12"
        ))
        // The watch writing for itself.
        #expect(!HealthKitWatchRelay.isRelayedWatchMeasurement(
            sourceBundleIdentifier: watchBundle, sourceProductType: "Watch7,12",
            deviceModel: "Watch", deviceHardwareVersion: "Watch7,12"
        ))
        // A third-party app on the iPhone that names a watch is its own writer.
        #expect(!HealthKitWatchRelay.isRelayedWatchMeasurement(
            sourceBundleIdentifier: "com.example.oximeter", sourceProductType: "iPhone17,2",
            deviceModel: "Watch", deviceHardwareVersion: nil
        ))
        // An unknown writer product type is never guessed to be an iPhone.
        #expect(!HealthKitWatchRelay.isRelayedWatchMeasurement(
            sourceBundleIdentifier: phoneBundle, sourceProductType: nil,
            deviceModel: "Watch", deviceHardwareVersion: nil
        ))
        // The iPhone's own measurements, or another device it relays, are not the watch's.
        #expect(!HealthKitWatchRelay.isRelayedWatchMeasurement(
            sourceBundleIdentifier: phoneBundle, sourceProductType: "iPhone17,2",
            deviceModel: "iPhone", deviceHardwareVersion: "iPhone17,2"
        ))
    }

    // MARK: - Conversion

    @Test("Relayed Blood Oxygen lands in the watch's row, scaled, with its sample UUID")
    func relayedSpO2FilesUnderWatch() throws {
        let sample = relayed(rawValue: 0.96)
        let converted = HealthKitManager.convert(
            descriptors: [sample],
            mapping: try spo2Mapping(),
            knownSources: [watchSource(), legacyPhoneSource()]
        )
        let reading = try #require(converted.readings.first)
        #expect(reading.id == sample.id)
        #expect(reading.sourceID == watchID)
        #expect(reading.value == 96)
        #expect(reading.provenance == .measured)

        // No iPhone row is created or refreshed for it; the watch gains the metric and keeps
        // its own name and models.
        #expect(converted.sources.map(\.id) == [watchID])
        let watch = try #require(converted.sources.first)
        #expect(watch.displayName == "Sergey's Apple Watch Ultra 4")
        #expect(watch.observedDeviceModels == ["Watch"])
        #expect(watch.observedMetrics.contains(.spo2))
        #expect(watch.lastSeenAt == sample.end)
        #expect(converted.relays == [HealthKitManager.WatchRelay(writerID: phoneID, watchID: watchID)])
    }

    @Test("Without a known watch the sample stays under its writer, as before")
    func noWatchKeepsWriter() throws {
        let converted = HealthKitManager.convert(
            descriptors: [relayed()],
            mapping: try spo2Mapping(),
            knownSources: []
        )
        let reading = try #require(converted.readings.first)
        #expect(reading.sourceID == phoneID)
        #expect(converted.sources.map(\.id) == [phoneID])
        #expect(converted.sources.first?.writerProductTypes == ["iPhone17,2"])
        #expect(converted.relays.isEmpty)
    }

    @Test("Two watches that cannot be told apart are never chosen between")
    func ambiguousWatchesKeepWriter() throws {
        let second = watchSource(id: "hk.com.apple.health.33333333", name: "Old Watch")
        let converted = HealthKitManager.convert(
            descriptors: [relayed(hardware: nil)],
            mapping: try spo2Mapping(),
            knownSources: [watchSource(), second]
        )
        #expect(converted.readings.first?.sourceID == phoneID)
        #expect(converted.relays.isEmpty)
    }

    @Test("The hardware version picks the watch whose product type matches")
    func hardwarePicksWatch() throws {
        let ultra2 = watchSource(id: "hk.com.apple.health.33333333", name: "Old Ultra", productTypes: ["Watch6,18"])
        let ultra4 = watchSource(productTypes: ["Watch7,12"])
        let converted = HealthKitManager.convert(
            descriptors: [relayed(hardware: "Watch7,12")],
            mapping: try spo2Mapping(),
            knownSources: [ultra2, ultra4]
        )
        #expect(converted.readings.first?.sourceID == watchID)
    }

    @Test("A lone watch takes the sample even when its recorded product type differs")
    func loneWatchTakesMismatchedHardware() throws {
        // The hardware string on an iPhone-calculated sample is undocumented; with one watch
        // there is no one else it could belong to.
        let only = watchSource(productTypes: ["Watch7,20"])
        let converted = HealthKitManager.convert(
            descriptors: [relayed(hardware: "Watch7,12")],
            mapping: try spo2Mapping(),
            knownSources: [only]
        )
        #expect(converted.readings.first?.sourceID == watchID)
    }

    @Test("With several watches and no hardware match, the sample stays under its writer")
    func severalWatchesWithoutMatchKeepWriter() throws {
        let first = watchSource(productTypes: ["Watch6,18"])
        let second = watchSource(id: "hk.com.apple.health.33333333", name: "Old Watch", productTypes: ["Watch5,4"])
        let converted = HealthKitManager.convert(
            descriptors: [relayed(hardware: "Watch7,12")],
            mapping: try spo2Mapping(),
            knownSources: [first, second]
        )
        #expect(converted.readings.first?.sourceID == phoneID)
        #expect(converted.relays.isEmpty)
    }

    @Test("A watch first seen on the same page receives the relayed sample and its product type")
    func watchOnSamePage() throws {
        let converted = HealthKitManager.convert(
            descriptors: [relayed(rawValue: 71, hardware: "Watch7,12"), watchOwn()],
            mapping: try heartRateMapping(),
            knownSources: []
        )
        #expect(converted.readings.count == 2)
        #expect(converted.readings.allSatisfy { $0.sourceID == watchID })
        let watch = try #require(converted.sources.first { $0.id == watchID })
        #expect(watch.writerProductTypes == ["Watch7,12"])
        #expect(!converted.sources.contains { $0.id == phoneID })
    }

    @Test("A legacy iPhone row reporting only Watch is never a candidate for its own relays")
    func legacyPhoneRowIsNotItsOwnTarget() throws {
        // The legacy row passes the model fallback, but it is the writer and is excluded.
        let converted = HealthKitManager.convert(
            descriptors: [relayed()],
            mapping: try spo2Mapping(),
            knownSources: [legacyPhoneSource()]
        )
        #expect(converted.readings.first?.sourceID == phoneID)
    }

    @Test("A renamed watch keeps the user's name when a relayed sample updates it")
    func renamedWatchKeepsName() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(watchSource())
        #expect(store.rename(sourceID: watchID, to: "Ultra") == .applied)
        let converted = HealthKitManager.convert(
            descriptors: [relayed()],
            mapping: try spo2Mapping(),
            knownSources: store.sources
        )
        let result = store.upsertBatch(readings: converted.readings, updatingSources: converted.sources)
        #expect(result.committed)
        let watch = try #require(store.source(id: watchID))
        #expect(watch.displayName == "Ultra")
        #expect(watch.observedMetrics.contains(.spo2))
    }

    // MARK: - Moving stored history

    @Test("Only a writer that reported nothing but watches may move its history")
    func historyMoveScope() {
        #expect(HealthKitWatchRelay.mayMoveHistory(of: legacyPhoneSource()))

        var mixed = legacyPhoneSource()
        mixed.observedDeviceModels = ["Watch", "iPhone"]
        #expect(!HealthKitWatchRelay.mayMoveHistory(of: mixed))

        var unknown = legacyPhoneSource()
        unknown.observedDeviceModels = nil
        #expect(!HealthKitWatchRelay.mayMoveHistory(of: unknown))

        #expect(!HealthKitWatchRelay.mayMoveHistory(of: watchSource(productTypes: ["Watch7,12"])))

        var thirdParty = legacyPhoneSource()
        thirdParty.id = "hk.com.example.oximeter"
        #expect(!HealthKitWatchRelay.mayMoveHistory(of: thirdParty))
    }

    private func compactedID(sourceID: String, windowStart: Date) -> UUID {
        UUID(stableFrom: "compact.\(sourceID).\(MetricKind.spo2.rawValue).\(Int(windowStart.timeIntervalSince1970))")
    }

    private func oldWindowStart() -> Date {
        ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-20 * 86_400), size: MetricKind.spo2.comparisonWindow)
    }

    private func compactedMedian(sourceID: String, at windowStart: Date, value: Double = 97) -> Reading {
        Reading(
            id: compactedID(sourceID: sourceID, windowStart: windowStart),
            sourceID: sourceID,
            kind: .spo2,
            value: value,
            start: windowStart,
            metadata: ReadingMetadata(aggregation: AggregationMetadata(
                originalSampleCount: 4,
                originalStandardDeviation: 0.5
            ))
        )
    }

    @Test("Stored history moves to the watch: raw rows keep their ids, medians are re-keyed")
    func storedHistoryMoves() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(legacyPhoneSource())
        store.upsert(watchSource())
        // Whole seconds, so a row rebuilt from its columns encodes exactly as delivered.
        let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
        let raw = (0..<3).map { index in
            Reading(
                id: UUID(),
                sourceID: phoneID,
                kind: .spo2,
                value: 95 + Double(index),
                start: now.addingTimeInterval(Double(-3_600 * (index + 1)))
            )
        }
        let windowStart = oldWindowStart()
        let median = compactedMedian(sourceID: phoneID, at: windowStart)
        #expect(store.append(contentsOf: raw + [median]).count == 4)

        #expect(store.moveReadings(kind: .spo2, from: phoneID, to: watchID))

        let all = store.readings(kind: .spo2, enabledOnly: false)
        #expect(all.count == 4)
        #expect(all.allSatisfy { $0.sourceID == watchID })
        #expect(Set(raw.map(\.id)).isSubset(of: Set(all.map(\.id))))
        #expect(!all.contains { $0.id == median.id })
        #expect(all.contains { $0.id == compactedID(sourceID: watchID, windowStart: windowStart) })

        // The iPhone row no longer lists the metric; the watch does.
        #expect(store.source(id: phoneID)?.observedMetrics == [.heartRate])
        #expect(store.source(id: watchID)?.observedMetrics.contains(.spo2) == true)

        // The re-read delivers the same samples under the watch: nothing changes, and a raw
        // sample behind the moved median cannot come back beside it.
        let redelivered = raw.map { reading -> Reading in
            var copy = reading
            copy.sourceID = watchID
            return copy
        }
        let folded = Reading(id: UUID(), sourceID: watchID, kind: .spo2, value: 96, start: windowStart.addingTimeInterval(1))
        #expect(store.upsertBatch(readings: redelivered + [folded]).acceptedReadings.isEmpty)
        #expect(store.readings(kind: .spo2, enabledOnly: false).count == 4)

        // Idempotent.
        #expect(store.moveReadings(kind: .spo2, from: phoneID, to: watchID))
        #expect(store.readings(kind: .spo2, enabledOnly: false).count == 4)
    }

    @Test("Where the watch already has a median for a window, the iPhone row keeps its own")
    func medianCollisionStays() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(legacyPhoneSource())
        store.upsert(watchSource())
        let windowStart = oldWindowStart()
        let phoneMedian = compactedMedian(sourceID: phoneID, at: windowStart, value: 97)
        let watchMedian = compactedMedian(sourceID: watchID, at: windowStart, value: 95)
        #expect(store.append(contentsOf: [phoneMedian, watchMedian]).count == 2)

        #expect(store.moveReadings(kind: .spo2, from: phoneID, to: watchID))

        let all = store.readings(kind: .spo2, enabledOnly: false)
        #expect(all.count == 2)
        #expect(all.first { $0.sourceID == watchID }?.value == 95)
        #expect(all.first { $0.sourceID == phoneID }?.id == phoneMedian.id)
        #expect(store.source(id: phoneID)?.observedMetrics.contains(.spo2) == true)
    }

    // MARK: - Source metadata

    @Test("Writer product types accumulate across updates and older archives decode without them")
    func productTypesMergeAndDecode() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(watchSource(productTypes: ["Watch6,18"]))
        store.upsert(watchSource(productTypes: ["Watch7,12"]))
        store.upsert(watchSource(productTypes: nil))
        #expect(store.source(id: watchID)?.writerProductTypes == ["Watch6,18", "Watch7,12"])

        let encoder = JSONEncoder()
        var json = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(watchSource(productTypes: ["Watch7,12"]))) as? [String: Any]
        )
        json.removeValue(forKey: "writerProductTypes")
        let decoded = try JSONDecoder().decode(
            DataSource.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.writerProductTypes == nil)
        #expect(decoded.id == watchID)
    }
}
