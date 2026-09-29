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

    private enum SyncAbort: Error {
        case authorization
        /// Oura asked HeartSync to wait and the client could not absorb the wait inline.
        /// The rest of the cycle is skipped, and what was fetched before it is still kept.
        case rateLimited
        /// A clear cancelled this cycle. Nothing it fetched is written anywhere.
        case superseded
    }

    /// The cycle running now, so a clear can cancel it and wait for it to stop before it
    /// deletes anything (improvement 47).
    private var syncTask: Task<Void, Never>?
    /// Advanced by every clear. A cycle remembers the value it started under and writes
    /// neither the cache nor the database once it has moved: it worked on a copy of the
    /// dashboard taken before the clear, and writing that copy back would restore history
    /// the user just removed.
    private var dataEpoch = 0
    /// True while a clear runs. No cycle starts then.
    private(set) var isClearing = false

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
    /// The deadline installed by the cycle running now, if it met a 429. A cycle lifts a
    /// backoff only by finishing without one; starting a cycle does not.
    private var cycleRateLimit: Date?

    private weak var store: HealthStore?
    private var onReadings: (@MainActor ([Reading], [DataSource], Set<UUID>) -> Bool)?
    private let oauthSession = OuraOAuthSession()
    private let archive: ReadingArchive
    private let urlSession: URLSession

    /// Production uses Keychain. Tests use an in-memory credential so an unsigned simulator
    /// host can exercise the complete sync state machine without weakening credential
    /// storage or depending on a Keychain entitlement that CI deliberately does not sign.
    private enum CredentialStorage {
        case keychain
        case memory(OuraOAuthCredential?)
        case scripted(ScriptedCredentialStore)
    }
    private var credentialStorage: CredentialStorage

    /// A credential store whose reads a test scripts, to exercise the difference between
    /// "nothing stored" and "Keychain could not be read right now" without a locked device.
    final class ScriptedCredentialStore {
        var load: OuraOAuthCredentialStore.Load
        private(set) var clearCount = 0

        init(_ load: OuraOAuthCredentialStore.Load) { self.load = load }

        func noteCleared() {
            clearCount += 1
            load = .absent
        }
    }

    /// Set while the stored credential could not be read, and nil once a read succeeds. The
    /// credential may still exist, so this is never a reason to clear it or to report the
    /// account as disconnected.
    private(set) var credentialReadIssue: String?

    init(archive: ReadingArchive = .shared, urlSession: URLSession = .shared) {
        self.archive = archive
        self.urlSession = urlSession
        credentialStorage = .keychain
    }

    /// Narrow test seam for a Keychain that can be made to fail.
    init(archive: ReadingArchive, urlSession: URLSession, scriptedCredentials: ScriptedCredentialStore) {
        self.archive = archive
        self.urlSession = urlSession
        credentialStorage = .scripted(scriptedCredentials)
    }

    /// Narrow test seam for deterministic Oura orchestration tests.
    init(
        archive: ReadingArchive,
        urlSession: URLSession,
        credentialForTesting: OuraOAuthCredential
    ) {
        self.archive = archive
        self.urlSession = urlSession
        credentialStorage = .memory(credentialForTesting)
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

    /// Whether an authorization may exist: one is cached, or the Keychain could not be read
    /// and so cannot say. Schedulers use this, so a locked device does not stop syncing from
    /// ever being retried.
    var mayHaveAuthorization: Bool { credential != nil || credentialReadIssue != nil }

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
        switch readStoredCredential() {
        case .credential(let loaded):
            if loaded != credential { credential = loaded }
            credentialReadIssue = nil
            return loaded
        case .absent, .unusable:
            if credential != nil { credential = nil }
            credentialReadIssue = nil
            return nil
        case .unavailable:
            // Keychain could not be read; the credential may exist. Keep what is cached and
            // say why nothing newer is known, rather than treating a locked device as a
            // signed-out account.
            credentialReadIssue = Self.credentialUnavailableMessage
            return credential
        }
    }

    private static let credentialUnavailableMessage =
        "HeartSync could not read your Oura authorization from Keychain just now, for example because the device is locked. It will try again."

    private func readStoredCredential() -> OuraOAuthCredentialStore.Load {
        switch credentialStorage {
        case .keychain:
            OuraOAuthCredentialStore.read()
        case .memory(let credential):
            credential.map { .credential($0) } ?? .absent
        case .scripted(let scripted):
            scripted.load
        }
    }

    private func storedCredential() -> OuraOAuthCredential? {
        if case .credential(let credential) = readStoredCredential() { return credential }
        return nil
    }

    @discardableResult
    private func saveStoredCredential(_ credential: OuraOAuthCredential) -> Bool {
        switch credentialStorage {
        case .keychain:
            return OuraOAuthCredentialStore.save(credential)
        case .memory:
            credentialStorage = .memory(credential)
            return true
        case .scripted(let scripted):
            scripted.load = .credential(credential)
            return true
        }
    }

    @discardableResult
    private func clearStoredCredential() -> Bool {
        switch credentialStorage {
        case .keychain:
            return OuraOAuthCredentialStore.clear()
        case .memory:
            credentialStorage = .memory(nil)
            return true
        case .scripted(let scripted):
            scripted.noteCleared()
            return true
        }
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
        let stored = readStoredCredential()
        refreshCredentialCache()
        switch stored {
        case .credential(let credential) where credential.isValid():
            status = .connected(email: snapshot.personalInfo?.email)
        case .unavailable:
            // Not a verdict on the credential. Clearing here would sign the user out of an
            // account because the device happened to be locked; leave it alone and retry.
            status = .error(Self.credentialUnavailableMessage)
        case .credential, .absent, .unusable:
            // Expired, absent, or undecodable: there is nothing usable to keep.
            clearStoredCredential()
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
            guard saveStoredCredential(credential) else {
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
        // A cycle in flight belongs to the account being removed; it must not write its
        // copy of the dashboard back afterwards.
        dataEpoch &+= 1
        syncTask?.cancel()
        let accessToken = credential?.accessToken ?? storedCredential()?.accessToken
        let cleared = clearStoredCredential()
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
        // A cycle that began before this clear must not finish after it. It is cancelled
        // and awaited first; its own epoch check keeps it from writing on the way out.
        isClearing = true
        defer { isClearing = false }
        dataEpoch &+= 1
        if let syncTask {
            syncTask.cancel()
            await syncTask.value
        }
        // Every Oura reading, not only those the 14-day dashboard cache still holds: stored
        // readings now outlive the cache, so its contents no longer name them all.
        _ = store?.removeReadings(forSource: DataSource.ouraSourceID)
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
    ///
    /// - Parameter minimumInterval: skips when the last committed sync is more recent than
    ///   this. Foreground returns pass the scheduled interval, so opening the app twice in a
    ///   minute does not repeat a full cycle of requests.
    func syncIfDue(days: Int = 14, minimumInterval: TimeInterval = 0) async {
        if let rateLimitedUntil, Date.now < rateLimitedUntil { return }
        if minimumInterval > 0, let lastSyncedAt,
           Date.now.timeIntervalSince(lastSyncedAt) < minimumInterval {
            return
        }
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
        // A second caller waits for the cycle already running rather than starting another.
        if let syncTask {
            await syncTask.value
            return
        }
        guard !isClearing else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performSync(days: days)
        }
        syncTask = task
        await task.value
        if syncTask == task { syncTask = nil }
    }

    private func performSync(days: Int) async {
        guard !isSyncing, !isClearing else { return }
        let epoch = dataEpoch
        guard let credential = refreshCredentialCache() else {
            status = credentialReadIssue.map { .error($0) } ?? .notConnected
            return
        }
        guard credential.isValid() else {
            let cleared = clearStoredCredential()
            refreshCredentialCache()
            status = .error(cleared
                ? "Oura authorization expired. Connect your account again."
                : "Oura authorization expired, but HeartSync could not remove it from Keychain.")
            return
        }

        isSyncing = true
        endpointIssues.removeAll()
        truncationOutcomes.removeAll()
        // The backoff stays in force while the cycle runs. It is lifted when the cycle ends
        // without meeting another 429, not when it starts: an explicit sync inside a backoff
        // is still an attempt, but one that fails again must not have erased the deadline.
        cycleRateLimit = nil
        defer {
            isSyncing = false
            rateLimitedUntil = cycleRateLimit
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
        let client = OuraClient(accessToken: credential.accessToken, session: urlSession)
        var next = snapshot
        var recordCount = 0
        var pausedByRateLimit = false
        let fullReconciliationWindow = wantsFullWindow
            ? DateInterval(start: fullStart, end: end)
            : nil
        /// Readings whose documents Oura itself dropped: cached, dated inside the window that
        /// a complete full-window response covered, and absent from that response. This is
        /// the only evidence of withdrawal. A document that merely aged out of the 14-day
        /// dashboard cache is not withdrawn, and its stored readings belong to retention.
        var withdrawn: [Reading] = []

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
                withdrawn += Self.readings(fromHeartRate: Self.withdrawn(
                    next.heartRates,
                    fetched: value.records,
                    id: { $0.timestamp },
                    date: { OuraClient.parseTimestamp($0.timestamp) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                ))
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
                withdrawn += Self.readings(fromSleep: Self.withdrawn(
                    next.sleeps,
                    fetched: value.records,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.bedtime_end) ?? OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                ))
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
                withdrawn += Self.readings(fromSpO2: Self.withdrawn(
                    next.oxygen,
                    fetched: value.records,
                    id: { $0.id },
                    date: { OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                ))
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
                withdrawn += Self.readings(fromVO2Max: Self.withdrawn(
                    next.vo2Max,
                    fetched: value.records,
                    id: { $0.id },
                    date: { OuraClient.parseTimestamp($0.timestamp) ?? OuraClient.parseDay($0.day) },
                    reconcileWindow: value.isTruncated ? nil : fullReconciliationWindow
                ))
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
        } catch SyncAbort.superseded {
            return
        } catch SyncAbort.rateLimited {
            // Keep what earlier collections returned; the rest waits for the backoff.
            pausedByRateLimit = true
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
        // A cycle cut short by a rate limit did not cover the window, so it is not a backfill.
        if wantsFullWindow, !pausedByRateLimit { next.lastFullBackfillAt = end }

        let readings = Self.readings(fromHeartRate: next.heartRates)
            + Self.readings(fromSleep: next.sleeps)
            + Self.readings(fromSpO2: next.oxygen)
            + Self.readings(fromVO2Max: next.vo2Max)

        next.fetchedAt = .now
        // A clear since this cycle started: `next` is a copy from before it.
        guard epoch == dataEpoch, !Task.isCancelled else { return }
        let previousSnapshot = snapshot
        let cacheWritten = await archive.write(next, to: ReadingArchive.File.ouraDashboard)
        // The clear waits for this cycle, so it deletes the file after this write lands.
        guard epoch == dataEpoch else { return }
        guard cacheWritten else {
            status = .error("Oura returned data, but HeartSync could not save the cache. The previous dashboard and comparison readings were kept.")
            lastSyncSummary = "Sync not committed: local Oura cache write failed"
            logger.error("Oura sync received data but the cache write failed")
            return
        }
        let withdrawnIDs = Set(withdrawn.map(\.id)).subtracting(Set(readings.map(\.id)))
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
        let recordSummary = Self.recordSummary(count: recordCount, isFullWindow: wantsFullWindow)
        if endpointIssues.isEmpty {
            lastSyncSummary = recordSummary
        } else {
            // A truncated collection returned data but not all of it, which is a different
            // claim from a collection that returned nothing. Each truncated endpoint raises
            // exactly one issue, so the two counts partition `endpointIssues`.
            let incomplete = truncationOutcomes.values.filter { $0 }.count
            let unavailable = endpointIssues.count - incomplete
            var parts = [recordSummary]
            if unavailable > 0 {
                parts.append(String(
                    localized: "oura.summary.unavailable",
                    defaultValue: "\(unavailable) unavailable collections",
                    comment: "Oura sync summary fragment. The argument is how many collections could not be read."
                ))
            }
            if incomplete > 0 {
                parts.append(String(
                    localized: "oura.summary.incomplete",
                    defaultValue: "\(incomplete) incomplete collections",
                    comment: "Oura sync summary fragment. The argument is how many collections returned only part of their records."
                ))
            }
            if pausedByRateLimit {
                parts.append(String(
                    localized: "oura.summary.rateLimited",
                    defaultValue: "paused by an Oura rate limit",
                    comment: "Oura sync summary fragment: Oura asked HeartSync to wait, so the rest of the sync was skipped"
                ))
            }
            lastSyncSummary = ListFormatter.localizedString(byJoining: parts)
            logger.warning("Oura partial sync: \(self.endpointIssues.map(\.message).joined(separator: "; "), privacy: .public)")
        }
    }

    /// "12 Oura records" after a full-window sync, "3 new Oura records" after an incremental
    /// one, where zero means "nothing new" rather than "nothing held".
    nonisolated static func recordSummary(count: Int, isFullWindow: Bool) -> String {
        if isFullWindow {
            return String(
                localized: "oura.summary.records.full",
                defaultValue: "\(count) Oura records",
                comment: "Oura sync summary after a full-window sync. The argument is how many records were received."
            )
        }
        return String(
            localized: "oura.summary.records.new",
            defaultValue: "\(count) new Oura records",
            comment: "Oura sync summary after an incremental sync. The argument is how many new records were received."
        )
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
        guard !Task.isCancelled else { throw SyncAbort.superseded }
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
            // A cancelled request is a clear, not an endpoint failure.
            if Task.isCancelled {
                endpointStates[endpoint] = .idle
                throw SyncAbort.superseded
            }
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
            // A 429 that reached this point could not be absorbed by the client. Each
            // remaining endpoint would meet the same wall and retry inline, so stop.
            if let failure = error as? OuraClient.Failure, case .rateLimited = failure {
                throw SyncAbort.rateLimited
            }
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
        cycleRateLimit = max(cycleRateLimit ?? deadline, deadline)
        rateLimitedUntil = cycleRateLimit
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

    /// Cached records that a complete full-window response no longer contains.
    ///
    /// The same test `merged` applies when it drops a record from the cache, kept apart so
    /// the caller can name what left the cache because Oura withdrew it. Only a record dated
    /// inside `reconcileWindow` qualifies; a record that fell out of the cache by age, or an
    /// incremental or truncated response (`reconcileWindow` nil), withdraws nothing.
    nonisolated static func withdrawn<T>(
        _ cached: [T],
        fetched: [T],
        id: (T) -> String,
        date: (T) -> Date?,
        reconcileWindow: DateInterval?
    ) -> [T] {
        guard let reconcileWindow else { return [] }
        let fetchedIDs = Set(fetched.map(id))
        return cached.filter { record in
            guard let stamp = date(record), reconcileWindow.contains(stamp) else { return false }
            return !fetchedIDs.contains(id(record))
        }
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
        let cleared = clearStoredCredential()
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

    /// Fourteen days of cached documents for the chart UI tests and for visual checks of
    /// the Oura charts: a timed night of stages, a timed day of movement including
    /// non-wear, daily scores and nightly values with one missing day each, and a day of
    /// heart rate with an upload gap. In memory only: nothing is fetched or persisted.
    func injectChartFixtureForUITesting(now: Date = .now) {
        let fixture = Self.chartFixtureSnapshot(now: now)
        snapshot = fixture
        status = .connected(email: "demo@example.com")
        endpointStates[.heartRate] = .available(fixture.heartRates.count)
        endpointStates[.detailedSleep] = .available(fixture.sleeps.count)
        endpointStates[.dailyReadiness] = .available(fixture.readiness.count)
        endpointStates[.dailySleep] = .available(fixture.sleepScores.count)
        endpointStates[.dailyActivity] = .available(fixture.activities.count)
        lastSyncSummary = "Fixture data"
    }

    /// The documents behind `injectChartFixtureForUITesting`, also used by the Oura
    /// previews so they draw exactly what the UI test checks.
    nonisolated static func chartFixtureSnapshot(now: Date = .now) -> OuraSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let today = calendar.startOfDay(for: now)
        let stamp = ISO8601DateFormatter()
        func date(daysAgo: Int) -> Date { today.addingTimeInterval(-Double(daysAgo) * 86_400) }
        func day(_ daysAgo: Int) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date(daysAgo: daysAgo))
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        func codes(_ runs: [(Character, Int)]) -> String {
            String(runs.flatMap { Array(repeating: $0.0, count: $0.1) })
        }

        var fixture = OuraSnapshot()
        fixture.fetchedAt = now

        // Samples every five minutes for a day, with two hours missing while the ring charged.
        fixture.heartRates = (0..<288).compactMap { index -> OuraClient.HeartRatePoint? in
            let minutesAgo = 10 + index * 5
            guard !(600...720).contains(minutesAgo) else { return nil }
            return OuraClient.HeartRatePoint(
                bpm: Int(64 + 12 * sin(Double(index) / 18)),
                source: minutesAgo > 900 ? "sleep" : "awake",
                timestamp: stamp.string(from: now.addingTimeInterval(-Double(minutesAgo) * 60))
            )
        }

        // Last night: eight hours of stages from 23:00 UTC.
        let night = codes([
            ("4", 3), ("2", 8), ("1", 10), ("2", 6), ("3", 5), ("2", 9), ("1", 8),
            ("3", 7), ("4", 1), ("2", 10), ("3", 9), ("2", 8), ("3", 8), ("4", 4),
        ])
        fixture.sleeps = (0..<14).compactMap { daysAgo -> OuraClient.SleepDocument? in
            guard daysAgo != 6 else { return nil }
            let start = date(daysAgo: daysAgo).addingTimeInterval(-3_600)
            return OuraClient.SleepDocument(
                id: "fixture-sleep-\(daysAgo)",
                day: day(daysAgo),
                bedtime_start: stamp.string(from: start),
                bedtime_end: stamp.string(from: start.addingTimeInterval(Double(night.count) * 300)),
                average_hrv: Double(38 + (daysAgo * 3) % 12),
                lowest_heart_rate: Double(50 + daysAgo % 6),
                deep_sleep_duration: daysAgo == 0 ? 5_400 : nil,
                efficiency: daysAgo == 0 ? 88 : nil,
                light_sleep_duration: daysAgo == 0 ? 15_300 : nil,
                rem_sleep_duration: daysAgo == 0 ? 5_700 : nil,
                sleep_phase_5_min: daysAgo == 0 ? night : nil,
                total_sleep_duration: daysAgo == 0 ? 26_400 : nil,
                type: "long_sleep"
            )
        }

        fixture.readiness = (0..<14).compactMap { daysAgo -> OuraClient.DailyReadiness? in
            guard daysAgo != 4 else { return nil }
            return OuraClient.DailyReadiness(
                id: "fixture-readiness-\(daysAgo)",
                day: day(daysAgo),
                score: 70 + (daysAgo * 7) % 20,
                temperature_deviation: Double((daysAgo % 5) - 2) * 0.12,
                contributors: OuraClient.ScoreContributors()
            )
        }
        fixture.sleepScores = (0..<14).map { daysAgo in
            OuraClient.DailySleep(
                id: "fixture-sleep-score-\(daysAgo)",
                day: day(daysAgo),
                score: 75 + (daysAgo * 5) % 18,
                contributors: OuraClient.ScoreContributors()
            )
        }

        // Today's activity day from 04:00 UTC, including an hour and a half off the finger.
        let movement = codes([
            ("1", 36), ("2", 24), ("3", 12), ("5", 6), ("4", 12), ("2", 36),
            ("0", 18), ("3", 24), ("2", 48), ("4", 12), ("2", 30), ("1", 30),
        ])
        fixture.activities = (0..<14).map { daysAgo in
            OuraClient.DailyActivity(
                id: "fixture-activity-\(daysAgo)",
                day: day(daysAgo),
                score: 65 + (daysAgo * 3) % 25,
                active_calories: 420,
                average_met_minutes: 1.7,
                class_5_min: daysAgo == 0 ? movement : nil,
                contributors: OuraClient.ScoreContributors(),
                equivalent_walking_distance: 7_000,
                high_activity_time: 1_800,
                inactivity_alerts: 1,
                low_activity_time: 10_800,
                medium_activity_time: 7_200,
                non_wear_time: 5_400,
                resting_time: 19_800,
                sedentary_time: 36_000,
                steps: 8_400,
                target_calories: 500,
                target_meters: 9_000,
                total_calories: 2_300,
                timestamp: daysAgo == 0 ? stamp.string(from: date(daysAgo: 0).addingTimeInterval(4 * 3_600)) : nil
            )
        }

        return fixture
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
}
