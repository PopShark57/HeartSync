import Foundation
import Testing
@testable import HeartSyncChecker

// MARK: - Day parsing determinism (finding 1.6)

/// Serialized because these tests move `NSTimeZone.default`, which is process-global. The
/// window it is moved for is two statements wide and it is always put back.
@Suite("Oura day parsing", .serialized)
struct OuraDayParsingTests {

    /// 2026-08-28T00:00:00Z. Written as an epoch instant on purpose: the whole point of the
    /// finding is that a `day` string names one absolute instant and not "midnight wherever
    /// the phone happens to be standing".
    private let august28UTC = Date(timeIntervalSince1970: 1_787_875_200)

    @Test("A day string names UTC midnight, not local midnight")
    func dayStringIsUTCMidnight() throws {
        #expect(OuraClient.parseDay("2026-08-28") == august28UTC)
        #expect(OuraClient.parseDay("2026-01-01") == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(OuraClient.parseDay("2026-09-01") == Date(timeIntervalSince1970: 1_788_220_800))
        #expect(OuraClient.parseDay("28-08-2026") == nil)
        #expect(OuraClient.parseDay("not a day") == nil)
    }

    @Test("The same Oura document yields the same reading instants in every time zone")
    func dayDocumentsAreTimeZoneIndependent() throws {
        // Kiritimati is UTC+14 and Pago Pago is UTC-11: 25 hours apart, so a local-midnight
        // parse cannot possibly agree across the pair. Any calendar day is a different
        // instant in the two zones.
        let oxygen = OuraClient.DailySpO2(
            id: "oxygen-2026-08-28",
            day: "2026-08-28",
            spo2_percentage: .init(average: 96.4)
        )
        let sleep = OuraClient.SleepDocument(
            // No bedtime timestamps, so the mapping has nothing but `day` to work from —
            // which is exactly the path the finding is about.
            id: "sleep-2026-08-28", day: "2026-08-28",
            bedtime_start: nil, bedtime_end: nil,
            average_hrv: 42, average_heart_rate: nil,
            lowest_heart_rate: 49, average_breath: nil
        )
        let vo2 = OuraClient.VO2MaxDocument(
            id: "vo2-2026-08-28", day: "2026-08-28", timestamp: nil, vo2_max: 46.2
        )

        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        NSTimeZone.default = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let eastOxygen = OuraManager.readings(fromSpO2: [oxygen])
        let eastSleep = OuraManager.readings(fromSleep: [sleep])
        let eastVO2 = OuraManager.readings(fromVO2Max: [vo2])

        NSTimeZone.default = try #require(TimeZone(identifier: "Pacific/Pago_Pago"))
        let westOxygen = OuraManager.readings(fromSpO2: [oxygen])
        let westSleep = OuraManager.readings(fromSleep: [sleep])
        let westVO2 = OuraManager.readings(fromVO2Max: [vo2])

        NSTimeZone.default = original

        #expect(eastOxygen.map(\.start) == westOxygen.map(\.start))
        #expect(eastSleep.map(\.start) == westSleep.map(\.start))
        #expect(eastVO2.map(\.start) == westVO2.map(\.start))
        #expect(eastOxygen.first?.start == august28UTC)
        #expect(eastSleep.first?.start == august28UTC)
        #expect(eastVO2.first?.start == august28UTC)
        // A day document covers the whole 86,400-second window that starts at that instant,
        // which is exactly one epoch-aligned comparison bucket.
        #expect(eastOxygen.first?.end == august28UTC.addingTimeInterval(86_400))
    }

    @Test("Reading identity comes from Oura document ids and never from the parsed date")
    func readingIdentityIsDerivedFromDocumentIDs() throws {
        // These literals are the point of the test. A reading id is the key that lets a
        // corrected Oura document replace its earlier copy instead of duplicating it, so
        // changing the recipe orphans every archived reading of that kind. If this list has
        // to be edited, the edit needs a migration, not a new expectation.
        let oxygen = OuraClient.DailySpO2(
            id: "oxygen-2026-08-28", day: "2026-08-28", spo2_percentage: .init(average: 96.4)
        )
        let sleep = OuraClient.SleepDocument(
            id: "sleep-2026-08-28", day: "2026-08-28",
            bedtime_start: nil, bedtime_end: nil,
            average_hrv: 42, average_heart_rate: nil,
            lowest_heart_rate: 49, average_breath: nil
        )
        let vo2 = OuraClient.VO2MaxDocument(
            id: "vo2-2026-08-28", day: "2026-08-28", timestamp: nil, vo2_max: 46.2
        )
        let heartRate = OuraClient.HeartRatePoint(
            bpm: 61, source: "rest", timestamp: "2026-08-28T10:00:00+00:00"
        )

        #expect(OuraManager.readings(fromSpO2: [oxygen]).first?.id
            == UUID(uuidString: "BC1C7A0B-A943-580E-9B4A-4A5EE26A871C"))
        #expect(OuraManager.readings(fromVO2Max: [vo2]).first?.id
            == UUID(uuidString: "54056E14-29A9-5546-9148-C8C2ED8D8282"))
        #expect(OuraManager.readings(fromHeartRate: [heartRate]).first?.id
            == UUID(uuidString: "74CD50A4-802F-5089-A6F0-61E227E03F48"))

        let sleepReadings = OuraManager.readings(fromSleep: [sleep])
        #expect(sleepReadings.first(where: { $0.kind == .hrvRMSSD })?.id
            == UUID(uuidString: "BA3CFB6D-94D6-58F4-99BD-630B08C0FD04"))
        #expect(sleepReadings.first(where: { $0.kind == .restingHeartRate })?.id
            == UUID(uuidString: "9284EC45-AA9B-5105-86AD-52D1F38F8198"))

        // The same document read on a phone in a different zone is the same reading, so its
        // id must not move even though a naive implementation could fold the parsed date in.
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        let relocated = OuraManager.readings(fromSpO2: [oxygen]).first?.id
        NSTimeZone.default = original
        #expect(relocated == UUID(uuidString: "BC1C7A0B-A943-580E-9B4A-4A5EE26A871C"))
    }
}

