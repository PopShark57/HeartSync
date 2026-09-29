import Foundation
import Testing
@testable import HeartSyncChecker

/// The orchestration in `AppModel`: startup order, retention, derived metrics, refresh.
///
/// Every test builds the model over temporary files and `TransportActions.inert` (or a
/// recording copy of it), so nothing here starts Bluetooth, HealthKit, or the network.

private let day: TimeInterval = 86_400

/// Temporary database and settings archive for one test, removed afterwards.
@MainActor
private final class Environment {
    let folder: URL
    let archiveName: String
    let databaseURL: URL

    init() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeartSync", isDirectory: true)
        let name = "appmodel-tests-\(UUID().uuidString)"
        folder = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        archiveName = "\(name)/settings.json"
        databaseURL = folder.appendingPathComponent("health.sqlite3")
    }

    var settingsFile: URL { folder.appendingPathComponent("settings.json") }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: settingsFile.path)
        try? FileManager.default.removeItem(at: folder)
    }

    func writeSettings(retentionDays: Int) throws {
        var snapshot = SettingsSnapshot()
        snapshot.retentionDays = retentionDays
        try JSONEncoder().encode(snapshot).write(to: settingsFile)
    }

    /// A model the way a launch builds it: real store and settings over these files.
    func makeModel(transports: AppModel.TransportActions = .inert) -> AppModel {
        AppModel(
            store: HealthStore(
                persistenceEnabled: true,
                databaseURL: databaseURL,
                archive: ReadingArchive(directory: folder)
            ),
            settings: AppSettings(archiveName: archiveName),
            sessions: ComparisonSessionStore(persistenceEnabled: false),
            transports: transports
        )
    }

    /// First launch: retention is 365 days, and readings 60 and 200 days old are stored.
    func seedYearOfHistory() async throws {
        try writeSettings(retentionDays: 365)
        let model = makeModel()
        await model.start()
        #expect(model.startupState == .ready)
        model.store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        let now = Date.now
        model.store.append(contentsOf: [
            Reading(id: Self.recent, sourceID: "strap", kind: .heartRate, value: 60, start: now.addingTimeInterval(-60 * day)),
            Reading(id: Self.old, sourceID: "strap", kind: .heartRate, value: 61, start: now.addingTimeInterval(-200 * day)),
        ])
        #expect(model.store.readings.count == 2)
    }

    static let recent = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let old = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
}

@Suite("AppModel startup and retention")
@MainActor
struct AppModelRetentionTests {

    @Test("A saved 365-day retention is applied before anything older than 30 days can be pruned")
    func savedRetentionSurvivesRelaunch() async throws {
        let environment = try Environment()
        defer { environment.cleanup() }
        try await environment.seedYearOfHistory()

        let relaunched = environment.makeModel()
        await relaunched.start()

        let ids = Set(relaunched.store.readings.map(\.id))
        #expect(ids == [Environment.recent, Environment.old])
        #expect(relaunched.store.retention == 365 * day)
        #expect(relaunched.store.retentionIsConfirmed)
        #expect(!relaunched.retentionIsPaused)
    }

    @Test("Settings that cannot be read delete nothing")
    func unreadableSettingsDeleteNothing() async throws {
        let environment = try Environment()
        defer { environment.cleanup() }
        try await environment.seedYearOfHistory()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: environment.settingsFile.path)

        let relaunched = environment.makeModel()
        await relaunched.start()
        await relaunched.enterBackground()   // the pass that used to prune with the default

