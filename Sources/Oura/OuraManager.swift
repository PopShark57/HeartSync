import Foundation
import Observation
import OSLog

/// Owns Oura OAuth, token-free dashboard data, per-collection sync state, and scalar
/// mappings that participate in HeartSync's cross-device comparisons.
@MainActor
@Observable
final class OuraManager {

    private let logger = Logger(subsystem: "com.heartsync.HeartSyncChecker", category: "Oura")

    enum Status: Equatable {
        case notConnected
        case authorizing
        case connected(email: String?)
        case error(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        /// Oura account status.
        ///
        /// `.connected` shows the account email when Oura returned one, so only the
        /// fallback is looked up. `.error` carries an already-localized message.
        var title: String {
            switch self {
            case .notConnected:
                String(localized: "oura.status.notConnected", defaultValue: "Not connected", comment: "Oura account status: no saved authorization")
            case .authorizing:
                String(localized: "oura.status.authorizing", defaultValue: "Waiting for Oura…", comment: "Oura account status: the sign-in sheet is open. Oura is a brand name and is not translated.")
            case .connected(let email):
                email ?? String(localized: "oura.status.connected", defaultValue: "Connected", comment: "Oura account status: authorized, but Oura did not report an account email")
            case .error(let message):
                message
            }
        }
    }

    private enum SyncAbort: Error { case authorization }

    private(set) var status: Status = .notConnected
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastSyncSummary: String?
    private(set) var snapshot = OuraSnapshot()
    private(set) var endpointStates = Dictionary(
        uniqueKeysWithValues: OuraEndpoint.allCases.map { ($0, OuraEndpointState.idle) }
    )
    private(set) var endpointIssues: [OuraEndpointIssue] = []

    /// Observable cache of the Keychain credential.
    ///
    /// Keychain remains the source of truth: every write goes there first and this is
    /// re-read from it. The cache exists because the four derived accessors below were each
    /// performing a `SecItemCopyMatching`, a base64 decode, and a JSON decode *per read*,
    /// and the Oura screen reads them dozens of times per body. Worse, a Keychain read is
    /// invisible to Observation, so SwiftUI had no dependency on authorization state at all
    /// and only refreshed because `status` happened to change nearby. As stored state it
    /// drives invalidation properly.
    ///
    /// The bearer token still never leaves memory and Keychain: it is not written to
    /// `OuraSnapshot`, `UserDefaults`, `@AppStorage`, or any archive, and is never logged.
    private(set) var credential: OuraOAuthCredential?

    /// Set when Oura rate-limited this account, so scheduled syncs can wait instead of
    /// walking into the same 429 nineteen more times.
    private(set) var rateLimitedUntil: Date?

    private weak var store: HealthStore?
    private var onReadings: (@MainActor ([Reading], [DataSource], Set<UUID>) -> Bool)?
    private let oauthSession = OuraOAuthSession()
    private let archive: ReadingArchive

    init(archive: ReadingArchive = .shared) {
        self.archive = archive
    }

    /// Page walks that hit the client's ceiling during the sync currently running.
    private var truncationOutcomes: [OuraEndpoint: Bool] = [:]

    /// A full window is re-requested at most this often; between backfills a sync asks only
    /// for days after each collection's high-water mark.
    private static let fullBackfillInterval: TimeInterval = 24 * 3_600

    /// How far before a high-water mark an incremental fetch reaches back. Oura revises
    /// recent documents — a night is re-scored, a workout is relabelled — so a mark is not a
    /// promise that everything before it is final.
    private static let incrementalOverlap: TimeInterval = 2 * 86_400

    /// The longest a rate limit may hold off the scheduled sync.
    private static let maximumRateLimitBackoff: TimeInterval = 30 * 60

    /// Applied when Oura rate-limits without naming a `Retry-After`.
    private static let defaultRateLimitBackoff: TimeInterval = 5 * 60

    /// Credential presence, not validity. `sync()` intentionally processes expiration so
    /// the UI receives an actionable reconnect state.
    var hasAuthorization: Bool { credential != nil }

    var authorizationExpiresAt: Date? { credential?.expiresAt }

    /// Nil means Oura did not report scope metadata, not that every scope was denied.
    var reportedGrantedScopes: Set<String>? {
        guard let credential else { return nil }
        if case .granted(let scopes) = credential.scopeMetadata { return scopes }
        return nil
    }

    var missingRequestedScopes: [String] {
        guard let credential, case .granted = credential.scopeMetadata else { return [] }
        return OuraOAuthSession.requestedScopes.filter {
            !credential.mayAttemptAccess(requiring: $0)
        }
    }

