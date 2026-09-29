import Foundation
import Testing
@testable import HeartSyncChecker

/// Source mutations that report failure, estimate reconciliation scope, maintenance that no
/// longer runs per ingest page, count-only queries, and sub-second payload dates.

private let day: TimeInterval = 86_400

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("store-maintenance-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A store over a real SQLite file that has finished loading.
@MainActor
private func loadedStore(in folder: URL) async -> HealthStore {
    let store = HealthStore(
        persistenceEnabled: true,
        databaseURL: folder.appendingPathComponent("health.sqlite3"),
        archive: ReadingArchive(directory: folder)
    )
    await store.loadIfNeeded()
    return store
}

// MARK: - Source mutations (48)

@Suite("Source mutations report and roll back failed writes")
@MainActor
struct SourceMutationTests {

    @Test("A failed rename leaves the name unchanged and says so")
    func failedRenameRollsBack() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.upsert(DataSource(id: "a", displayName: "Strap", transport: .bluetooth))

        store.injectDatabaseFailureOnNextCommitForTesting()
        let result = store.rename(sourceID: "a", to: "Renamed")

        #expect(result.isFailure)
        #expect(store.source(id: "a")?.displayName == "Strap")
        #expect(store.rename(sourceID: "a", to: "Renamed") == .applied)
        #expect(store.source(id: "a")?.displayName == "Renamed")
    }

    @Test("A rename survives the transport re-reporting its own name")
    func renameIsNotUndoneByASync() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "hk.oura", displayName: "Oura", transport: .healthKit))
        #expect(store.rename(sourceID: "hk.oura", to: "My ring") == .applied)

        // Every Health sync re-reports the writer's name.
        store.upsert(DataSource(id: "hk.oura", displayName: "Oura", transport: .healthKit))

        #expect(store.source(id: "hk.oura")?.displayName == "My ring")
        // An unrenamed source still follows its transport.
        store.upsert(DataSource(id: "hk.other", displayName: "Before", transport: .healthKit))
        store.upsert(DataSource(id: "hk.other", displayName: "After", transport: .healthKit))
        #expect(store.source(id: "hk.other")?.displayName == "After")
    }

    @Test("A failed pause leaves the device collecting")
    func failedPauseRollsBack() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.upsert(DataSource(id: "a", displayName: "Strap", transport: .bluetooth))

        store.injectDatabaseFailureOnNextCommitForTesting()
        #expect(store.setEnabled(false, forSource: "a").isFailure)
        #expect(store.source(id: "a")?.isEnabled == true)
        #expect(store.setEnabled(false, forSource: "a") == .applied)
        #expect(store.setEnabled(false, forSource: "a") == .unchanged)
    }

    @Test("A failed removal deletes nothing")
    func failedRemovalKeepsSourceAndReadings() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.upsert(DataSource(id: "a", displayName: "Strap", transport: .bluetooth))
        store.append(Reading(sourceID: "a", kind: .heartRate, value: 60, start: .now.addingTimeInterval(-60)))

        store.injectDatabaseFailureOnNextCommitForTesting()
        #expect(store.removeSourceResult(id: "a").isFailure)
        #expect(store.source(id: "a") != nil)
        #expect(store.readings.count == 1)

        #expect(store.removeSourceResult(id: "a") == .applied)
        #expect(store.source(id: "a") == nil)
        #expect(store.readings.isEmpty)
        #expect(store.removeSourceResult(id: "a") == .unchanged)
    }

    @Test("A rolled-back source update does not stay in memory")
    func failedUpsertRollsBack() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)

        store.injectDatabaseFailureOnNextCommitForTesting()
        store.upsert(DataSource(id: "a", displayName: "Strap", transport: .bluetooth))
        #expect(store.source(id: "a") == nil)

        store.upsert(DataSource(id: "a", displayName: "Strap", transport: .bluetooth))
        #expect(store.source(id: "a") != nil)
    }

    @Test("Removal, rename, and pause are refused before the store has loaded")
    func refusedBeforeLoad() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HealthStore(
            persistenceEnabled: true,
            databaseURL: folder.appendingPathComponent("health.sqlite3"),
            archive: ReadingArchive(directory: folder)
        )
        #expect(store.loadState == .notLoaded)
        #expect(store.removeSourceResult(id: "a").isFailure)
        #expect(store.rename(sourceID: "a", to: "x") == .unchanged)   // unknown source
    }
}