        #expect(relaunched.settings.loadState == .failed)
        #expect(Set(relaunched.store.readings.map(\.id)) == [Environment.recent, Environment.old])
        #expect(relaunched.retentionIsPaused)
    }

    @Test("Corrupt settings delete nothing, and the old file is kept aside")
    func corruptSettingsDeleteNothing() async throws {
        let environment = try Environment()
        defer { environment.cleanup() }
        try await environment.seedYearOfHistory()
        try Data("{ this is not settings".utf8).write(to: environment.settingsFile)

        let relaunched = environment.makeModel()
        await relaunched.start()
        await relaunched.enterBackground()

        #expect(relaunched.settings.recoveredCorruptArchive)
        #expect(relaunched.settings.snapshot.retentionDays == 30)
        #expect(Set(relaunched.store.readings.map(\.id)) == [Environment.recent, Environment.old])
        #expect(relaunched.retentionIsPaused)
        #expect(relaunched.startupNotice?.contains("paused") == true)
    }

    @Test("Settings from a newer schema delete nothing")
    func newerSchemaSettingsDeleteNothing() async throws {
        let environment = try Environment()
        defer { environment.cleanup() }
        try await environment.seedYearOfHistory()
        try Data(#"{"schemaVersion":999,"payload":{"retentionDays":7}}"#.utf8).write(to: environment.settingsFile)

        let relaunched = environment.makeModel()
        await relaunched.start()
        await relaunched.enterBackground()

        #expect(relaunched.settings.recoveredCorruptArchive)
        #expect(Set(relaunched.store.readings.map(\.id)) == [Environment.recent, Environment.old])
    }

    @Test("A settings file lost and recreated with the default cannot shorten a longer period on record")
    func recreatedDefaultCannotShortenRetention() async throws {
        let environment = try Environment()
        defer { environment.cleanup() }
        try await environment.seedYearOfHistory()

        // The next launch resets settings; the launch after that finds no file at all, so
        // it reads the 30-day default with nothing marking it untrustworthy.
        try FileManager.default.removeItem(at: environment.settingsFile)
        let afterLoss = environment.makeModel()
        await afterLoss.start()
        await afterLoss.enterBackground()

        #expect(afterLoss.settings.snapshot.retentionDays == 30)
        #expect(afterLoss.store.retentionHeldBackDays == 365)
        #expect(afterLoss.retentionIsPaused)
        #expect(Set(afterLoss.store.readings.map(\.id)) == [Environment.recent, Environment.old])
    }

    @Test("Only the user's own choice lifts the hold, and it then deletes what is older")
    func choosingRetentionLiftsTheHold() async throws {
        let environment = try Environment()
        defer { environment.cleanup() }
        try await environment.seedYearOfHistory()
        try Data("{ not settings".utf8).write(to: environment.settingsFile)

        let model = environment.makeModel()
        await model.start()
        #expect(model.retentionIsPaused)

        #expect(model.chooseRetention(days: 90))
        model.store.prune()

        #expect(!model.retentionIsPaused)
        #expect(Set(model.store.readings.map(\.id)) == [Environment.recent])
    }

    @Test("A refresh while start() is still loading does nothing")
    func refreshWaitsForStartup() async throws {
        var refreshedTransports = 0
        var transports = AppModel.TransportActions.inert
        transports.reconnectBluetooth = { refreshedTransports += 1 }
        let model = AppModel(
            store: HealthStore(persistenceEnabled: false),
            settings: AppSettings(persistenceEnabled: false),
            sessions: ComparisonSessionStore(persistenceEnabled: false),
            transports: transports
        )

        // Not started: a refresh starts the model and returns without touching transports.
        await model.refresh()
        #expect(model.startupState == .ready)
        #expect(refreshedTransports == 0)

        await model.refresh()
        #expect(refreshedTransports == 1)
    }
}

@Suite("AppModel derived metrics")
@MainActor
struct AppModelDerivedMetricTests {

    private func makeModel() -> AppModel {
        AppModel(
            store: HealthStore(persistenceEnabled: false),
            settings: AppSettings(persistenceEnabled: false),
            sessions: ComparisonSessionStore(persistenceEnabled: false),
            transports: .inert
        )
    }

    private func ringBloodPressure(at date: Date, systolic: Double = 118, id: String) -> [Reading] {
        [
            Reading(id: UUID(stableFrom: "ring.sys.\(id)"), sourceID: "ring", kind: .bloodPressureSystolic,
                    value: systolic, start: date, provenance: .estimated),
            Reading(id: UUID(stableFrom: "ring.dia.\(id)"), sourceID: "ring", kind: .bloodPressureDiastolic,
                    value: 76, start: date, provenance: .estimated),
        ]
    }

    @Test("A ring's blood pressure survives reconciliation with the trend index off")
    func ringBloodPressureSurvivesIndexOff() {
        let model = makeModel()
        model.store.upsert(DataSource(id: "ring", displayName: "Ring", transport: .bluetooth))
        let stale = ringBloodPressure(at: Date.now.addingTimeInterval(-3 * day), id: "old")
        let live = ringBloodPressure(at: Date.now.addingTimeInterval(-120), id: "live")
        model.store.append(contentsOf: stale + live)

        model.recomputeDerivedMetrics()

        let kept = Set(model.store.readings(kind: .bloodPressureSystolic, enabledOnly: false).map(\.id))
        #expect(kept == Set([stale[0].id, live[0].id]))
        #expect(model.store.readings(kind: .bloodPressureDiastolic, enabledOnly: false).count == 2)
    }

    @Test("HeartSync's own stale estimates are still removed when the index is off")
    func ownEstimatesAreStillReconciled() {
        let model = makeModel()
        model.ensureEstimateSourceExists()
        let ours = Reading(
            sourceID: AppModel.estimateSourceID, kind: .bloodPressureSystolic, value: 121,
            start: .now.addingTimeInterval(-600), provenance: .estimated,
            metadata: ReadingMetadata(modelledBy: ReadingMetadata.heartSyncModel)
        )
        model.store.append(ours)

        model.recomputeDerivedMetrics()

        #expect(model.store.readings(kind: .bloodPressureSystolic, enabledOnly: false).isEmpty)
    }