    /// When a scheduled sync may next run. Nil means "now".
    var nextAutomaticSyncAllowedAt: Date? { rateLimitedUntil }

    func state(for endpoint: OuraEndpoint) -> OuraEndpointState {
        endpointStates[endpoint] ?? .idle
    }

    /// Re-reads the Keychain into the observable cache. Called after every write and at the
    /// start of each sync; the equality guard keeps it from waking every observer of this
    /// manager on an unchanged credential.
    @discardableResult
    private func refreshCredentialCache() -> OuraOAuthCredential? {
        let loaded = OuraOAuthCredentialStore.load()
        if loaded != credential { credential = loaded }
        return loaded
    }

    func configure(
        store: HealthStore,
        onReadings: @escaping @MainActor ([Reading], [DataSource], Set<UUID>) -> Bool
    ) async {
        self.store = store
        self.onReadings = onReadings
        snapshot = await archive.read(
            OuraSnapshot.self,
            from: ReadingArchive.File.ouraDashboard
        ) ?? OuraSnapshot()
        restoreEndpointStatesFromSnapshot()
        lastSyncedAt = snapshot.fetchedAt

        // A personal access token from an older build cannot be migrated to OAuth.
        Keychain.delete(.ouraPersonalAccessToken)
        if let credential = refreshCredentialCache(), credential.isValid() {
            status = .connected(email: snapshot.personalInfo?.email)
        } else {
            OuraOAuthCredentialStore.clear()
            refreshCredentialCache()
            status = .notConnected
        }
    }

    // MARK: - OAuth