// MARK: - Estimate reconciliation (43)

@Suite("Estimate reconciliation scope")
@MainActor
struct EstimateReconciliationTests {

    @Test("Reconciling estimates reads only the estimate rows in scope")
    func candidatesAreScoped() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.upsert(DataSource(id: "ring", displayName: "Ring", transport: .bluetooth))
        store.upsert(DataSource(id: "heartsync.estimate", displayName: "Estimate", transport: .manual))
        let now = Date.now
        let ringEstimate = Reading(sourceID: "ring", kind: .bloodPressureSystolic, value: 120,
                                   start: now.addingTimeInterval(-60), provenance: .estimated)
        let ownEstimate = Reading(sourceID: "heartsync.estimate", kind: .bloodPressureSystolic, value: 122,
                                  start: now.addingTimeInterval(-60), provenance: .estimated)
        let measured = Reading(sourceID: "ring", kind: .heartRate, value: 60, start: now.addingTimeInterval(-60))
        store.append(contentsOf: [ringEstimate, ownEstimate, measured])

        let removed = store.reconcileEstimates(
            kinds: [.bloodPressureSystolic],
            keeping: [],
            currentSince: nil,
            sourceID: "heartsync.estimate"
        )

        #expect(removed == 1)
        let remaining = Set(store.readings.map(\.id))
        #expect(remaining == [ringEstimate.id, measured.id])
    }

    @Test("Legacy VO₂ estimates without a marker are still HeartSync's, a foreign marker is not")
    func markerDecidesOwnership() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.upsert(DataSource(id: "strap", displayName: "Strap", transport: .bluetooth))
        let start = Calendar.current.startOfDay(for: .now)
        let legacy = Reading(sourceID: "strap", kind: .vo2Max, value: 40, start: start,
                             end: start.addingTimeInterval(day), provenance: .estimated)
        var foreign = legacy
        foreign.id = UUID()
        foreign.metadata = ReadingMetadata(modelledBy: "another.app")
        store.append(contentsOf: [legacy, foreign])

        store.reconcileEstimates(kinds: [.vo2Max], keeping: [], currentSince: nil)

        #expect(store.readings.map(\.id) == [foreign.id])
    }
}

// MARK: - Maintenance (51)

@Suite("Maintenance no longer runs per ingest")
@MainActor
struct MaintenanceTests {