// MARK: - Pagination ceiling and rate limits (findings 4.1 and 4.2)

@Suite("Oura pagination and rate limits")
struct OuraTransportLimitTests {

    private func makeSession(_ protocolClass: AnyClass) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }

    @Test("A page walk that hits the ceiling is reported as a prefix, not the collection")
    func truncatedPageWalkIsSurfaced() async throws {
        OuraEndlessPagesURLProtocol.log.reset()
        let session = makeSession(OuraEndlessPagesURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let client = OuraClient(accessToken: "truncation-token", session: session)
        let start = try #require(OuraClient.parseDay("2026-08-01"))
        let end = try #require(OuraClient.parseDay("2026-08-15"))

        let result = try await client.dailyStress(from: start, to: end)

        // Oura never stopped offering a next_token, so what came back is a prefix. Reporting
        // this as `available(25)` is the bug: the screen then tells the user it holds a
        // fortnight when it holds whatever fitted in 25 pages.
        #expect(result.isTruncated)
        #expect(result.count == 25)
        // The ceiling is a documented contract (25 pages per collection); a page walk with
        // no ceiling lets one looping cursor hold a sequential sync open forever.
        #expect(OuraEndlessPagesURLProtocol.log.count == 25)
        #expect(!OuraEndpointState.partial(result.count).isComplete)
        #expect(OuraEndpointState.partial(result.count).recordCount == 25)
    }

    @Test("A collection that ends inside the ceiling is complete")
    func completePageWalkIsNotTruncated() async throws {
        OuraTwoPageURLProtocol.log.reset()
        let session = makeSession(OuraTwoPageURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let client = OuraClient(accessToken: "pagination-token", session: session)
        let start = try #require(OuraClient.parseDay("2026-08-01"))
        let end = try #require(OuraClient.parseDay("2026-08-15"))

        let result = try await client.dailyStress(from: start, to: end)

        #expect(!result.isTruncated)
        #expect(result.count == 2)
        #expect(OuraTwoPageURLProtocol.log.count == 2)
        #expect(OuraEndpointState.available(result.count).isComplete)
        // The second page must be requested with the cursor the first one handed back,
        // otherwise the walk silently re-reads page one until the ceiling stops it.
        let second = try #require(OuraTwoPageURLProtocol.log.recorded.last)
        let query = URLComponents(url: second, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first(where: { $0.name == "next_token" })?.value == "page-2")
    }

    @Test("A short Retry-After is honoured and retried a bounded number of times")
    func shortRateLimitRetriesWithinItsCap() async throws {
        OuraPersistentRateLimitURLProtocol.log.reset()
        let session = makeSession(OuraPersistentRateLimitURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let client = OuraClient(accessToken: "rate-limit-token", session: session)
        let start = try #require(OuraClient.parseDay("2026-08-01"))
        let end = try #require(OuraClient.parseDay("2026-08-15"))

        do {
            _ = try await client.dailyStress(from: start, to: end)
            Issue.record("Expected the rate limit to be surfaced once the retries ran out")
        } catch let failure as OuraClient.Failure {
            #expect(failure == .rateLimited(retryAfter: 1, detail: "Rate limit exceeded"))
        }

        // One attempt plus at most two retries. An unbounded retry loop against a server
        // that is already limiting the account is how a sync deepens its own rate limit.
        #expect(OuraPersistentRateLimitURLProtocol.log.count == 3)
    }

    @Test("A Retry-After longer than the client will wait is surfaced instead of slept through")
    func longRateLimitIsNotSleptThrough() async throws {
        OuraLongRateLimitURLProtocol.log.reset()
        let session = makeSession(OuraLongRateLimitURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let client = OuraClient(accessToken: "rate-limit-token", session: session)
        let start = try #require(OuraClient.parseDay("2026-08-01"))
        let end = try #require(OuraClient.parseDay("2026-08-15"))

        let began = Date.now
        do {
            _ = try await client.dailyStress(from: start, to: end)
            Issue.record("Expected a rate limit failure")
        } catch let failure as OuraClient.Failure {
            #expect(failure == .rateLimited(retryAfter: 600, detail: "Too Many Requests"))
        }

        // A sync issues nineteen sequential requests. Sleeping ten minutes inside one of
        // them stalls the other eighteen, so the wait belongs to the manager's cadence.
        #expect(OuraLongRateLimitURLProtocol.log.count == 1)
        #expect(Date.now.timeIntervalSince(began) < 30)
    }

    @Test("A rate limit that clears is retried rather than reported as a failure")
    func rateLimitRecovery() async throws {
        OuraRecoveringRateLimitURLProtocol.log.reset()
        let session = makeSession(OuraRecoveringRateLimitURLProtocol.self)
        defer { session.invalidateAndCancel() }
        let client = OuraClient(accessToken: "rate-limit-token", session: session)
        let start = try #require(OuraClient.parseDay("2026-08-01"))
        let end = try #require(OuraClient.parseDay("2026-08-15"))

        let result = try await client.dailyStress(from: start, to: end)

        #expect(result.count == 1)
        #expect(!result.isTruncated)
        #expect(OuraRecoveringRateLimitURLProtocol.log.count == 2)
    }
}

// MARK: - Sync orchestration (findings 1.4, 2.6, 4.1, 4.2 and the AGENTS.md Oura rules)

/// These drive a real `OuraManager` through a stubbed `URLSession.shared`, so they touch
/// process-global state: the Keychain credential item, the Oura dashboard archive file, and
/// the global `URLProtocol` registry. Every one of the three is captured before the test and
/// put back afterwards, and the suite is serialized so two of them never overlap.
@Suite("Oura sync orchestration", .serialized)
@MainActor
struct OuraSyncOrchestrationTests {

    @Test("An incremental sync asks only for the days after each collection's high-water mark")
    func incrementalSyncNarrowsItsWindow() async throws {
        let now = Date.now
        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-3_600)
        // A full backfill just happened, so this cycle is the incremental one.
        seeded.lastFullBackfillAt = now
        seeded.collectionSyncMarks[OuraEndpoint.dailyStress.rawValue] = now.addingTimeInterval(-3_600)
        seeded.collectionSyncMarks[OuraEndpoint.personalInfo.rawValue] = now

        try await withOuraSyncHarness(seeded: seeded, responding: ouraEmptyCollections) { manager, _ in
            await manager.sync(days: 14)

            let requests = OuraStubServer.shared.requests
            #expect(!requests.isEmpty, "The stub never saw a request; URLSession.shared was not intercepted")

            // A marked collection asks for its mark less the deliberate two-day overlap,
            // padded by the usual day. The exact instant depends on when the test runs, so
            // what is pinned is the shape: a few days, nowhere near the fortnight.
            let stressStart = try #require(ouraDayQueryStart(requests, path: "/daily_stress"))
            let stressDaysBack = now.timeIntervalSince(stressStart) / 86_400
            #expect(stressDaysBack > 2.5)
            #expect(stressDaysBack < 4.5)

            // An unmarked collection has no high-water mark to trust, so it still gets the
            // whole window. Narrowing that too would leave permanent holes in the cache.
            let heartRateStart = try #require(ouraTimeQueryStart(requests, path: "/heartrate"))
            let heartRateDaysBack = now.timeIntervalSince(heartRateStart) / 86_400
            #expect(heartRateDaysBack > 13.5)
            #expect(heartRateDaysBack < 14.5)

            // Profile data changes when the user edits it. Refetching it every quarter of an
            // hour is pure traffic, so a recent mark suppresses the request entirely.
            #expect(!requests.contains { $0.url?.path.hasSuffix("/personal_info") == true })

            // The mark advances, or the next cycle asks for the same days again forever.
            let mark = try #require(manager.snapshot.collectionSyncMarks[OuraEndpoint.dailyStress.rawValue])
            #expect(mark > now.addingTimeInterval(-3_600))
        }
    }

    @Test("A stale backfill re-requests the whole window despite the high-water marks")
    func periodicFullBackfillStillHappens() async throws {
        let now = Date.now
        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-25 * 3_600)
        // Older than the one-day backfill interval, so the marks must be ignored.
        seeded.lastFullBackfillAt = now.addingTimeInterval(-25 * 3_600)
        seeded.collectionSyncMarks[OuraEndpoint.dailyStress.rawValue] = now.addingTimeInterval(-3_600)
        seeded.collectionSyncMarks[OuraEndpoint.personalInfo.rawValue] = now.addingTimeInterval(-3_600)

        try await withOuraSyncHarness(seeded: seeded, responding: ouraEmptyCollections) { manager, _ in
            await manager.sync(days: 14)

            let requests = OuraStubServer.shared.requests
            #expect(!requests.isEmpty, "The stub never saw a request; URLSession.shared was not intercepted")

            // Incremental fetches only ever see what Oura chose to return for recent days.
            // Without this pass, a late correction or a day missed by an earlier failure
            // would never be picked up again.
            let stressStart = try #require(ouraDayQueryStart(requests, path: "/daily_stress"))
            let stressDaysBack = now.timeIntervalSince(stressStart) / 86_400
            #expect(stressDaysBack > 14.5)
            #expect(stressDaysBack < 16.5)

            // Forced along with the window, so a reconnect or a daily pass re-checks it.
            #expect(requests.contains { $0.url?.path.hasSuffix("/personal_info") == true })

            let backfill = try #require(manager.snapshot.lastFullBackfillAt)
            #expect(backfill >= now)
        }
    }

    @Test("A narrow incremental fetch merges into the cache instead of replacing it")
    func incrementalFetchPreservesCachedHistory() async throws {
        let now = Date.now
        // Relative days, because the sync prunes anything older than its own window; a fixed
        // 2026 fixture would be discarded as ancient the moment the clock moved past it.
        let today = ouraUTCDayString(now)
        let yesterday = ouraUTCDayString(now.addingTimeInterval(-86_400))
        let twoDaysAgo = ouraUTCDayString(now.addingTimeInterval(-2 * 86_400))
        let threeDaysAgo = ouraUTCDayString(now.addingTimeInterval(-3 * 86_400))

        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-3_600)
        seeded.lastFullBackfillAt = now
        seeded.collectionSyncMarks[OuraEndpoint.dailyStress.rawValue] = now.addingTimeInterval(-3_600)
        seeded.stress = [
            OuraClient.DailyStress(id: "stress-1", day: threeDaysAgo, day_summary: "normal", recovery_high: 3_600, stress_high: 900),
            OuraClient.DailyStress(id: "stress-2", day: twoDaysAgo, day_summary: "stressful", recovery_high: 1_800, stress_high: 5_400),
            OuraClient.DailyStress(id: "stress-3", day: yesterday, day_summary: "restored", recovery_high: 7_200, stress_high: 1_800),
        ]
        seeded.oxygen = [
            OuraClient.DailySpO2(id: "oxygen-1", day: twoDaysAgo, spo2_percentage: .init(average: 96.1)),
            OuraClient.DailySpO2(id: "oxygen-2", day: yesterday, spo2_percentage: .init(average: 96.8)),
        ]

        let freshStress = #"""
        {"data":[{"id":"stress-4","day":"\#(today)","day_summary":"restored","recovery_high":7200,"stress_high":1200}],"next_token":null}
        """#
        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/daily_stress") { return .json(freshStress) }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: seeded, responding: handler) { manager, _ in
            await manager.sync(days: 14)

            #expect(!OuraStubServer.shared.requests.isEmpty, "URLSession.shared was not intercepted")

            // The whole point of the finding: a two-day request must not become a two-day
            // dashboard. The fortnight the screen is drawing has to survive it.
            let stressIDs = Set(manager.snapshot.stress.map(\.id))
            #expect(stressIDs == ["stress-1", "stress-2", "stress-3", "stress-4"])

            // A collection that returned nothing at all keeps everything it held.
            #expect(Set(manager.snapshot.oxygen.map(\.id)) == ["oxygen-1", "oxygen-2"])

            // Merged records stay in chronological order so `latest…` selectors still work.
            #expect(manager.snapshot.latestStress?.id == "stress-4")
        }
    }

    @Test("A corrected document replaces its cached copy rather than joining it")
    func revisedDocumentReplacesCachedCopy() async throws {
        let now = Date.now
        let yesterday = ouraUTCDayString(now.addingTimeInterval(-86_400))

        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-3_600)
        seeded.lastFullBackfillAt = now
        seeded.collectionSyncMarks[OuraEndpoint.dailyStress.rawValue] = now.addingTimeInterval(-3_600)
        seeded.stress = [
            OuraClient.DailyStress(id: "stress-1", day: yesterday, day_summary: "stressful", recovery_high: 1_800, stress_high: 5_400),
        ]

        let corrected = #"""
        {"data":[{"id":"stress-1","day":"\#(yesterday)","day_summary":"restored","recovery_high":7200,"stress_high":1800}],"next_token":null}
        """#
        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/daily_stress") { return .json(corrected) }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: seeded, responding: handler) { manager, _ in
            await manager.sync(days: 14)

            #expect(manager.snapshot.stress.count == 1)
            #expect(manager.snapshot.stress.first?.day_summary == "restored")
        }
    }

    @Test("A complete full-window response removes records withdrawn upstream")
    func fullWindowReconcilesDeletion() async throws {
        let now = Date.now
        let yesterday = ouraUTCDayString(now.addingTimeInterval(-86_400))
        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-25 * 3_600)
        seeded.lastFullBackfillAt = now.addingTimeInterval(-25 * 3_600)
        seeded.oxygen = [
            OuraClient.DailySpO2(
                id: "withdrawn-oxygen",
                day: yesterday,
                spo2_percentage: .init(average: 96.2)
            ),
        ]

        try await withOuraSyncHarness(seeded: seeded, responding: ouraEmptyCollections) { manager, store in
            let priorReading = try #require(OuraManager.readings(fromSpO2: seeded.oxygen).first)
            store.upsert(DataSource(
                id: DataSource.ouraSourceID,
                displayName: "Oura Ring",
                transport: .oura
            ))
            #expect(store.upsert(contentsOf: [priorReading]).count == 1)
            await manager.sync(days: 14)

            #expect(manager.snapshot.oxygen.isEmpty)
            #expect(OuraManager.readings(fromSpO2: manager.snapshot.oxygen).isEmpty)
            #expect(store.readings.isEmpty)

            let relaunched = OuraManager()
            await relaunched.configure(
                store: HealthStore(persistenceEnabled: false),
                onReadings: { _, _, _ in true }
            )
            #expect(relaunched.snapshot.oxygen.isEmpty)
        }
    }

    @Test("A cache write failure leaves the previous Oura generation active")
    func cacheWriteFailureDoesNotCommit() async throws {
        let now = Date.now
        let yesterday = ouraUTCDayString(now.addingTimeInterval(-86_400))
        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-3_600)
        seeded.oxygen = [
            OuraClient.DailySpO2(
                id: "kept-oxygen",
                day: yesterday,
                spo2_percentage: .init(average: 96.2)
            ),
        ]

        try await withOuraSyncHarness(seeded: seeded, responding: ouraEmptyCollections) { manager, _ in
            await ReadingArchive.shared.injectFailureOnNextWriteForTesting()
            await manager.sync(days: 14)

            #expect(manager.snapshot.oxygen.map(\.id) == ["kept-oxygen"])
            #expect(manager.lastSyncSummary?.contains("not committed") == true)
            if case .error(let message) = manager.status {
                #expect(message.contains("could not save"))
            } else {
                Issue.record("Expected a durability error")
            }
        }
    }

    @Test("A database batch failure restores the previous Oura cache generation")
    func databaseFailureRollsBackCache() async throws {
        let now = Date.now
        let yesterday = ouraUTCDayString(now.addingTimeInterval(-86_400))
        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-25 * 3_600)
        seeded.lastFullBackfillAt = now.addingTimeInterval(-25 * 3_600)
        seeded.oxygen = [
            OuraClient.DailySpO2(
                id: "rollback-oxygen",
                day: yesterday,
                spo2_percentage: .init(average: 97.1)
            ),
        ]

        try await withOuraSyncHarness(seeded: seeded, responding: ouraEmptyCollections) { manager, store in
            store.injectDatabaseFailureOnNextCommitForTesting()
            await manager.sync(days: 14)

            #expect(manager.snapshot.oxygen.map(\.id) == ["rollback-oxygen"])
            #expect(manager.lastSyncSummary?.contains("not committed") == true)
            if case .error(let message) = manager.status {
                #expect(message.contains("previous Oura cache was restored"))
            } else {
                Issue.record("Expected a database durability error")
            }

            let relaunched = OuraManager()
            await relaunched.configure(
                store: HealthStore(persistenceEnabled: false),
                onReadings: { _, _, _ in true }
            )
            #expect(relaunched.snapshot.oxygen.map(\.id) == ["rollback-oxygen"])
        }
    }

    @Test("A truncated collection is never presented as complete, not even after a relaunch")
    func truncatedCollectionSurvivesAsPartial() async throws {
        let now = Date.now
        let today = ouraUTCDayString(now)
        let endlessStress = #"""
        {"data":[{"id":"stress-page","day":"\#(today)","day_summary":"restored","recovery_high":7200,"stress_high":1800}],"next_token":"more"}
        """#
        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/daily_stress") { return .json(endlessStress) }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: nil, responding: handler) { manager, _ in
            await manager.sync(days: 14)

            #expect(!OuraStubServer.shared.requests.isEmpty, "URLSession.shared was not intercepted")
            #expect(!manager.state(for: .dailyStress).isComplete)
            #expect(manager.state(for: .dailyStress).recordCount == 25)
            #expect(manager.snapshot.truncatedCollections.contains(OuraEndpoint.dailyStress.rawValue))
            #expect(manager.endpointIssues.contains { $0.endpoint == .dailyStress })
            // The user is told the difference between "nothing came back" and "not all of it
            // came back"; those are different claims about their data.
            #expect(manager.lastSyncSummary?.contains("incomplete") == true)
            // A collection that answered in full is still complete: the flag is per
            // collection, not a blanket downgrade of the whole sync.
            #expect(manager.state(for: .dailySleep).isComplete)

            // A relaunch reads the cache back. If truncation did not persist, the cached
            // prefix would be restored as `available` and quietly become "the collection".
            let relaunched = OuraManager()
            await relaunched.configure(
                store: HealthStore(persistenceEnabled: false),
                onReadings: { _, _, _ in true }
            )
            #expect(!relaunched.state(for: .dailyStress).isComplete)
            #expect(relaunched.state(for: .dailySleep).isComplete)
        }
    }

    @Test("A non-scope 401 aborts the sync without leaving an endpoint spinning")
    func expiredTokenLeavesNoEndpointSyncing() async throws {
        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/heartrate") {
                return .json(#"{"status":401,"title":"Unauthorized","detail":"Access token expired"}"#, status: 401)
            }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: nil, responding: handler) { manager, _ in
            await manager.sync(days: 14)

            #expect(!OuraStubServer.shared.requests.isEmpty, "URLSession.shared was not intercepted")

            // The bug this guards: the endpoint that failed was left on `.syncing` and its
            // row spun forever, because the abort unwound past the state reset.
            for endpoint in OuraEndpoint.allCases {
                #expect(manager.state(for: endpoint) != .syncing, "\(endpoint.rawValue) is still spinning")
            }
            #expect(manager.state(for: .heartRate) != .idle)
            #expect(ouraIsFailed(manager.state(for: .heartRate)))
            // Everything after the abort was never attempted, and says so.
            #expect(manager.state(for: .dailyStress) == .idle)
            #expect(!manager.isSyncing)

            // A dead bearer token is cleared once instead of failing the remaining
            // eighteen requests in the same way.
            #expect(!manager.hasAuthorization)
            #expect(!manager.status.isConnected)
            let paths = OuraStubServer.shared.requests.compactMap { $0.url?.path }
            #expect(!paths.contains { $0.hasSuffix("/daily_stress") })
        }
    }

    @Test("A scope-related 401 is an endpoint permission problem, not a dead account")
    func scopeDenialKeepsTheCredential() async throws {
        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/daily_cardiovascular_age") || path.hasSuffix("/vO2_max") {
                return .json(
                    #"{"status":401,"title":"Unauthorized","detail":"Token is not authorized access heart_health scope."}"#,
                    status: 401
                )
            }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: nil, responding: handler) { manager, _ in
            await manager.sync(days: 14)

            #expect(!OuraStubServer.shared.requests.isEmpty, "URLSession.shared was not intercepted")

            // Declining one permission must never sign the account out.
            #expect(manager.hasAuthorization)
            #expect(manager.status.isConnected)
            #expect(manager.state(for: .cardiovascularAge) == .permissionMissing)
            #expect(manager.endpointIssues.contains { $0.endpoint == .cardiovascularAge && $0.isPermissionIssue })

            // The sync carried on through the collections that follow.
            #expect(manager.state(for: .workouts).isComplete)
            #expect(manager.lastSyncedAt != nil)
            for endpoint in OuraEndpoint.allCases {
                #expect(manager.state(for: endpoint) != .syncing)
            }
        }
    }

    @Test("A failed collection keeps its cache while successful empty collections reconcile")
    func oneFailedCollectionKeepsTheDashboard() async throws {
        let now = Date.now
        let yesterday = ouraUTCDayString(now.addingTimeInterval(-86_400))

        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-3_600)
        seeded.stress = [
            OuraClient.DailyStress(id: "stress-1", day: yesterday, day_summary: "restored", recovery_high: 7_200, stress_high: 1_800),
        ]
        seeded.oxygen = [
            OuraClient.DailySpO2(id: "oxygen-1", day: yesterday, spo2_percentage: .init(average: 96.8)),
        ]
        seeded.batteryLevels = [
            OuraClient.RingBatteryLevel(
                timestamp: "2026-08-28T12:00:00Z",
                timestamp_unix: Int64(now.addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000),
                charging: false, in_charger: false, level: 73
            ),
        ]

        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/daily_stress") {
                return .json(#"{"status":500,"title":"Internal Server Error"}"#, status: 500)
            }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: seeded, responding: handler) { manager, _ in
            await manager.sync(days: 14)

            #expect(ouraIsFailed(manager.state(for: .dailyStress)))
            // The cached collection is untouched by its own failure...
            #expect(manager.snapshot.stress.map(\.id) == ["stress-1"])
            // Successful complete empty responses are server-authoritative withdrawals;
            // they must not be confused with the failed collection above.
            #expect(manager.snapshot.oxygen.isEmpty)
            #expect(manager.snapshot.batteryLevels.isEmpty)
            #expect(manager.hasAuthorization)
            #expect(manager.snapshot.hasData)
        }
    }

    /// **This test currently fails, and the failure is the point.**
    ///
    /// `OuraSnapshot.batteryLevels` is the one merged collection whose age is computed as
    /// `Date(timeIntervalSince1970: TimeInterval(timestamp_unix))`, while `timestamp_unix`
    /// is milliseconds everywhere else in this codebase — `OuraDataTests` pins
    /// `1_777_030_400_000` against the ISO timestamp `2026-04-22T12:00:00Z`, which is only
    /// consistent with milliseconds. Read as seconds, every battery record dates to roughly
    /// the year 58,000, sits comfortably after any cutoff, and is never pruned. The archive
    /// therefore accumulates ring-battery samples for the life of the install even though
    /// the merge is documented as dropping anything older than the window.
    @Test("Ring battery records older than the window are pruned like every other collection")
    func staleBatteryRecordsArePruned() async throws {
        let now = Date.now
        let freshTimestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3_600))
        let freshUnix = Int64(now.addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000)
        var seeded = OuraSnapshot()
        seeded.fetchedAt = now.addingTimeInterval(-3_600)
        seeded.batteryLevels = [
            // 2017-07-14, in the milliseconds the API and the rest of this codebase use.
            OuraClient.RingBatteryLevel(
                timestamp: "2017-07-14T02:40:00Z",
                timestamp_unix: 1_500_000_000_000,
                charging: false, in_charger: false, level: 41
            ),
            OuraClient.RingBatteryLevel(
                timestamp: freshTimestamp,
                timestamp_unix: freshUnix,
                charging: false, in_charger: false, level: 73
            ),
        ]

        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            if request.url?.path.hasSuffix("/ring_battery") == true {
                return .json(
                    """
                    {"data":[{"timestamp":"\(freshTimestamp)","timestamp_unix":\(freshUnix),"charging":false,"in_charger":false,"level":73}],"next_token":null}
                    """
                )
            }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: seeded, responding: handler) { manager, _ in
            await manager.sync(days: 14)

            #expect(manager.snapshot.batteryLevels.map(\.level) == [73])
        }
    }

    @Test("A rate-limited sync backs off for the interval Oura asked for")
    func rateLimitHonoursRetryAfter() async throws {
        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/daily_stress") {
                return .json(
                    #"{"status":429,"title":"Too Many Requests"}"#,
                    status: 429,
                    headers: ["Retry-After": "120"]
                )
            }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: nil, responding: handler) { manager, _ in
            let began = Date.now
            await manager.sync(days: 14)

            let deadline = try #require(manager.rateLimitedUntil)
            // 120 seconds, not the 300-second default it would fall back to and not the
            // 1,800-second cap: the server's own number was used.
            #expect(deadline.timeIntervalSince(began) > 60)
            #expect(deadline.timeIntervalSince(began) < 200)
            #expect(manager.nextAutomaticSyncAllowedAt == deadline)

            // A 429 on one collection does not cascade: the remaining eighteen were still
            // asked for, and one limited endpoint is not an excuse to stop syncing.
            #expect(manager.state(for: .workouts).isComplete)
            #expect(ouraIsFailed(manager.state(for: .dailyStress)))

            // One cycle cannot spin: nineteen collections, at most three attempts each.
            #expect(OuraStubServer.shared.requests.count <= OuraEndpoint.allCases.count * 3)
            #expect(Date.now.timeIntervalSince(began) < 60)
        }
    }

    @Test("An absurd Retry-After is capped instead of disabling syncing")
    func rateLimitBackoffIsCapped() async throws {
        let handler: @Sendable (URLRequest) -> OuraStubReply = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/daily_stress") {
                return .json(
                    #"{"status":429,"title":"Too Many Requests"}"#,
                    status: 429,
                    headers: ["Retry-After": "864000"]
                )
            }
            return ouraEmptyCollections(request)
        }

        try await withOuraSyncHarness(seeded: nil, responding: handler) { manager, _ in
            let began = Date.now
            await manager.sync(days: 14)

            let deadline = try #require(manager.rateLimitedUntil)
            // Ten days was asked for. Honouring it literally would silently switch the ring
            // off for a week and a half.
            #expect(deadline.timeIntervalSince(began) <= 30 * 60 + 5)
            #expect(deadline.timeIntervalSince(began) > 60)
        }
    }

    @Test("A clean cycle lifts a previous rate-limit backoff")
    func cleanCycleClearsTheBackoff() async throws {
        try await withOuraSyncHarness(seeded: nil, responding: ouraEmptyCollections) { manager, _ in
            await manager.sync(days: 14)
            // Nothing rate-limited this cycle, so nothing may hold off the next one; a
            // backoff that is only ever set is a sync that stops for good.
            #expect(manager.rateLimitedUntil == nil)
            #expect(manager.nextAutomaticSyncAllowedAt == nil)
            #expect(manager.status.isConnected)
        }
    }
}

// MARK: - Harness

/// Reply for one stubbed Oura request.
private struct OuraStubReply: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(
        _ text: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> OuraStubReply {
        var headers = headers
        headers["Content-Type"] = "application/json"
        return OuraStubReply(status: status, headers: headers, body: Data(text.utf8))
    }
}

/// `OuraManager` builds its own `OuraClient` on `URLSession.shared`, so there is no session
/// to inject. A globally registered `URLProtocol` is the only seam; it is installed for the
/// duration of one test and removed afterwards.
private final class OuraStubServer: @unchecked Sendable {
    static let shared = OuraStubServer()

    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) -> OuraStubReply)?
    private var recorded: [URLRequest] = []

    func install(_ handler: @escaping @Sendable (URLRequest) -> OuraStubReply) {
        lock.lock()
        self.handler = handler
        recorded = []
        lock.unlock()
    }

    func uninstall() {
        lock.lock()
        handler = nil
        recorded = []
        lock.unlock()
    }

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler != nil
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func reply(to request: URLRequest) -> OuraStubReply {
        lock.lock()
        recorded.append(request)
        let handler = self.handler
        lock.unlock()
        // No installed handler means the registry outlived its test. Answering with a
        // failure is still better than letting the request reach Oura.
        return handler?(request) ?? OuraStubReply(status: 503, headers: [:], body: Data())
    }
}

private final class OuraGlobalStubURLProtocol: URLProtocol, @unchecked Sendable {
    /// Deliberately matches on host alone rather than on the bearer token: if the token ever
    /// stopped being visible here, a token check would silently let real requests out to
    /// Oura. Nothing else in this bundle uses `URLSession.shared`.
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.ouraring.com" && OuraStubServer.shared.isInstalled
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = OuraStubServer.shared.reply(to: request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: reply.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Every windowed collection answers with an empty page; `personal_info` answers with a
/// profile, because it is not a paginated collection.
private let ouraEmptyCollections: @Sendable (URLRequest) -> OuraStubReply = { request in
    if request.url?.path.hasSuffix("/personal_info") == true {
        return .json(#"{"email":"rider@example.com"}"#)
    }
    return .json(#"{"data":[],"next_token":null}"#)
}

private func ouraArchiveURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HeartSync", isDirectory: true)
        .appendingPathComponent(ReadingArchive.File.ouraDashboard)
}

/// Runs `body` against a configured `OuraManager` whose network, credential and dashboard
/// archive are all stubbed, and restores the archive afterwards whatever happens.
@MainActor
private func withOuraSyncHarness(
    seeded: OuraSnapshot?,
    responding handler: @escaping @Sendable (URLRequest) -> OuraStubReply,
    _ body: @MainActor (OuraManager, HealthStore) async throws -> Void
) async throws {
    let archiveURL = ouraArchiveURL()
    let savedArchive = try? Data(contentsOf: archiveURL)
    // \`ReadingArchive.shared\` has already created its directory. Capture the user's
    // existing test-host cache before clearing it so the harness never destroys real data.
    await ReadingArchive.shared.delete(ReadingArchive.File.ouraDashboard)

    if let seeded {
        await ReadingArchive.shared.write(seeded, to: ReadingArchive.File.ouraDashboard)
    }

    let credential = OuraOAuthCredential(
        accessToken: "stubbed-oura-access-token",
        expiresAt: Date.now.addingTimeInterval(30 * 86_400),
        grantedScopes: Set(OuraOAuthSession.requestedScopes),
        scopeFieldWasReturned: true
    )
    OuraStubServer.shared.install(handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OuraGlobalStubURLProtocol.self]
    let session = URLSession(configuration: configuration)

    defer {
        session.invalidateAndCancel()
        OuraStubServer.shared.uninstall()
        try? FileManager.default.removeItem(at: archiveURL)
        if let savedArchive { try? savedArchive.write(to: archiveURL) }
    }

    let manager = OuraManager(
        archive: .shared,
        urlSession: session,
        credentialForTesting: credential
    )
    let store = HealthStore(persistenceEnabled: false)
    await manager.configure(
        store: store,
        onReadings: { readings, sources, withdrawnIDs in
            store.upsertBatch(
                readings: readings,
                updatingSources: sources,
                removingReadingIDs: withdrawnIDs
            ).committed
        }
    )
    try await body(manager, store)
}

private func ouraQuery(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                      uniquingKeysWith: { first, _ in first })
}

/// The `start_date` a day-windowed collection asked for, as the UTC instant it names.
private func ouraDayQueryStart(_ requests: [URLRequest], path: String) -> Date? {
    guard let url = requests.compactMap(\.url).first(where: { $0.path.hasSuffix(path) }),
          let value = ouraQuery(url)["start_date"]
    else { return nil }
    return OuraClient.parseDay(value)
}

private func ouraTimeQueryStart(_ requests: [URLRequest], path: String) -> Date? {
    guard let url = requests.compactMap(\.url).first(where: { $0.path.hasSuffix(path) }),
          let value = ouraQuery(url)["start_datetime"]
    else { return nil }
    return OuraClient.parseTimestamp(value)
}

private func ouraUTCDayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .gmt
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func ouraIsFailed(_ state: OuraEndpointState) -> Bool {
    if case .failed = state { return true }
    return false
}

// MARK: - Injected-session stubs

/// Thread-safe record of what a stub was asked for.
private final class OuraRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL?) {
        guard let url else { return }
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        urls = []
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.count
    }

    var recorded: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

private func ouraFinish(
    _ protocolInstance: URLProtocol,
    _ client: (any URLProtocolClient)?,
    status: Int,
    headers: [String: String] = [:],
    body: String
) {
    guard let url = protocolInstance.request.url,
          let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Type": "application/json"]) { current, _ in current }
          )
    else {
        client?.urlProtocol(protocolInstance, didFailWithError: URLError(.badServerResponse))
        return
    }
    client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(protocolInstance)
}

/// Always offers another page, so the page walk can only be stopped by the client's ceiling.
private final class OuraEndlessPagesURLProtocol: URLProtocol, @unchecked Sendable {
    static let log = OuraRequestLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.record(request.url)
        ouraFinish(self, client, status: 200, body: #"""
        {"data":[{"id":"stress-page","day":"2026-08-10","day_summary":"restored","recovery_high":7200,"stress_high":1800}],"next_token":"more"}
        """#)
    }

    override func stopLoading() {}
}

/// Two pages and then a nil cursor: a collection that genuinely ends.
private final class OuraTwoPageURLProtocol: URLProtocol, @unchecked Sendable {
    static let log = OuraRequestLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.record(request.url)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cursor = items.first { $0.name == "next_token" }?.value
        if cursor == nil {
            ouraFinish(self, client, status: 200, body: #"""
            {"data":[{"id":"stress-a","day":"2026-08-10","day_summary":"restored","recovery_high":7200,"stress_high":1800}],"next_token":"page-2"}
            """#)
        } else {
            ouraFinish(self, client, status: 200, body: #"""
            {"data":[{"id":"stress-b","day":"2026-08-11","day_summary":"normal","recovery_high":3600,"stress_high":900}],"next_token":null}
            """#)
        }
    }

    override func stopLoading() {}
}

/// Rate-limits every attempt with a short `Retry-After`, so the retry cap is what stops it.
private final class OuraPersistentRateLimitURLProtocol: URLProtocol, @unchecked Sendable {
    static let log = OuraRequestLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.record(request.url)
        ouraFinish(
            self, client,
            status: 429,
            headers: ["Retry-After": "1"],
            body: #"{"status":429,"title":"Too Many Requests","detail":"Rate limit exceeded"}"#
        )
    }

    override func stopLoading() {}
}

/// Asks for a ten-minute wait, which is far longer than one request may hold a sync open.
private final class OuraLongRateLimitURLProtocol: URLProtocol, @unchecked Sendable {
    static let log = OuraRequestLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.record(request.url)
        ouraFinish(
            self, client,
            status: 429,
            headers: ["Retry-After": "600"],
            body: #"{"status":429,"title":"Too Many Requests"}"#
        )
    }

    override func stopLoading() {}
}

/// Limits once, then serves the collection.
private final class OuraRecoveringRateLimitURLProtocol: URLProtocol, @unchecked Sendable {
    static let log = OuraRequestLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.log.record(request.url)
        if Self.log.count == 1 {
            ouraFinish(
                self, client,
                status: 429,
                headers: ["Retry-After": "0"],
                body: #"{"status":429,"title":"Too Many Requests"}"#
            )
        } else {
            ouraFinish(self, client, status: 200, body: #"""
            {"data":[{"id":"stress-a","day":"2026-08-10","day_summary":"restored","recovery_high":7200,"stress_high":1800}],"next_token":null}
            """#)
        }
    }

    override func stopLoading() {}
}