    func authorize(clientID: String) async {
        let hadCredential = hasAuthorization
        status = .authorizing
        do {
            let credential = try await oauthSession.authorize(clientID: clientID)
            guard OuraOAuthCredentialStore.save(credential) else {
                status = .error("HeartSync could not save the Oura authorization in Keychain.")
                return
            }
            refreshCredentialCache()
            endpointIssues.removeAll()
            for endpoint in OuraEndpoint.allCases { endpointStates[endpoint] = .idle }
            // A reconnect may have changed which scopes are granted, so nothing learned
            // under the previous credential is trusted: the next sync walks the full window
            // and re-checks every collection.
            snapshot.collectionSyncMarks.removeAll()
            snapshot.truncatedCollections.removeAll()
            snapshot.lastFullBackfillAt = nil
            rateLimitedUntil = nil
            status = .connected(email: snapshot.personalInfo?.email)
            upsertSource()
            await sync()
        } catch OuraOAuthSession.Failure.cancelled {
            status = hadCredential ? .connected(email: snapshot.personalInfo?.email) : .notConnected
        } catch let failure as OuraOAuthSession.Failure {
            status = .error(failure.errorDescription ?? "Could not authorize Oura")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func cancelAuthorization() {
        oauthSession.cancel()
        if case .authorizing = status {
            status = hasAuthorization ? .connected(email: snapshot.personalInfo?.email) : .notConnected
        }
    }

    @discardableResult
    func disconnect() -> Bool {
        oauthSession.cancel()
        let accessToken = credential?.accessToken ?? OuraOAuthCredentialStore.load()?.accessToken
        let cleared = OuraOAuthCredentialStore.clear()
        refreshCredentialCache()
        if let accessToken { Task { await OuraOAuthSession.revoke(accessToken: accessToken) } }

        snapshot = OuraSnapshot()
        endpointIssues.removeAll()
        rateLimitedUntil = nil
        for endpoint in OuraEndpoint.allCases { endpointStates[endpoint] = .idle }
        Task { [archive] in await archive.delete(ReadingArchive.File.ouraDashboard) }

        status = cleared
            ? .notConnected
            : .error("HeartSync could not remove the Oura authorization from Keychain.")
        lastSyncedAt = nil
        lastSyncSummary = nil
        return cleared
    }

    /// Removes dashboard/cache records and their normalized readings. Keeping authorization
    /// makes this a resyncable cache clear; removing it is the explicit "forget imported
    /// history" path.
    func clearCachedData(keepingAuthorization: Bool) async -> Bool {
        let ids = Set(Self.scalarReadings(from: snapshot).map(\.id))
        if !ids.isEmpty { _ = store?.remove(readingIDs: ids) }
        snapshot = OuraSnapshot()
        endpointIssues.removeAll()
        truncationOutcomes.removeAll()
        rateLimitedUntil = nil
        lastSyncedAt = nil
        lastSyncSummary = nil
        for endpoint in OuraEndpoint.allCases { endpointStates[endpoint] = .idle }

        var credentialCleared = true
        if !keepingAuthorization {
            credentialCleared = disconnect()
        } else {
            status = hasAuthorization ? .connected(email: nil) : .notConnected
        }
        let cacheDeleted = await archive.delete(ReadingArchive.File.ouraDashboard)
        return credentialCleared && cacheDeleted
    }

    // MARK: - Sync

    /// Runs a scheduled sync unless a rate limit says to wait.
    ///
    /// `sync()` itself stays unconditional so a user who pulls to refresh always gets a real
    /// attempt; this is the entry point for the repeating timer, where walking into the same
    /// 429 every quarter of an hour only deepens the limit.
    func syncIfDue(days: Int = 14) async {
        if let rateLimitedUntil, Date.now < rateLimitedUntil { return }
        await sync(days: days)
    }

    /// Pulls up to two weeks so the dashboard has useful trends while keeping time-series
    /// payloads modest. Every endpoint is independent: cached data survives partial
    /// permission, subscription, decoding, or network failures.
    ///
    /// Requests stay strictly sequential. Endpoint status, 401 classification, partial
    /// permission handling and cached-data preservation are all coupled to that order, so
    /// the cost is reduced by narrowing the window rather than by widening concurrency: each
    /// collection asks only for what followed its high-water mark, with a full window
    /// re-requested once a day and after every reconnect. Responses are merged into the
    /// cache by document id, never assigned over it, so a narrow fetch cannot erase the
    /// fortnight the screen is drawing.
    func sync(days: Int = 14) async {
        guard !isSyncing else { return }
        guard let credential = refreshCredentialCache() else {
            status = .notConnected
            return
        }
        guard credential.isValid() else {
            let cleared = OuraOAuthCredentialStore.clear()
            refreshCredentialCache()
            status = .error(cleared
                ? "Oura authorization expired. Connect your account again."
                : "Oura authorization expired, but HeartSync could not remove it from Keychain.")
            return
        }

        isSyncing = true
        endpointIssues.removeAll()
        truncationOutcomes.removeAll()
        // Cleared up front so a cycle that completes without a 429 lifts the backoff, and
        // one that hits another sets a fresh deadline.
        rateLimitedUntil = nil
        defer {
            isSyncing = false
            resetInterruptedEndpointStates()
        }

        let end = Date.now
        let fullStart = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        // Merging means nothing drops out of the cache on its own any more, so records
        // older than the window are pruned explicitly. The padding matches the day-query
        // padding so a boundary day is not fetched and immediately discarded.
        let cacheCutoff = fullStart.addingTimeInterval(-OuraClient.dayQueryPadding)
        let wantsFullWindow = snapshot.lastFullBackfillAt.map {
            end.timeIntervalSince($0) >= Self.fullBackfillInterval
        } ?? true
        let marks: [String: Date] = wantsFullWindow ? [:] : snapshot.collectionSyncMarks
        let client = OuraClient(accessToken: credential.accessToken)
        var next = snapshot
        var recordCount = 0
        let fullReconciliationWindow = wantsFullWindow
            ? DateInterval(start: fullStart, end: end)
            : nil

        /// The narrowest window that still covers everything this collection may not have.
        func start(_ endpoint: OuraEndpoint) -> Date {
            guard let mark = marks[endpoint.rawValue] else { return fullStart }
            return max(fullStart, mark.addingTimeInterval(-Self.incrementalOverlap))
        }

        do {
            // `personal_info` and `ring_configuration` describe the account and the ring
            // itself. They change when the user edits a profile or sets up a new ring, so a
            // daily refresh is ample and a 15-minute one is pure traffic.
            if shouldRefreshStaticCollection(.personalInfo, now: end, force: wantsFullWindow),
               let value = try await load(.personalInfo, credential: credential, operation: client.personalInfo) {
                next.personalInfo = value
                next.collectionSyncMarks[OuraEndpoint.personalInfo.rawValue] = end
                recordCount += 1
            }
            if let value = try await load(.heartRate, credential: credential, operation: { try await client.heartRate(from: start(.heartRate), to: end) }) {
                next.heartRates = Self.merged(
                    next.heartRates,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.timestamp },
                    date: { OuraClient.parseTimestamp($0.timestamp) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.heartRate.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.dailyActivity, credential: credential, operation: { try await client.dailyActivity(from: start(.dailyActivity), to: end) }) {
                next.activities = Self.merged(
                    next.activities,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.dailyActivity.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.dailyReadiness, credential: credential, operation: { try await client.dailyReadiness(from: start(.dailyReadiness), to: end) }) {
                next.readiness = Self.merged(
                    next.readiness,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.dailyReadiness.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.dailySleep, credential: credential, operation: { try await client.dailySleep(from: start(.dailySleep), to: end) }) {
                next.sleepScores = Self.merged(
                    next.sleepScores,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.dailySleep.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.detailedSleep, credential: credential, operation: { try await client.sleep(from: start(.detailedSleep), to: end) }) {
                next.sleeps = Self.merged(
                    next.sleeps,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.bedtime_end) ?? OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.detailedSleep.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.sleepTime, credential: credential, operation: { try await client.sleepTime(from: start(.sleepTime), to: end) }) {
                next.sleepTimes = Self.merged(
                    next.sleepTimes,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.sleepTime.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.dailySpO2, credential: credential, operation: { try await client.dailySpO2(from: start(.dailySpO2), to: end) }) {
                next.oxygen = Self.merged(
                    next.oxygen,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.dailySpO2.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.dailyStress, credential: credential, operation: { try await client.dailyStress(from: start(.dailyStress), to: end) }) {
                next.stress = Self.merged(
                    next.stress,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.dailyStress.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.dailyResilience, credential: credential, operation: { try await client.dailyResilience(from: start(.dailyResilience), to: end) }) {
                next.resilience = Self.merged(
                    next.resilience,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.dailyResilience.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.cardiovascularAge, credential: credential, operation: { try await client.dailyCardiovascularAge(from: start(.cardiovascularAge), to: end) }) {
                next.cardiovascularAge = Self.merged(
                    next.cardiovascularAge,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.cardiovascularAge.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.vo2Max, credential: credential, operation: { try await client.vo2Max(from: start(.vo2Max), to: end) }) {
                next.vo2Max = Self.merged(
                    next.vo2Max,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.timestamp) ?? OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.vo2Max.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.workouts, credential: credential, operation: { try await client.workouts(from: start(.workouts), to: end) }) {
                next.workouts = Self.merged(
                    next.workouts,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.start_datetime) ?? OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.workouts.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.sessions, credential: credential, operation: { try await client.sessions(from: start(.sessions), to: end) }) {
                next.sessions = Self.merged(
                    next.sessions,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.start_datetime) ?? OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.sessions.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.tags, credential: credential, operation: { try await client.tags(from: start(.tags), to: end) }) {
                next.tags = Self.merged(
                    next.tags,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.timestamp) ?? OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.tags.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.enhancedTags, credential: credential, operation: { try await client.enhancedTags(from: start(.enhancedTags), to: end) }) {
                next.enhancedTags = Self.merged(
                    next.enhancedTags,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.start_time) ?? OuraClient.parseDay($0.start_day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.enhancedTags.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.restMode, credential: credential, operation: { try await client.restModePeriods(from: start(.restMode), to: end) }) {
                next.restModePeriods = Self.merged(
                    next.restModePeriods,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.start_time) ?? OuraClient.parseDay($0.start_day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.restMode.rawValue] = end
                recordCount += value.count
            }
            if let value = try await load(.ringBattery, credential: credential, operation: { try await client.ringBatteryLevels(from: start(.ringBattery), to: end) }) {
                next.batteryLevels = Self.merged(
                    next.batteryLevels,
                    with: value.records,
                    keepAfter: cacheCutoff,
                    id: { String($0.timestamp_unix) },
                    date: { Date(timeIntervalSince1970: TimeInterval($0.timestamp_unix) / 1_000) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                )
                next.collectionSyncMarks[OuraEndpoint.ringBattery.rawValue] = end
                recordCount += value.count
            }
            // Unwindowed, so the response is the whole collection and replacing is correct.
            if shouldRefreshStaticCollection(.ringConfiguration, now: end, force: wantsFullWindow),
               let value = try await load(.ringConfiguration, credential: credential, operation: client.ringConfigurations) {
                next.ringConfigurations = value.records
                next.collectionSyncMarks[OuraEndpoint.ringConfiguration.rawValue] = end
                recordCount += value.count
            }
        } catch SyncAbort.authorization {
            return
        } catch {
            logger.error("Unexpected Oura sync abort: \(error.localizedDescription, privacy: .public)")
            return
        }

        // A truncation flag is only cleared by a full-window pass: an incremental fetch that
        // fitted in one page says nothing about the cached history behind it.
        for (endpoint, wasTruncated) in truncationOutcomes {
            if wasTruncated {
                next.truncatedCollections.insert(endpoint.rawValue)
            } else if wantsFullWindow {
                next.truncatedCollections.remove(endpoint.rawValue)
            }
        }
        if wantsFullWindow { next.lastFullBackfillAt = end }

        let readings = Self.readings(fromHeartRate: next.heartRates)
            + Self.readings(fromSleep: next.sleeps)
            + Self.readings(fromSpO2: next.oxygen)
            + Self.readings(fromVO2Max: next.vo2Max)

        next.fetchedAt = .now
        let previousSnapshot = snapshot
        let previousReadings = Self.scalarReadings(from: previousSnapshot)
        let cacheWritten = await archive.write(next, to: ReadingArchive.File.ouraDashboard)
        guard cacheWritten else {
            status = .error("Oura returned data, but HeartSync could not save the cache. The previous dashboard and comparison readings were kept.")
            lastSyncSummary = "Sync not committed: local Oura cache write failed"
            logger.error("Oura sync received data but the cache write failed")
            return
        }
        let withdrawnIDs = Set(previousReadings.map(\.id)).subtracting(Set(readings.map(\.id)))
        let source = sourceDescriptor(from: next, battery: next.latestBatteryLevel?.level)
        guard onReadings?(readings, [source], withdrawnIDs) == true else {
            let cacheRolledBack = await archive.write(
                previousSnapshot,
                to: ReadingArchive.File.ouraDashboard
            )
            truncationOutcomes.removeAll()
            restoreEndpointStatesFromSnapshot()
            status = .error(cacheRolledBack
                ? "Oura returned data, but HeartSync could not commit it to the health database. The previous Oura cache was restored."
                : "Oura returned data, but neither the health database nor the previous Oura cache could be confirmed. Retry before relying on this sync.")
            lastSyncSummary = "Sync not committed: local health database write failed"
            logger.error("Oura cache was written, but the database batch failed; cache rollback: \(cacheRolledBack, privacy: .public)")
            return
        }

        snapshot = next
        lastSyncedAt = next.fetchedAt

        status = .connected(email: next.personalInfo?.email)
        // An incremental cycle fetches only what changed, so "0 records" there means
        // "nothing new", not "nothing held". Say which of the two the number is.
        let noun = wantsFullWindow ? "Oura record" : "new Oura record"
        if endpointIssues.isEmpty {
            lastSyncSummary = "\(recordCount) \(noun)\(recordCount == 1 ? "" : "s")"
        } else {
            // A truncated collection returned data but not all of it, which is a different
            // claim from a collection that returned nothing. Each truncated endpoint raises
            // exactly one issue, so the two counts partition `endpointIssues`.
            let incomplete = truncationOutcomes.values.filter { $0 }.count
            let unavailable = endpointIssues.count - incomplete
            var parts = ["\(recordCount) \(noun)\(recordCount == 1 ? "" : "s")"]
            if unavailable > 0 {
                parts.append("\(unavailable) unavailable collection\(unavailable == 1 ? "" : "s")")
            }
            if incomplete > 0 {
                parts.append("\(incomplete) incomplete collection\(incomplete == 1 ? "" : "s")")
            }
            lastSyncSummary = parts.joined(separator: ", ")
            logger.warning("Oura partial sync: \(self.endpointIssues.map(\.message).joined(separator: "; "), privacy: .public)")
        }
    }

    private func load<T: Sendable>(
        _ endpoint: OuraEndpoint,
        credential: OuraOAuthCredential,
        operation: () async throws -> T
    ) async throws -> T? {
        // Deliberately no pre-emptive scope check. The callback's scope list is
        // corroborating evidence, never grounds to skip a request: Oura's published scope
        // names are incomplete (`heart_health`, `stress` and `ring_configuration` are
        // absent from the documented set) and it has answered a `spo2` request with
        // `spo2Daily`. A name this app fails to match must not hide data the user granted,
        // so Oura is asked and only Oura's answer marks a collection unavailable.
        endpointStates[endpoint] = .syncing
        do {
            let result = try await operation()
            let count = (result as? any Collection)?.count ?? 1
            // Truncation travels with the response so a prefix is never advertised as the
            // whole collection. `load` is generic over the record type, so the flag is read
            // through an existential.
            let wasTruncated = (result as? any OuraTruncatableResult)?.isTruncated ?? false
            truncationOutcomes[endpoint] = wasTruncated
            if wasTruncated {
                let message = "\(endpoint.title): Oura has more records than one sync can page through. This collection is incomplete."
                endpointStates[endpoint] = .partial(count)
                endpointIssues.append(OuraEndpointIssue(
                    endpoint: endpoint,
                    message: message,
                    isPermissionIssue: false
                ))
            } else {
                endpointStates[endpoint] = .available(count)
            }
            return result
        } catch {
            noteRateLimitIfNeeded(error)
            // Oura currently returns HTTP 401 (rather than 403) when a valid token lacks
            // newer scopes such as `heart_health`. That is an endpoint permission issue,
            // not an invalid bearer token, so keep the account and continue the sync.
            // A 401 whose detail does not spell out "scope" would otherwise fall through
            // to handleAuthorizationFailure and clear the whole credential. When the
            // callback already told us this scope was withheld, that reading is wrong:
            // declining one permission must not sign the account out.
            let scopeWithheldByCallback = endpoint.requiredScope
                .map { !credential.mayAttemptAccess(requiring: $0) } ?? false
            if Self.isScopePermissionFailure(error)
                || (scopeWithheldByCallback && Self.isUnauthorized(error)) {
                let message = Self.describe(error, endpoint: endpoint.title)
                endpointStates[endpoint] = .permissionMissing
                endpointIssues.append(OuraEndpointIssue(
                    endpoint: endpoint,
                    message: message,
                    isPermissionIssue: true
                ))
                return nil
            }
            if handleAuthorizationFailure(error) {
                // The credential has just been cleared, so no later sync will revisit this
                // endpoint. Leaving it on `.syncing` would spin forever on a request that
                // has already failed; record the failure before unwinding.
                let message = Self.describe(error, endpoint: endpoint.title)
                endpointStates[endpoint] = .failed(message)
                endpointIssues.append(OuraEndpointIssue(
                    endpoint: endpoint,
                    message: message,
                    isPermissionIssue: false
                ))
                throw SyncAbort.authorization
            }
            let message = Self.describe(error, endpoint: endpoint.title)
            let isPermissionIssue: Bool
            if let failure = error as? OuraClient.Failure, case .forbidden = failure {
                isPermissionIssue = true
            } else {
                isPermissionIssue = false
            }
            endpointStates[endpoint] = .failed(message)
            endpointIssues.append(OuraEndpointIssue(
                endpoint: endpoint,
                message: message,
                isPermissionIssue: isPermissionIssue
            ))
            return nil
        }
    }

    /// Holds off the scheduled sync after a rate limit that `OuraClient` could not absorb.
    ///
    /// The client retries only short waits inline; anything longer arrives here. With 19
    /// sequential requests per cycle, retrying the whole cycle on the usual 15-minute
    /// cadence would keep the account limited, so the deadline Oura asked for is honoured —
    /// capped, because an absurd `Retry-After` must not silently disable syncing.
    private func noteRateLimitIfNeeded(_ error: any Error) {
        guard let failure = error as? OuraClient.Failure,
              case .rateLimited(let retryAfter, _) = failure
        else { return }
        let requested = retryAfter.map { TimeInterval($0) } ?? Self.defaultRateLimitBackoff
        let wait = min(max(requested, 0), Self.maximumRateLimitBackoff)
        let deadline = Date.now.addingTimeInterval(wait)
        rateLimitedUntil = max(rateLimitedUntil ?? deadline, deadline)
    }

    /// Any endpoint still marked `.syncing` when the sync stops is not in flight — nothing
    /// is running. `.idle` reads as "not attempted", which is the truth; a spinner that
    /// never resolves is not.
    private func resetInterruptedEndpointStates() {
        for (endpoint, state) in endpointStates where state == .syncing {
            endpointStates[endpoint] = .idle
        }
    }

    /// Whether an account-level collection is due. Cached data and its endpoint state are
    /// left untouched when it is not, so skipping shows as the previous result rather than
    /// as a collection that was never fetched.
    private func shouldRefreshStaticCollection(
        _ endpoint: OuraEndpoint,
        now: Date,
        force: Bool
    ) -> Bool {
        if force { return true }
        guard let mark = snapshot.collectionSyncMarks[endpoint.rawValue] else { return true }
        return now.timeIntervalSince(mark) >= Self.fullBackfillInterval
    }

    /// Folds a freshly fetched window into the cached collection.
    ///
    /// An incremental sync deliberately asks for a narrow window, so assigning the response
    /// over the cached array — what the full-window sync used to do — would erase the rest
    /// of the fortnight the dashboard is drawing. Records are matched on Oura's own document
    /// id, which is the same identity `Reading` ids are derived from, and the newest copy
    /// wins so a corrected document replaces rather than duplicates.
    ///
    /// Because nothing falls out of a merged cache on its own, records older than
    /// `keepAfter` are dropped here; a record whose date cannot be parsed is kept rather
    /// than silently discarded, since an unreadable timestamp is not evidence of age.
    nonisolated static func merged<T>(
        _ cached: [T],
        with fetched: [T],
        keepAfter: Date,
        id: (T) -> String,
        date: (T) -> Date?,
        reconcileWindow: DateInterval? = nil
    ) -> [T] {
        var byID: [String: T] = Dictionary(minimumCapacity: cached.count + fetched.count)
        var order: [String] = []
        order.reserveCapacity(cached.count + fetched.count)
        let fetchedIDs = Set(fetched.map(id))
        for record in cached {
            let key = id(record)
            if let reconcileWindow,
               let stamp = date(record),
               reconcileWindow.contains(stamp),
               !fetchedIDs.contains(key) {
                continue
            }
            if byID.updateValue(record, forKey: key) == nil { order.append(key) }
        }
        for record in fetched {
            let key = id(record)
            if byID.updateValue(record, forKey: key) == nil { order.append(key) }
        }

        return order
            .compactMap { byID[$0] }
            .filter { record in
                guard let stamp = date(record) else { return true }
                return stamp >= keepAfter
            }
            .sorted { (date($0) ?? .distantPast) < (date($1) ?? .distantPast) }
    }

    private static func describe(_ error: any Error, endpoint: String) -> String {
        if let failure = error as? OuraClient.Failure {
            return "\(endpoint): \(failure.errorDescription ?? "failed")"
        }
        return "\(endpoint): \(error.localizedDescription)"
    }

    nonisolated static func isUnauthorized(_ error: any Error) -> Bool {
        guard let failure = error as? OuraClient.Failure, case .unauthorized = failure
        else { return false }
        return true
    }

    nonisolated static func isScopePermissionFailure(_ error: any Error) -> Bool {
        guard let failure = error as? OuraClient.Failure,
              case .unauthorized(let detail) = failure,
              let detail = detail?.lowercased()
        else { return false }
        return detail.contains("scope")
            && (detail.contains("not authorized")
                || detail.contains("unauthorized")
                || detail.contains("permission"))
    }

    /// A non-scope 401 applies to the bearer token rather than one collection. Clear it once
    /// instead of making the remaining requests fail in the same way.
    private func handleAuthorizationFailure(_ error: any Error) -> Bool {
        guard let failure = error as? OuraClient.Failure,
              case .unauthorized(let detail) = failure
        else { return false }
        let cleared = OuraOAuthCredentialStore.clear()
        refreshCredentialCache()
        status = .error(cleared
            ? (detail ?? failure.errorDescription ?? "Oura authorization failed")
            : "Oura rejected the authorization, but HeartSync could not remove it from Keychain.")
        return true
    }

    private func sourceDescriptor(from snapshot: OuraSnapshot, battery: Int? = nil) -> DataSource {
        DataSource(
            id: DataSource.ouraSourceID,
            displayName: "Oura Ring",
            transport: .oura,
            model: snapshot.currentRing.map { ring in
                [ring.hardware_type, ring.design]
                    .compactMap { $0?.replacingOccurrences(of: "_", with: " ").capitalized }
                    .joined(separator: " ")
            } ?? "Oura Cloud API v2 (OAuth)",
            lastSeenAt: snapshot.fetchedAt ?? .now,
            batteryPercent: battery,
            upstreamDeviceRelationshipID: "oura.account.default"
        )
    }

    private func upsertSource(battery: Int? = nil) {
        store?.upsert(sourceDescriptor(from: snapshot, battery: battery))
    }

    private func restoreEndpointStatesFromSnapshot() {
        for endpoint in OuraEndpoint.allCases { endpointStates[endpoint] = .idle }
        guard snapshot.fetchedAt != nil else { return }
        endpointStates[.personalInfo] = snapshot.personalInfo == nil ? .idle : cachedState(.personalInfo, 1)
        endpointStates[.heartRate] = cachedState(.heartRate, snapshot.heartRates.count)
        endpointStates[.dailyActivity] = cachedState(.dailyActivity, snapshot.activities.count)
        endpointStates[.dailyReadiness] = cachedState(.dailyReadiness, snapshot.readiness.count)
        endpointStates[.dailySleep] = cachedState(.dailySleep, snapshot.sleepScores.count)
        endpointStates[.detailedSleep] = cachedState(.detailedSleep, snapshot.sleeps.count)
        endpointStates[.sleepTime] = cachedState(.sleepTime, snapshot.sleepTimes.count)
        endpointStates[.dailySpO2] = cachedState(.dailySpO2, snapshot.oxygen.count)
        endpointStates[.dailyStress] = cachedState(.dailyStress, snapshot.stress.count)
        endpointStates[.dailyResilience] = cachedState(.dailyResilience, snapshot.resilience.count)
        endpointStates[.cardiovascularAge] = cachedState(.cardiovascularAge, snapshot.cardiovascularAge.count)
        endpointStates[.vo2Max] = cachedState(.vo2Max, snapshot.vo2Max.count)
        endpointStates[.workouts] = cachedState(.workouts, snapshot.workouts.count)
        endpointStates[.sessions] = cachedState(.sessions, snapshot.sessions.count)
        endpointStates[.tags] = cachedState(.tags, snapshot.tags.count)
        endpointStates[.enhancedTags] = cachedState(.enhancedTags, snapshot.enhancedTags.count)
        endpointStates[.restMode] = cachedState(.restMode, snapshot.restModePeriods.count)
        endpointStates[.ringBattery] = cachedState(.ringBattery, snapshot.batteryLevels.count)
        endpointStates[.ringConfiguration] = cachedState(.ringConfiguration, snapshot.ringConfigurations.count)
    }

    #if DEBUG
    func injectPartialFailureForUITesting() {
        let now = Date.now
        snapshot = OuraSnapshot()
        snapshot.fetchedAt = now
        snapshot.heartRates = [
            OuraClient.HeartRatePoint(
                bpm: 62,
                source: "rest",
                timestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))
            ),
        ]
        status = .connected(email: "demo@example.com")
        endpointStates[.heartRate] = .available(1)
        endpointStates[.dailyStress] = .failed("Simulated endpoint failure")
        endpointIssues = [
            OuraEndpointIssue(
                endpoint: .dailyStress,
                message: "Stress was unavailable; cached Oura data was kept.",
                isPermissionIssue: false
            ),
        ]
        lastSyncSummary = "1 collection unavailable"
    }
    #endif

    /// A relaunch must not upgrade a cached prefix into a complete collection, so the
    /// persisted truncation flag decides which state the cache is restored as.
    private func cachedState(_ endpoint: OuraEndpoint, _ count: Int) -> OuraEndpointState {
        snapshot.truncatedCollections.contains(endpoint.rawValue) ? .partial(count) : .available(count)
    }

    // MARK: - Scalar mapping into the shared comparison store

    nonisolated private static let source = DataSource.ouraSourceID

    nonisolated static func readings(fromHeartRate points: [OuraClient.HeartRatePoint]) -> [Reading] {
        points.compactMap { point in
            guard let timestamp = OuraClient.parseTimestamp(point.timestamp) else { return nil }
            return Reading(
                id: UUID(stableFrom: "oura.hr.\(point.timestamp)"),
                sourceID: source,
                kind: .heartRate,
                value: Double(point.bpm),
                start: timestamp,
                provenance: .measured
            )
        }
    }

    nonisolated static func readings(fromSleep documents: [OuraClient.SleepDocument]) -> [Reading] {
        documents.flatMap { document -> [Reading] in
            let start = OuraClient.parseTimestamp(document.bedtime_start)
                ?? OuraClient.parseDay(document.day)
            guard let start else { return [] }
            let end = OuraClient.parseTimestamp(document.bedtime_end) ?? start

            var result: [Reading] = []
            func add(_ kind: MetricKind, _ value: Double?, _ tag: String) {
                guard let value else { return }
                result.append(Reading(
                    id: UUID(stableFrom: "oura.sleep.\(document.id).\(tag)"),
                    sourceID: source,
                    kind: kind,
                    value: value,
                    start: start,
                    end: end,
                    provenance: .measured
                ))
            }
            // Oura average HRV is RMSSD-based and must not be compared against SDNN.
            add(.hrvRMSSD, document.average_hrv, "hrv")
            add(.restingHeartRate, document.lowest_heart_rate, "rhr")
            add(.heartRate, document.average_heart_rate, "avghr")
            add(.respiratoryRate, document.average_breath, "breath")
            return result
        }
    }

    nonisolated static func readings(fromSpO2 documents: [OuraClient.DailySpO2]) -> [Reading] {
        documents.compactMap { document in
            guard let average = document.spo2_percentage?.average,
                  let day = OuraClient.parseDay(document.day)
            else { return nil }
            return Reading(
                id: UUID(stableFrom: "oura.spo2.\(document.id)"),
                sourceID: source,
                kind: .spo2,
                value: average,
                start: day,
                end: day.addingTimeInterval(86_400),
                provenance: .measured
            )
        }
    }

    nonisolated static func readings(fromVO2Max documents: [OuraClient.VO2MaxDocument]) -> [Reading] {
        documents.compactMap { document in
            guard let value = document.vo2_max else { return nil }
            let date = OuraClient.parseTimestamp(document.timestamp) ?? OuraClient.parseDay(document.day)
            guard let date else { return nil }
            return Reading(
                id: UUID(stableFrom: "oura.vo2.\(document.id)"),
                sourceID: source,
                kind: .vo2Max,
                value: value,
                start: date,
                provenance: .measured
            )
        }
    }

    nonisolated private static func scalarReadings(from snapshot: OuraSnapshot) -> [Reading] {
        readings(fromHeartRate: snapshot.heartRates)
            + readings(fromSleep: snapshot.sleeps)
            + readings(fromSpO2: snapshot.oxygen)
            + readings(fromVO2Max: snapshot.vo2Max)
    }
}