    @Test("A batch commit leaves aged history alone; maintenance prunes it")
    func ingestDoesNotPrune() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.confirmRetention(days: 30)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .healthKit))
        let aged = Reading(sourceID: "a", kind: .heartRate, value: 60, start: .now.addingTimeInterval(-40 * day))
        let fresh = Reading(sourceID: "a", kind: .heartRate, value: 61, start: .now.addingTimeInterval(-60))
        store.append(contentsOf: [aged, fresh])

        // The HealthKit page path: one committed batch, then the anchor moves. Nothing here
        // prunes, compacts, or checkpoints any more.
        let result = store.appendBatch(
            readings: [Reading(sourceID: "a", kind: .heartRate, value: 62, start: .now.addingTimeInterval(-30))]
        )
        #expect(result.committed)
        #expect(store.readings.count == 3)

        #expect(await store.saveNow())
        #expect(Set(store.readings.map(\.id)).contains(aged.id) == false)
        #expect(store.readings.count == 2)
    }

    @Test("A prune that only trims history writes no source rows")
    func pruneDoesNotRewriteSources() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.confirmRetention(days: 30)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        let before = store.source(id: "a")

        #expect(store.prune())
        #expect(store.source(id: "a") == before)
    }

    @Test("A window that straddled the previous pass's cutoff is folded whole by the next pass")
    func compactionKeepsStraddlingWindowsWhole() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        // Aligned to a whole minute, plus 30 s, so the first pass's cutoff falls mid-window.
        let firstMinute = ComparisonEngine.floorToWindow(.now.addingTimeInterval(-40 * day), size: 60)
        let origin = firstMinute.addingTimeInterval(30)
        var readings: [Reading] = []
        for minute in 0..<(4 * 24 * 60) {
            let base = firstMinute.addingTimeInterval(Double(minute) * 60)
            for offset in [31.0, 45.0, 59.0] {
                readings.append(Reading(sourceID: "a", kind: .heartRate, value: 60 + Double(minute % 5),
                                        start: base.addingTimeInterval(offset)))
            }
        }
        _ = origin
        store.append(contentsOf: readings)
        let now = firstMinute.addingTimeInterval(40 * day)

        var passes = 0
        while passes < 6 {
            #expect(store.compact(now: now))
            passes += 1
        }

        // One median per minute per source, nothing left raw below the age cutoff.
        let windows = Set(store.readings.map { ComparisonEngine.floorToWindow($0.midpoint, size: 60) })
        #expect(store.readings.count == windows.count)
        #expect(store.readings.allSatisfy { $0.metadata?.aggregation != nil })
    }
}

// MARK: - Observation churn (56)

@Suite("A streaming source does not rewrite the observed source list per reading")
@MainActor
struct SourceStatusChurnTests {

    @Test("Last-seen moves in coarse steps and metrics only when a new one appears")
    func lastSeenIsCoarse() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        let base = Date.now.addingTimeInterval(-600)

        store.append(Reading(sourceID: "a", kind: .heartRate, value: 60, start: base))
        let first = try #require(store.source(id: "a")?.lastSeenAt)
        #expect(first == base)

        store.append(Reading(sourceID: "a", kind: .heartRate, value: 61, start: base.addingTimeInterval(1)))
        #expect(store.source(id: "a")?.lastSeenAt == first)

        let later = base.addingTimeInterval(HealthStore.lastSeenResolution + 1)
        store.append(Reading(sourceID: "a", kind: .heartRate, value: 62, start: later))
        #expect(store.source(id: "a")?.lastSeenAt == later)

        // A metric seen for the first time is always shown.
        store.append(Reading(sourceID: "a", kind: .spo2, value: 97, start: later.addingTimeInterval(1)))
        #expect(store.source(id: "a")?.observedMetrics == [.heartRate, .spo2])
    }
}

// MARK: - Count-only queries (58)

@Suite("History counts are answered in SQL")
@MainActor
struct HistoryCountTests {

    @Test("Retention impact counts what a shorter period would delete and what would still fold")
    func retentionImpactCounts() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        let now = Date.now
        func reading(_ daysAgo: Double, compacted: Bool = false) -> Reading {
            Reading(
                sourceID: "a", kind: .heartRate, value: 60,
                start: now.addingTimeInterval(-daysAgo * day),
                metadata: compacted
                    ? ReadingMetadata(aggregation: AggregationMetadata(originalSampleCount: 5, originalStandardDeviation: 1))
                    : nil
            )
        }
        store.append(contentsOf: [
            reading(100), reading(50), reading(20), reading(18, compacted: true), reading(2),
        ])

