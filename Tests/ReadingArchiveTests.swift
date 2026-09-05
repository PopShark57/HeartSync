import Foundation
import Testing
@testable import HeartSyncChecker

/// Archive behaviour that user history depends on.
///
/// Two of these are load-bearing beyond the file itself. An undecodable archive must be
/// preserved beside itself rather than deleted, and `.missing` must never be confused with
/// `.unreadable` — the second is what turned a locked-device launch into an empty store that
/// then overwrote a good archive.
///
/// **Seam.** `ReadingArchive` resolves its own Application Support directory and offers no
/// way to point it somewhere else, so these tests use the only seam it does have: the file
/// *name*. Every name is prefixed with a folder created for the individual test and removed
/// afterwards, so nothing here can read, write, or move `readings.json`, `sources.json`,
/// `settings.json`, or the Oura cache. If an injectable directory is ever added, delete the
/// prefixing and keep the assertions.
@Suite("Reading archive")
final class ReadingArchiveTests: Sendable {

    private let archive = ReadingArchive()
    /// This test's private sub-folder of the archive directory.
    private let folder: String
    private let directory: URL

    /// 2023-11-14T22:13:20Z, the instant every fixture in this file is anchored to.
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let epochISO = "2023-11-14T22:13:20Z"

    init() throws {
        // Mirrors ReadingArchive's own resolution. It is private, and duplicating it here is
        // the price of there being no injectable directory.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeartSync", isDirectory: true)
        folder = "archive-tests-\(UUID().uuidString)"
        directory = base.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        // A test may have left a file unreadable on purpose; make it removable again first.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for item in contents {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: directory.appendingPathComponent(item).path
            )
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures and helpers

    /// The name to hand the archive, scoped to this test's folder.
    private func name(_ file: String) -> String { "\(folder)/\(file)" }

    /// Where that name lands on disk.
    private func url(_ file: String) -> URL { directory.appendingPathComponent(file) }

