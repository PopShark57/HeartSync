import Foundation
import Testing
@testable import HeartSyncChecker

/// The wrist's sync-all reply: its wire format, and how each transport's state becomes an
/// outcome the watch can show without claiming a sync that did not happen.
@Suite("Watch sync-all report")
struct WatchSyncReportTests {
    private let since = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A report round-trips and stays small")
    func roundTrip() throws {
        let report = WatchSyncReport(
            status: .completed, finishedAt: since,
            health: .synced, oura: .partial,
            bluetoothDevices: 2, bluetoothPoweredOn: true, ringImports: 1
        )
        let data = try report.encoded()

        #expect(data.count <= WatchSyncReport.maximumBytes)
        #expect(try WatchSyncReport.decode(data) == report)
    }

    @Test("Malformed, oversized, and newer-version replies are rejected")
    func rejectsBadReplies() throws {
        let impossible = WatchSyncReport(status: .completed, finishedAt: since, bluetoothDevices: 1, ringImports: 2)
        #expect(throws: WatchSnapshot.PayloadError.self) { try impossible.encoded() }

        var newer = WatchSyncReport(status: .completed, finishedAt: since)
        newer.version = WatchSyncReport.currentVersion + 1
        let newerData = try JSONEncoder().encode(newer)
        #expect(throws: WatchSnapshot.PayloadError.self) { try WatchSyncReport.decode(newerData) }

        #expect(throws: WatchSnapshot.PayloadError.self) {
            try WatchSyncReport.decode(Data(count: WatchSyncReport.maximumBytes + 1))
        }
        #expect(throws: (any Error).self) { try WatchSyncReport.decode(Data("{}".utf8)) }
    }

    @Test("The watch shows one line per source, plus ring imports and a still-running note")
    func lines() {
        var report = WatchSyncReport(
            status: .stillRunning, finishedAt: since,
            health: .synced, oura: .running,
            bluetoothDevices: 2, ringImports: 1
        )
        #expect(report.lines.count == 5)
        #expect(report.lines[0].contains(WatchSyncReport.text(.synced)))
        #expect(report.lines[1].contains(WatchSyncReport.text(.running)))

        report.status = .completed
        report.ringImports = 0
        #expect(report.lines.count == 3)

        report.bluetoothPoweredOn = false
        #expect(report.lines[2] != WatchSyncReport(status: .completed, finishedAt: since, bluetoothDevices: 2).lines[2])

        #expect(WatchSyncReport.tooSoon(at: since).lines.count == 1)
        #expect(WatchSyncReport.unavailable(at: since).lines.count == 1)
    }

    @Test("Health is synced only for a complete drain that ran for this request")
    func healthOutcome() {
        typealias Summary = HealthKitManager.HealthKitSyncSummary
        let complete = Summary(outcome: .complete, results: [], attemptedAt: since.addingTimeInterval(5))
        let partial = Summary(outcome: .permissionUnknown, results: [], attemptedAt: since.addingTimeInterval(5))
        let failed = Summary(outcome: .failed, results: [], attemptedAt: since.addingTimeInterval(5))
        let earlier = Summary(outcome: .complete, results: [], attemptedAt: since.addingTimeInterval(-5))

        #expect(WatchSyncOutcomes.healthKit(complete, since: since) == .synced)
        #expect(WatchSyncOutcomes.healthKit(partial, since: since) == .partial)
        #expect(WatchSyncOutcomes.healthKit(failed, since: since) == .failed)
        #expect(WatchSyncOutcomes.healthKit(earlier, since: since) == .failed)
        #expect(WatchSyncOutcomes.healthKit(nil, since: since) == .failed)
    }

    @Test("Oura is synced only for a clean cycle committed for this request")
    func ouraOutcome() {
        let after = since.addingTimeInterval(5)
        let now = since.addingTimeInterval(10)
        let later = since.addingTimeInterval(600)

        #expect(WatchSyncOutcomes.oura(committedAt: after, issueCount: 0, rateLimitedUntil: nil, since: since, now: now) == .synced)
        #expect(WatchSyncOutcomes.oura(committedAt: after, issueCount: 2, rateLimitedUntil: nil, since: since, now: now) == .partial)
        // Committed what came before a 429: kept, but not the whole cycle.
        #expect(WatchSyncOutcomes.oura(committedAt: after, issueCount: 0, rateLimitedUntil: later, since: since, now: now) == .partial)
        #expect(WatchSyncOutcomes.oura(committedAt: nil, issueCount: 0, rateLimitedUntil: later, since: since, now: now) == .rateLimited)
        #expect(WatchSyncOutcomes.oura(committedAt: since.addingTimeInterval(-60), issueCount: 0, rateLimitedUntil: nil, since: since, now: now) == .failed)
        // An expired backoff says nothing about this cycle.
        #expect(WatchSyncOutcomes.oura(committedAt: nil, issueCount: 0, rateLimitedUntil: since, since: since, now: now) == .failed)
    }
}