        let impact = store.retentionImpact(days: 30, now: now)
        #expect(impact.readingsDeleted == 2)                       // 100 and 50 days old
        #expect(impact.readingsEligibleForCompaction == 1)         // the raw one 20 days old
        #expect(store.retentionImpact(days: 365, now: now).readingsDeleted == 0)
    }

    @Test("A session's count is restricted to its own sources and metric")
    func periodSummaryIsScoped() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        for id in ["a", "b", "c"] { store.upsert(DataSource(id: id, displayName: id, transport: .bluetooth)) }
        let start = Date.now.addingTimeInterval(-3_600)
        let interval = DateInterval(start: start, end: start.addingTimeInterval(1_800))
        for index in 0..<10 {
            let at = start.addingTimeInterval(Double(index) * 60)
            store.append(Reading(sourceID: "a", kind: .heartRate, value: 60, start: at))
            store.append(Reading(sourceID: "b", kind: .heartRate, value: 61, start: at))
            store.append(Reading(sourceID: "c", kind: .heartRate, value: 62, start: at))
            store.append(Reading(sourceID: "a", kind: .spo2, value: 97, start: at))
        }

        let scoped = try #require(store.periodSummaryOutcome(
            interval: interval, sourceIDs: ["a", "b"], kind: .heartRate
        ).value)
        #expect(scoped.count == 20)
        let everything = try #require(store.periodSummaryOutcome(interval: interval, sourceIDs: nil, kind: nil).value)
        #expect(everything.count == 40)
    }

    @Test("Five readings added and five removed is not reported as unchanged")
    func fingerprintDetectsReplacement() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        let start = Date.now.addingTimeInterval(-3_600)
        let interval = DateInterval(start: start.addingTimeInterval(-60), end: start.addingTimeInterval(1_800))
        let original = (0..<5).map {
            Reading(sourceID: "a", kind: .heartRate, value: 60, start: start.addingTimeInterval(Double($0) * 60))
        }
        store.append(contentsOf: original)
        let before = try #require(store.periodSummaryOutcome(interval: interval, sourceIDs: ["a"], kind: .heartRate).value)

        store.remove(readingIDs: original.map(\.id))
        store.append(contentsOf: (0..<5).map {
            Reading(sourceID: "a", kind: .heartRate, value: 61, start: start.addingTimeInterval(Double($0) * 60))
        })
        let after = try #require(store.periodSummaryOutcome(interval: interval, sourceIDs: ["a"], kind: .heartRate).value)

        #expect(after.count == before.count)
        #expect(after.fingerprint != before.fingerprint)

        var session = ComparisonSession(interval: interval, sourceIDs: ["a"], metric: .heartRate)
        session.lastViewedReadingCount = before.count
        session.lastViewedFingerprint = before.fingerprint
        let notice = session.revisitDisclosure(currentReadingCount: after.count, currentFingerprint: after.fingerprint)
        #expect(notice != nil)
        #expect(session.revisitDisclosure(currentReadingCount: before.count, currentFingerprint: before.fingerprint) == nil)
    }

    @Test("A baseline recorded before fingerprints existed is not compared with a session-scoped count")
    func legacyBaselineIsNotCompared() {
        var session = ComparisonSession(interval: DateInterval(start: .now, duration: 60), sourceIDs: ["a"])
        session.lastViewedReadingCount = 500   // counted across every source by an older build
        #expect(session.revisitDisclosure(currentReadingCount: 40, currentFingerprint: 1) == nil)
        // Without a fingerprint the old count-only rule still applies.
        #expect(session.revisitDisclosure(currentReadingCount: 40) != nil)
    }
}

// MARK: - Sub-second payload dates (67)

@Suite("Stored payloads keep sub-second timestamps")
@MainActor
struct PayloadDateTests {

    @Test("A one-second reading keeps its fractional start, end, and midpoint")
    func fractionsSurviveStorage() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await loadedStore(in: folder)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        let start = Date(timeIntervalSince1970: 1_780_000_079.7)
        let end = Date(timeIntervalSince1970: 1_780_000_080.7)
        let original = Reading(sourceID: "a", kind: .heartRate, value: 60, start: start, end: end)
        store.append(original)

        let stored = try #require(store.readings.first)
        #expect(abs(stored.start.timeIntervalSince1970 - start.timeIntervalSince1970) < 0.001)
        #expect(abs(stored.end.timeIntervalSince1970 - end.timeIntervalSince1970) < 0.001)
        #expect(abs(stored.midpoint.timeIntervalSince1970 - original.midpoint.timeIntervalSince1970) < 0.001)