    private func backupURL(_ file: String) -> URL {
        let original = url(file)
        let prefix = original.lastPathComponent + ".corrupt-"
        let matches = (try? FileManager.default.contentsOfDirectory(
            at: original.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        } ?? []
        return matches.last ?? original.appendingPathExtension("corrupt-unavailable")
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// An encoder configured exactly like the archive's, for hand-writing legacy and
    /// future-schema files the archive itself cannot produce.
    private var rawEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func reading(_ sourceID: String, _ value: Double, offset: TimeInterval = 0) -> Reading {
        Reading(
            id: UUID(stableFrom: "\(sourceID)-\(value)-\(offset)"),
            sourceID: sourceID,
            kind: .heartRate,
            value: value,
            start: epoch.addingTimeInterval(offset),
            end: epoch.addingTimeInterval(offset + 5)
        )
    }

    private var sampleReadings: [Reading] {
        [reading("chest", 62), reading("watch", 64, offset: 30)]
    }

    private func writeRaw(_ text: String, to file: String) throws {
        try Data(text.utf8).write(to: url(file))
    }

    private func rawText(_ file: String) throws -> String {
        String(decoding: try Data(contentsOf: url(file)), as: UTF8.self)
    }

    // MARK: - Round trips

    @Test("Readings survive a round trip with their instants unchanged")
    func readingsRoundTrip() async throws {
        let written = sampleReadings
        await archive.write(written, to: name("readings.json"))
        let read = try #require(await archive.readOutcome([Reading].self, from: name("readings.json")).value)

        #expect(read == written)
        #expect(read[0].start == epoch)
        #expect(read[0].end == epoch.addingTimeInterval(5))
        #expect(read[1].start == epoch.addingTimeInterval(30))
    }

    @Test("Instants are archived as ISO-8601 text, not as a floating-point offset")
    func datesAreISO8601OnDisk() async throws {
        // Every shipped archive holds date *strings*. Dropping the ISO-8601 strategy would
        // still round-trip in a test that only writes and reads, while making every existing
        // user file undecodable — so assert the representation, not just the round trip.
        await archive.write([reading("chest", 62)], to: name("readings.json"))
        let text = try rawText("readings.json")

        #expect(text.contains("\"start\":\"\(epochISO)\""))
        #expect(!text.contains("\"start\":716509"))   // timeIntervalSinceReferenceDate
    }

    @Test("A source keeps every field it was written with, including the optional ones")
    func sourcesRoundTrip() async throws {
        let written = [
            DataSource(
                id: "chest",
                displayName: "Polar H10",
                transport: .bluetooth,
                model: "H10",
                colorIndex: 3,
                isEnabled: true,
                addedAt: epoch,
                lastSeenAt: epoch.addingTimeInterval(600),
                observedMetrics: [.heartRate, .hrvRMSSD],
                batteryPercent: 88,
                bodyLocation: .chest
            ),
            DataSource(
                id: "watch",
                displayName: "Apple Watch",
                transport: .healthKit,
                addedAt: epoch,
                observedMetrics: []
            ),
        ]
        await archive.write(written, to: name("sources.json"))
        let read = try #require(await archive.readOutcome([DataSource].self, from: name("sources.json")).value)

        #expect(read == written)
        #expect(read[0].bodyLocation == .chest)
        #expect(read[0].observedMetrics == [.heartRate, .hrvRMSSD])
        #expect(read[1].bodyLocation == nil)
        #expect(read[1].batteryPercent == nil)
        #expect(read[1].lastSeenAt == nil)
    }

    @Test("Settings survive a round trip, calibration included")
    func settingsRoundTrip() async throws {
        var written = SettingsSnapshot()
        written.retentionDays = 90
        written.mirrorBluetoothToHealthKit = true
        written.discrepancyThreshold = .major
        written.ouraSyncInterval = 1_800
        written.profile.birthDate = epoch.addingTimeInterval(-86_400 * 365 * 30)
        written.profile.bpCalibration = .init(
            systolic: 118, diastolic: 76,
            referenceRestingHR: 58, referenceRMSSD: 42,
            takenAt: epoch
        )

        await archive.write(written, to: name("settings.json"))
        let read = try #require(await archive.readOutcome(SettingsSnapshot.self, from: name("settings.json")).value)

        #expect(read == written)
        #expect(read.profile.bpCalibration?.takenAt == epoch)
        #expect(read.discrepancyThreshold == .major)
    }

    @Test("The Oura snapshot survives a round trip with its sync marks and truncation flags")
    func ouraSnapshotRoundTrip() async throws {
        var written = OuraSnapshot()
        written.fetchedAt = epoch
        written.heartRates = [
            OuraClient.HeartRatePoint(bpm: 62, source: "rest", timestamp: "2026-08-29T10:00:00+00:00")
        ]
        written.collectionSyncMarks = ["heartrate": epoch.addingTimeInterval(-3_600)]
        written.lastFullBackfillAt = epoch.addingTimeInterval(-86_400)
        written.truncatedCollections = ["heartrate"]

        await archive.write(written, to: name("oura.json"))
        let read = try #require(await archive.readOutcome(OuraSnapshot.self, from: name("oura.json")).value)

        #expect(read == written)
        // The sync marks are what stop the next sync re-downloading the whole window; losing
        // them in serialization would be invisible except as traffic.
        #expect(read.collectionSyncMarks["heartrate"] == epoch.addingTimeInterval(-3_600))
        #expect(read.truncatedCollections == ["heartrate"])
        #expect(read.fetchedAt == epoch)
    }

    @Test("An archive that holds nothing is a value, not a missing file")
    func emptyCollectionIsAValue() async throws {
        await archive.write([Reading](), to: name("readings.json"))
        let outcome = await archive.readOutcome([Reading].self, from: name("readings.json"))

        // "The user deleted their history" and "there is no archive" are different facts and
        // must not collapse into one another.
        guard case .value(let readings) = outcome else {
            Issue.record("An empty archive must decode as a value, got \(outcome)")
            return
        }
        #expect(readings.isEmpty)
    }

    // MARK: - The envelope

    @Test("What lands on disk is a versioned envelope around the payload")
    func writesTheVersionedEnvelope() async throws {
        await archive.write(sampleReadings, to: name("readings.json"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url("readings.json")))
        let envelope = try #require(object as? [String: Any])

        #expect(envelope["schemaVersion"] as? Int == ReadingArchive.schemaVersion)
        #expect((envelope["payload"] as? [Any])?.count == 2)
    }

    @Test("A legacy bare payload written before the envelope existed still decodes")
    func readsLegacyBarePayload() async throws {
        // Byte-for-byte what the shipping build wrote: the payload alone, no wrapper. Every
        // archive already on a user's phone looks like this.
        let legacy = try rawEncoder.encode(sampleReadings)
        try legacy.write(to: url("readings.json"))

        let outcome = await archive.readOutcome([Reading].self, from: name("readings.json"))

        #expect(outcome.value == sampleReadings)
        #expect(outcome.isConclusive)
        // A legacy file is not a broken one: nothing may be moved aside.
        #expect(!exists(backupURL("readings.json")))
        #expect(exists(url("readings.json")))
    }

    @Test("A legacy file is upgraded to the envelope the next time it is written")
    func upgradesLegacyOnWrite() async throws {
        try rawEncoder.encode(sampleReadings).write(to: url("readings.json"))
        let loaded = try #require(await archive.readOutcome([Reading].self, from: name("readings.json")).value)

        await archive.write(loaded, to: name("readings.json"))

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url("readings.json")))
        let envelope = try #require(object as? [String: Any])
        #expect(envelope["schemaVersion"] as? Int == ReadingArchive.schemaVersion)
        // The upgrade must be a re-wrap, not a re-interpretation.
        #expect(await archive.readOutcome([Reading].self, from: name("readings.json")).value == sampleReadings)
    }