    @Test("A ring's recent blood pressure survives with the trend index on and calibrated")
    func ringBloodPressureSurvivesIndexOn() {
        let model = makeModel()
        model.settings.snapshot.bloodPressureIndexEnabled = true
        model.settings.profile.bpCalibration = UserProfile.BPCalibration(
            systolic: 120, diastolic: 80, referenceRestingHR: 60, referenceRMSSD: 40, takenAt: .now
        )
        model.store.upsert(DataSource(id: "ring", displayName: "Ring", transport: .bluetooth))
        model.store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        model.store.append(Reading(sourceID: "strap", kind: .heartRate, value: 64, start: .now.addingTimeInterval(-60)))
        let live = ringBloodPressure(at: Date.now.addingTimeInterval(-200), id: "live")
        model.store.append(contentsOf: live)
        #expect(model.settings.canEstimateBloodPressure)

        model.recomputeDerivedMetrics()

        let systolic = model.store.readings(kind: .bloodPressureSystolic, enabledOnly: false)
        #expect(systolic.contains { $0.id == live[0].id })
        #expect(systolic.contains { $0.sourceID == AppModel.estimateSourceID })
        // The estimate's own source was written in the same transaction as its readings.
        #expect(model.store.source(id: AppModel.estimateSourceID) != nil)
    }

    @Test("Estimates are marked as HeartSync's own")
    func estimatesCarryTheirMarker() {
        let model = makeModel()
        model.settings.snapshot.vo2MaxEstimateEnabled = true
        model.settings.profile.birthDate = Calendar.current.date(byAdding: .year, value: -40, to: .now)
        model.store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        model.store.append(Reading(
            sourceID: "strap", kind: .restingHeartRate, value: 55, start: .now.addingTimeInterval(-3_600)
        ))

        model.recomputeDerivedMetrics()

        let estimate = model.store.readings(kind: .vo2Max, enabledOnly: false).first
        #expect(estimate?.provenance == .estimated)
        #expect(estimate?.metadata?.modelledBy == ReadingMetadata.heartSyncModel)
    }
}

@Suite("AppModel refresh and Oura rate limits")
@MainActor
struct AppModelRefreshTests {

    private func makeModel(transports: AppModel.TransportActions) -> AppModel {
        let settings = AppSettings(persistenceEnabled: false)
        settings.snapshot.autoSyncOura = true
        settings.snapshot.ouraSyncInterval = 900
        return AppModel(
            store: HealthStore(persistenceEnabled: false),
            settings: settings,
            sessions: ComparisonSessionStore(persistenceEnabled: false),
            transports: transports
        )
    }

    @Test("A foreground refresh asks Oura as an unattended sync with the scheduled minimum interval")
    func foregroundOuraSyncIsThrottled() async {
        var calls: [(userInitiated: Bool, minimumInterval: TimeInterval)] = []
        var transports = AppModel.TransportActions.inert
        transports.hasOuraAuthorization = { true }
        transports.syncOura = { userInitiated, minimum in calls.append((userInitiated, minimum)) }
        let model = makeModel(transports: transports)
        await model.start()

        await model.refresh()
        await model.refresh(userInitiated: true)

        #expect(calls.count == 2)
        #expect(calls[0].userInitiated == false)
        #expect(calls[0].minimumInterval == 900)
        #expect(calls[1].userInitiated)
    }

    @Test("The minimum interval never drops under the five-minute floor")
    func minimumIntervalHasAFloor() {
        var snapshot = SettingsSnapshot()
        snapshot.ouraSyncInterval = 30
        #expect(AppModel.minimumForegroundOuraInterval(snapshot) == 300)
    }

    @Test("A watch refresh pulls Health and never touches Bluetooth, Oura, or estimates")
    func watchRefreshIsLight() async {
        var healthSyncs = 0
        var bluetoothReconnects = 0
        var ouraSyncs = 0
        var transports = AppModel.TransportActions.inert
        transports.isHealthKitAuthorized = { true }
        transports.syncHealthKit = { healthSyncs += 1 }
        transports.reconnectBluetooth = { bluetoothReconnects += 1 }
        transports.hasOuraAuthorization = { true }
        transports.syncOura = { _, _ in ouraSyncs += 1 }
        let model = makeModel(transports: transports)
        await model.start()
        let syncsAfterStart = healthSyncs

        await model.refreshForWatch()

        #expect(healthSyncs == syncsAfterStart + 1)
        #expect(bluetoothReconnects == 0)
        #expect(ouraSyncs == 0)
    }
}

@Suite("AppModel source removal")
@MainActor
struct AppModelRemovalTests {

    @Test("A failed database write leaves the source in place and reports it")
    func failedRemovalReportsAndKeepsTheSource() async throws {
        let environment = try Environment()
        defer { environment.cleanup() }
        try environment.writeSettings(retentionDays: 30)
        let model = environment.makeModel()
        await model.start()
        let strap = model.store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        model.store.append(Reading(sourceID: "strap", kind: .heartRate, value: 60, start: .now.addingTimeInterval(-60)))

        model.store.injectDatabaseFailureOnNextCommitForTesting()
        let result = model.removeSource(strap)

        #expect(result.isFailure)
        #expect(model.store.source(id: "strap") != nil)
        #expect(model.store.readings.count == 1)

        // The next attempt is not affected by the earlier injected failure.
        #expect(model.removeSource(strap) == .applied)
        #expect(model.store.source(id: "strap") == nil)
        #expect(model.store.readings.isEmpty)
    }
}