        // 1,780,000,080 is a one-minute boundary. The reading straddles it, with its midpoint
        // just after: returned by a range that starts there, and binned with the window that
        // starts there, not the one before it.
        let range = DateInterval(start: Date(timeIntervalSince1970: 1_780_000_080), end: Date(timeIntervalSince1970: 1_780_000_140))
        let inRange = store.readings(kind: .heartRate, in: range, enabledOnly: false)
        #expect(inRange.count == 1)
        let window = try #require(ComparisonEngine.windows(from: inRange, kind: .heartRate, range: range).first)
        // Truncated to whole seconds the midpoint was 79.5 s, in the window before.
        #expect(window.start == Date(timeIntervalSince1970: 1_780_000_080))
    }

    @Test("Whole-second dates are written exactly as the earlier format wrote them")
    func wholeSecondsAreUnchanged() {
        let date = Date(timeIntervalSince1970: 1_709_649_000)   // 2024-03-05T14:30:00Z
        #expect(HealthDatabase.PayloadDates.string(from: date) == "2024-03-05T14:30:00Z")
        #expect(HealthDatabase.PayloadDates.date(from: "2024-03-05T14:30:00Z") == date)
    }

    @Test("Fractional and whole-second dates both decode")
    func bothFormsDecode() {
        let whole = HealthDatabase.PayloadDates.date(from: "2024-03-05T14:30:00Z")
        let fractional = HealthDatabase.PayloadDates.date(from: "2024-03-05T14:30:00.250Z")
        #expect(whole != nil)
        #expect(fractional != nil)
        if let whole, let fractional {
            #expect(abs(fractional.timeIntervalSince(whole) - 0.25) < 0.0005)
        }
        #expect(HealthDatabase.PayloadDates.date(from: "not a date") == nil)
    }

    @Test("A fraction round-trips to the millisecond")
    func fractionRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_709_649_000.731)
        let text = HealthDatabase.PayloadDates.string(from: date)
        #expect(text.contains(".731"))
        let decoded = HealthDatabase.PayloadDates.date(from: text)
        #expect(abs((decoded?.timeIntervalSince1970 ?? 0) - date.timeIntervalSince1970) < 0.0005)
    }
}

// MARK: - CSV (60)

@Suite("Every CSV export neutralises spreadsheet formulas")
@MainActor
struct CSVSafetyTests {

    @Test("A hostile device name cannot become a formula in the whole-history export")
    func historyExportNeutralisesNames() {
        let hostile = DataSource(
            id: "a",
            displayName: #"=HYPERLINK("https://example.com","click")"#,
            transport: .bluetooth,
            model: "+cmd|' /C calc'!A0"
        )
        let reading = Reading(sourceID: "a", kind: .heartRate, value: 60, start: Date(timeIntervalSince1970: 1_780_000_000))

        let csv = HealthStore.exportCSV(readings: [reading], sources: [hostile])
        let row = csv.components(separatedBy: "\r\n")[1]

        #expect(row.contains(#""'=HYPERLINK(""https://example.com"",""click"")""#))
        #expect(row.contains("'+cmd|'"))
        #expect(!row.contains(",=HYPERLINK"))
        #expect(!row.contains(",+cmd"))
    }

    @Test("The two exporters share one escape and one neutraliser")
    func sharedWriter() {
        #expect(CSV.spreadsheetSafe("-1+1") == "'-1+1")
        #expect(CSV.spreadsheetSafe("  @SUM(A1)") == "'  @SUM(A1)")
        #expect(CSV.spreadsheetSafe("Polar H10") == "Polar H10")
        #expect(CSV.spreadsheetSafe("tab\there") == "tab here")
        #expect(CSV.escape("a,b") == "\"a,b\"")
        #expect(CSV.escape("a\r\nb") == "\"a\r\nb\"")
        #expect(CSV.escape("plain") == "plain")
    }
}