    @Test("A payload carrying its own schema version is not mistaken for a future archive")
    func payloadOwnSchemaVersionIsNotTheArchiveVersion() async throws {
        // `OuraSnapshot` has a `schemaVersion` field of its own. Written bare by an older
        // build, it looks exactly like an archive envelope stamped with that number — and if
        // the version check ran before the bare decode, a snapshot at its own version 99
        // would be moved aside as "from the future" and the cache silently thrown away.
        var snapshot = OuraSnapshot()
        snapshot.schemaVersion = 99
        snapshot.fetchedAt = epoch
        snapshot.heartRates = [
            OuraClient.HeartRatePoint(bpm: 62, source: "rest", timestamp: "2026-08-29T10:00:00+00:00")
        ]
        try rawEncoder.encode(snapshot).write(to: url("oura.json"))

        let outcome = await archive.readOutcome(OuraSnapshot.self, from: name("oura.json"))
        let read = try #require(outcome.value)

        #expect(read == snapshot)
        #expect(read.schemaVersion == 99)
        #expect(read.heartRates.count == 1)
        #expect(!exists(backupURL("oura.json")))
    }

    @Test("An Oura cache written before incremental-sync metadata still decodes")
    func legacyOuraSnapshotDefaultsNewMetadata() async throws {
        var snapshot = OuraSnapshot()
        snapshot.fetchedAt = epoch
        snapshot.heartRates = [
            OuraClient.HeartRatePoint(bpm: 62, source: "rest", timestamp: "2026-08-29T10:00:00+00:00")
        ]

        var object = try #require(
            JSONSerialization.jsonObject(with: rawEncoder.encode(snapshot)) as? [String: Any]
        )
        // These keys did not exist before the incremental-sync work. Declaration-time
        // defaults do not help synthesised Decodable when a non-optional key is absent.
        object.removeValue(forKey: "collectionSyncMarks")
        object.removeValue(forKey: "truncatedCollections")
        try JSONSerialization.data(withJSONObject: object).write(to: url("oura.json"))

        let outcome = await archive.readOutcome(OuraSnapshot.self, from: name("oura.json"))
        let loaded = try #require(outcome.value)

