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

        var title: String {
            switch self {
            case .notConnected:        "Not connected"
            case .authorizing:          "Waiting for Oura…"
            case .connected(let email): email ?? "Connected"
            case .error(let message):  message
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

    private weak var store: HealthStore?
    private var onReadings: (@MainActor ([Reading]) -> Void)?
    private let oauthSession = OuraOAuthSession()

    /// Credential presence, not validity. `sync()` intentionally processes expiration so
    /// the UI receives an actionable reconnect state.
    var hasAuthorization: Bool { OuraOAuthCredentialStore.load() != nil }

    var authorizationExpiresAt: Date? { OuraOAuthCredentialStore.load()?.expiresAt }

    /// Nil means Oura did not report scope metadata, not that every scope was denied.
    var reportedGrantedScopes: Set<String>? {
        guard let credential = OuraOAuthCredentialStore.load() else { return nil }
        if case .granted(let scopes) = credential.scopeMetadata { return scopes }
        return nil
    }

    var missingRequestedScopes: [String] {
        guard let credential = OuraOAuthCredentialStore.load(),
              case .granted = credential.scopeMetadata
        else { return [] }
        return OuraOAuthSession.requestedScopes.filter {
            !credential.mayAttemptAccess(requiring: $0)
        }
    }

    func state(for endpoint: OuraEndpoint) -> OuraEndpointState {
        endpointStates[endpoint] ?? .idle
    }

    func configure(
        store: HealthStore,
        onReadings: @escaping @MainActor ([Reading]) -> Void
    ) async {
        self.store = store
        self.onReadings = onReadings
        snapshot = await ReadingArchive.shared.read(
            OuraSnapshot.self,
            from: ReadingArchive.File.ouraDashboard
        ) ?? OuraSnapshot()
        restoreEndpointStatesFromSnapshot()
        lastSyncedAt = snapshot.fetchedAt

        // A personal access token from an older build cannot be migrated to OAuth.
        Keychain.delete(.ouraPersonalAccessToken)
        if let credential = OuraOAuthCredentialStore.load(), credential.isValid() {
            status = .connected(email: snapshot.personalInfo?.email)
        } else {
            OuraOAuthCredentialStore.clear()
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
            endpointIssues.removeAll()
            for endpoint in OuraEndpoint.allCases { endpointStates[endpoint] = .idle }
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
        let accessToken = OuraOAuthCredentialStore.load()?.accessToken
        let cleared = OuraOAuthCredentialStore.clear()
        if let accessToken { Task { await OuraOAuthSession.revoke(accessToken: accessToken) } }

        snapshot = OuraSnapshot()
        endpointIssues.removeAll()
        for endpoint in OuraEndpoint.allCases { endpointStates[endpoint] = .idle }
        Task { await ReadingArchive.shared.delete(ReadingArchive.File.ouraDashboard) }

        status = cleared
            ? .notConnected
            : .error("HeartSync could not remove the Oura authorization from Keychain.")
        lastSyncedAt = nil
        lastSyncSummary = nil
        return cleared
    }

    // MARK: - Sync

    /// Pulls two weeks so the dashboard has useful trends while keeping time-series payloads
    /// modest. Every endpoint is independent: cached data survives partial permission,
    /// subscription, decoding, or network failures.
    func sync(days: Int = 14) async {
        guard !isSyncing else { return }
        guard let credential = OuraOAuthCredentialStore.load() else {
            status = .notConnected
            return
        }
        guard credential.isValid() else {
            let cleared = OuraOAuthCredentialStore.clear()
            status = .error(cleared
                ? "Oura authorization expired. Connect your account again."
                : "Oura authorization expired, but HeartSync could not remove it from Keychain.")
            return
        }

        isSyncing = true
        endpointIssues.removeAll()
        defer { isSyncing = false }

        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        let client = OuraClient(accessToken: credential.accessToken)
        var next = snapshot
        var recordCount = 0

        do {
            if let value = try await load(.personalInfo, credential: credential, operation: client.personalInfo) {
                next.personalInfo = value
                recordCount += 1
            }
            if let value = try await load(.heartRate, credential: credential, operation: { try await client.heartRate(from: start, to: end) }) {
                next.heartRates = value
                recordCount += value.count
            }
            if let value = try await load(.dailyActivity, credential: credential, operation: { try await client.dailyActivity(from: start, to: end) }) {
                next.activities = value
                recordCount += value.count
            }
            if let value = try await load(.dailyReadiness, credential: credential, operation: { try await client.dailyReadiness(from: start, to: end) }) {
                next.readiness = value
                recordCount += value.count
            }
            if let value = try await load(.dailySleep, credential: credential, operation: { try await client.dailySleep(from: start, to: end) }) {
                next.sleepScores = value
                recordCount += value.count
            }
            if let value = try await load(.detailedSleep, credential: credential, operation: { try await client.sleep(from: start, to: end) }) {
                next.sleeps = value
                recordCount += value.count
            }
            if let value = try await load(.sleepTime, credential: credential, operation: { try await client.sleepTime(from: start, to: end) }) {
                next.sleepTimes = value
                recordCount += value.count
            }
            if let value = try await load(.dailySpO2, credential: credential, operation: { try await client.dailySpO2(from: start, to: end) }) {
                next.oxygen = value
                recordCount += value.count
            }
            if let value = try await load(.dailyStress, credential: credential, operation: { try await client.dailyStress(from: start, to: end) }) {
                next.stress = value
                recordCount += value.count
            }
            if let value = try await load(.dailyResilience, credential: credential, operation: { try await client.dailyResilience(from: start, to: end) }) {
                next.resilience = value
                recordCount += value.count
            }
            if let value = try await load(.cardiovascularAge, credential: credential, operation: { try await client.dailyCardiovascularAge(from: start, to: end) }) {
                next.cardiovascularAge = value
                recordCount += value.count
            }
            if let value = try await load(.vo2Max, credential: credential, operation: { try await client.vo2Max(from: start, to: end) }) {
                next.vo2Max = value
                recordCount += value.count
            }
            if let value = try await load(.workouts, credential: credential, operation: { try await client.workouts(from: start, to: end) }) {
                next.workouts = value
                recordCount += value.count
            }
            if let value = try await load(.sessions, credential: credential, operation: { try await client.sessions(from: start, to: end) }) {
                next.sessions = value
                recordCount += value.count
            }
            if let value = try await load(.tags, credential: credential, operation: { try await client.tags(from: start, to: end) }) {
                next.tags = value
                recordCount += value.count
            }
            if let value = try await load(.enhancedTags, credential: credential, operation: { try await client.enhancedTags(from: start, to: end) }) {
                next.enhancedTags = value
                recordCount += value.count
            }
            if let value = try await load(.restMode, credential: credential, operation: { try await client.restModePeriods(from: start, to: end) }) {
                next.restModePeriods = value
                recordCount += value.count
            }
            if let value = try await load(.ringBattery, credential: credential, operation: { try await client.ringBatteryLevels(from: start, to: end) }) {
                next.batteryLevels = value
                recordCount += value.count
            }
            if let value = try await load(.ringConfiguration, credential: credential, operation: client.ringConfigurations) {
                next.ringConfigurations = value
                recordCount += value.count
            }
        } catch SyncAbort.authorization {
            return
        } catch {
            logger.error("Unexpected Oura sync abort: \(error.localizedDescription, privacy: .public)")
            return
        }

        let readings = Self.readings(fromHeartRate: next.heartRates)
            + Self.readings(fromSleep: next.sleeps)
            + Self.readings(fromSpO2: next.oxygen)
            + Self.readings(fromVO2Max: next.vo2Max)

        next.fetchedAt = .now
        snapshot = next
        lastSyncedAt = next.fetchedAt
        await ReadingArchive.shared.write(next, to: ReadingArchive.File.ouraDashboard)

        upsertSource(battery: next.latestBatteryLevel?.level)
        if !readings.isEmpty { onReadings?(readings) }

        status = .connected(email: next.personalInfo?.email)
        if endpointIssues.isEmpty {
            lastSyncSummary = "\(recordCount) Oura record\(recordCount == 1 ? "" : "s")"
        } else {
            lastSyncSummary = "\(recordCount) records, \(endpointIssues.count) unavailable collection\(endpointIssues.count == 1 ? "" : "s")"
            logger.warning("Oura partial sync: \(self.endpointIssues.map(\.message).joined(separator: "; "), privacy: .public)")
        }
    }

    private func load<T>(
        _ endpoint: OuraEndpoint,
        credential: OuraOAuthCredential,
        operation: () async throws -> T
    ) async throws -> T? {
        guard endpoint.requiredScope.map({ credential.mayAttemptAccess(requiring: $0) }) != false else {
            endpointStates[endpoint] = .permissionMissing
            endpointIssues.append(OuraEndpointIssue(
                endpoint: endpoint,
                message: "\(endpoint.title): permission not granted",
                isPermissionIssue: true
            ))
            return nil
        }

        endpointStates[endpoint] = .syncing
        do {
            let result = try await operation()
            let count = (result as? any Collection)?.count ?? 1
            endpointStates[endpoint] = .available(count)
            return result
        } catch {
            // Oura currently returns HTTP 401 (rather than 403) when a valid token lacks
            // newer scopes such as `heart_health`. That is an endpoint permission issue,
            // not an invalid bearer token, so keep the account and continue the sync.
            if Self.isScopePermissionFailure(error) {
                let message = Self.describe(error, endpoint: endpoint.title)
                endpointStates[endpoint] = .permissionMissing
                endpointIssues.append(OuraEndpointIssue(
                    endpoint: endpoint,
                    message: message,
                    isPermissionIssue: true
                ))
                return nil
            }
            if handleAuthorizationFailure(error) { throw SyncAbort.authorization }
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

    private static func describe(_ error: any Error, endpoint: String) -> String {
        if let failure = error as? OuraClient.Failure {
            return "\(endpoint): \(failure.errorDescription ?? "failed")"
        }
        return "\(endpoint): \(error.localizedDescription)"
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
        status = .error(cleared
            ? (detail ?? failure.errorDescription ?? "Oura authorization failed")
            : "Oura rejected the authorization, but HeartSync could not remove it from Keychain.")
        return true
    }

    private func upsertSource(battery: Int? = nil) {
        store?.upsert(DataSource(
            id: DataSource.ouraSourceID,
            displayName: "Oura Ring",
            transport: .oura,
            model: snapshot.currentRing.map { ring in
                [ring.hardware_type, ring.design]
                    .compactMap { $0?.replacingOccurrences(of: "_", with: " ").capitalized }
                    .joined(separator: " ")
            } ?? "Oura Cloud API v2 (OAuth)",
            lastSeenAt: snapshot.fetchedAt ?? .now,
            batteryPercent: battery
        ))
    }

    private func restoreEndpointStatesFromSnapshot() {
        guard snapshot.fetchedAt != nil else { return }
        endpointStates[.personalInfo] = snapshot.personalInfo == nil ? .idle : .available(1)
        endpointStates[.heartRate] = .available(snapshot.heartRates.count)
        endpointStates[.dailyActivity] = .available(snapshot.activities.count)
        endpointStates[.dailyReadiness] = .available(snapshot.readiness.count)
        endpointStates[.dailySleep] = .available(snapshot.sleepScores.count)
        endpointStates[.detailedSleep] = .available(snapshot.sleeps.count)
        endpointStates[.sleepTime] = .available(snapshot.sleepTimes.count)
        endpointStates[.dailySpO2] = .available(snapshot.oxygen.count)
        endpointStates[.dailyStress] = .available(snapshot.stress.count)
        endpointStates[.dailyResilience] = .available(snapshot.resilience.count)
        endpointStates[.cardiovascularAge] = .available(snapshot.cardiovascularAge.count)
        endpointStates[.vo2Max] = .available(snapshot.vo2Max.count)
        endpointStates[.workouts] = .available(snapshot.workouts.count)
        endpointStates[.sessions] = .available(snapshot.sessions.count)
        endpointStates[.tags] = .available(snapshot.tags.count)
        endpointStates[.enhancedTags] = .available(snapshot.enhancedTags.count)
        endpointStates[.restMode] = .available(snapshot.restModePeriods.count)
        endpointStates[.ringBattery] = .available(snapshot.batteryLevels.count)
        endpointStates[.ringConfiguration] = .available(snapshot.ringConfigurations.count)
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