        #expect(loaded.heartRates == snapshot.heartRates)
        #expect(loaded.collectionSyncMarks.isEmpty)
        #expect(loaded.truncatedCollections.isEmpty)
        #expect(!exists(backupURL("oura.json")))
    }

    @Test("An archive from a newer build is preserved rather than parsed or destroyed")
    func futureSchemaIsPreserved() async throws {
        let payload = String(decoding: try rawEncoder.encode(sampleReadings), as: UTF8.self)
        let future = "{\"schemaVersion\":99,\"payload\":\(payload)}"
        try writeRaw(future, to: "readings.json")

        let outcome = await archive.readOutcome([Reading].self, from: name("readings.json"))

        // Guessing at a payload this build does not understand would be worse than refusing.
        #expect(outcome.value == nil)
        guard case .corrupt(let reason) = outcome else {
            Issue.record("A newer schema must be reported as corrupt, got \(outcome)")
            return
        }
        #expect(reason.contains("99"))
        // Downgrading a build must not cost the user their history.
        #expect(exists(backupURL("readings.json")))
        #expect(String(decoding: try Data(contentsOf: backupURL("readings.json")), as: UTF8.self) == future)
    }

    // MARK: - The four outcomes

    @Test("A file that was never written is missing, and reading it creates nothing")
    func missingIsNotCorrupt() async throws {
        let outcome = await archive.readOutcome([Reading].self, from: name("readings.json"))

        guard case .missing = outcome else {
            Issue.record("A first launch must report .missing, got \(outcome)")
            return
        }
        // A first launch is conclusive — the store may start empty and save over the absent
        // file — but it is emphatically not a corrupt archive, and nothing may be moved.
        #expect(outcome.isConclusive)
        #expect(outcome.value == nil)
        #expect(!exists(url("readings.json")))
        #expect(!exists(backupURL("readings.json")))
    }

    @Test("An undecodable archive is preserved beside itself, byte for byte")
    func corruptFileIsPreservedNotDeleted() async throws {
        // The invariant AGENTS.md singles out: a decode failure is far more likely to be an
        // app bug than worthless data, so the bytes must survive it.
        let garbage = "{\"readings\": [ this is not JSON"
        try writeRaw(garbage, to: "readings.json")

        let outcome = await archive.readOutcome([Reading].self, from: name("readings.json"))

        guard case .corrupt = outcome else {
            Issue.record("Undecodable bytes must be reported as corrupt, got \(outcome)")
            return
        }
        #expect(outcome.isConclusive)
        #expect(exists(backupURL("readings.json")))
        #expect(String(decoding: try Data(contentsOf: backupURL("readings.json")), as: UTF8.self) == garbage)
        // Moved aside, not copied aside and not left in place to fail again forever.
        #expect(!exists(url("readings.json")))
    }

    @Test("Setting a corrupt archive aside still leaves the app able to write a fresh one")
    func writesAfterCorruption() async throws {
        try writeRaw("not json at all", to: "readings.json")
        _ = await archive.readOutcome([Reading].self, from: name("readings.json"))

        await archive.write(sampleReadings, to: name("readings.json"))

        // `.corrupt` is deliberately conclusive: the recovery copy is already safe, so the
        // app starts over rather than being locked out of persistence for good.
        #expect(await archive.readOutcome([Reading].self, from: name("readings.json")).value == sampleReadings)
        #expect(exists(backupURL("readings.json")))
    }

    @Test("Repeated corruptions create distinct timestamped recovery files")
    func repeatedCorruptionsDoNotOverwriteRecovery() async throws {
        try writeRaw("first broken generation", to: "readings.json")
        _ = await archive.readOutcome([Reading].self, from: name("readings.json"))
        try writeRaw("second broken generation", to: "readings.json")
        _ = await archive.readOutcome([Reading].self, from: name("readings.json"))

        let prefix = "readings.json.corrupt-"
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
        #expect(backups.count == 2)
        let payloads = try Set(backups.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) })
        #expect(payloads == ["first broken generation", "second broken generation"])
    }

    @Test("A file that cannot be opened is left exactly where it is")
    func unreadableFileIsUntouched() async throws {
        // Stands in for the case this outcome exists for: a background relaunch before the
        // device's first unlock, where the archive is intact and its bytes are unavailable.
        let original = try rawEncoder.encode(sampleReadings)
        try original.write(to: url("readings.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url("readings.json").path)

        let outcome = await archive.readOutcome([Reading].self, from: name("readings.json"))

        guard case .unreadable = outcome else {
            Issue.record("An unopenable file must report .unreadable, got \(outcome)")
            return
        }
        // Inconclusive: the caller knows nothing about the contents and must not save over
        // them. This is the distinction whose absence destroyed history.
        #expect(!outcome.isConclusive)
        #expect(outcome.value == nil)
        // Untouched: still at its own path, no backup, and the bytes intact once readable.
        #expect(exists(url("readings.json")))
        #expect(!exists(backupURL("readings.json")))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url("readings.json").path)
        #expect(try Data(contentsOf: url("readings.json")) == original)
    }

    @Test("Only an unreadable archive leaves the caller without an answer")
    func onlyUnreadableIsInconclusive() async throws {
        // The four outcomes gathered from four real reads, so the classification cannot be
        // quietly regrouped.
        let missing = await archive.readOutcome([Reading].self, from: name("absent.json"))

        await archive.write(sampleReadings, to: name("good.json"))
        let value = await archive.readOutcome([Reading].self, from: name("good.json"))

        try writeRaw("<not json>", to: "broken.json")
        let corrupt = await archive.readOutcome([Reading].self, from: name("broken.json"))

        try rawEncoder.encode(sampleReadings).write(to: url("locked.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url("locked.json").path)
        let unreadable = await archive.readOutcome([Reading].self, from: name("locked.json"))

        #expect(missing.isConclusive)
        #expect(value.isConclusive)
        #expect(corrupt.isConclusive)
        #expect(!unreadable.isConclusive)
    }

    @Test("The Optional convenience cannot tell an unreadable archive from an empty one")
    func optionalReadCollapsesUnreadable() async throws {
        try rawEncoder.encode(sampleReadings).write(to: url("locked.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url("locked.json").path)

        // Documented and deliberate — which is exactly why anything owning user history has
        // to call `readOutcome`. If this ever stops being lossy, the warning can go.
        #expect(await archive.read([Reading].self, from: name("locked.json")) == nil)
        #expect(await archive.read([Reading].self, from: name("absent.json")) == nil)

        let outcome = await archive.readOutcome([Reading].self, from: name("locked.json"))
        #expect(!outcome.isConclusive)
    }

    // MARK: - Deletion

    @Test("Deleting an archive makes the next read report it missing")
    func deleteMakesFileMissing() async throws {
        await archive.write(sampleReadings, to: name("oura.json"))
        #expect(exists(url("oura.json")))

        await archive.delete(name("oura.json"))

        #expect(!exists(url("oura.json")))
        guard case .missing = await archive.readOutcome(OuraSnapshot.self, from: name("oura.json")) else {
            Issue.record("A deleted archive must read back as missing")
            return
        }
        // Deleting what is not there is not an error either.
        await archive.delete(name("never-written.json"))
    }
}
