import Foundation

/// Every collection imported for the dedicated Oura dashboard. Endpoint state is kept
/// separately from the cached payload so one unavailable collection never hides good data.
enum OuraEndpoint: String, CaseIterable, Identifiable, Sendable {
    case personalInfo
    case heartRate
    case dailyActivity
    case dailyReadiness
    case dailySleep
    case detailedSleep
    case sleepTime
    case dailySpO2
    case dailyStress
    case dailyResilience
    case cardiovascularAge
    case vo2Max
    case workouts
    case sessions
    case tags
    case enhancedTags
    case restMode
    case ringBattery
    case ringConfiguration

    var id: String { rawValue }

    /// Collection name for the Oura screen. Display only — `rawValue` stays the
    /// identifier used for endpoint state, issues, and the request paths.
    var title: String {
        switch self {
        case .personalInfo:
            String(localized: "ouraEndpoint.personalInfo", defaultValue: "Profile", comment: "Oura collection name: account profile")
        case .heartRate:
            String(localized: "ouraEndpoint.heartRate", defaultValue: "Heart rate", comment: "Oura collection name: heart rate samples")
        case .dailyActivity:
            String(localized: "ouraEndpoint.dailyActivity", defaultValue: "Activity", comment: "Oura collection name: daily activity")
        case .dailyReadiness:
            String(localized: "ouraEndpoint.dailyReadiness", defaultValue: "Readiness", comment: "Oura collection name: daily readiness score")
        case .dailySleep:
            String(localized: "ouraEndpoint.dailySleep", defaultValue: "Sleep score", comment: "Oura collection name: daily sleep score")
        case .detailedSleep:
            String(localized: "ouraEndpoint.detailedSleep", defaultValue: "Sleep signals", comment: "Oura collection name: detailed per-sleep documents")
        case .sleepTime:
            String(localized: "ouraEndpoint.sleepTime", defaultValue: "Bedtime guidance", comment: "Oura collection name: recommended bedtime window")
        case .dailySpO2:
            String(localized: "ouraEndpoint.dailySpO2", defaultValue: "Blood oxygen", comment: "Oura collection name: daily blood oxygen saturation")
        case .dailyStress:
            String(localized: "ouraEndpoint.dailyStress", defaultValue: "Stress", comment: "Oura collection name: daily stress")
        case .dailyResilience:
            String(localized: "ouraEndpoint.dailyResilience", defaultValue: "Resilience", comment: "Oura collection name: daily resilience")
        case .cardiovascularAge:
            String(localized: "ouraEndpoint.cardiovascularAge", defaultValue: "Cardiovascular age", comment: "Oura collection name: cardiovascular age")
        case .vo2Max:
            String(localized: "ouraEndpoint.vo2Max", defaultValue: "VO₂ max", comment: "Oura collection name: VO2 max")
        case .workouts:
            String(localized: "ouraEndpoint.workouts", defaultValue: "Workouts", comment: "Oura collection name: workouts")
        case .sessions:
            String(localized: "ouraEndpoint.sessions", defaultValue: "Sessions", comment: "Oura collection name: guided sessions")
        case .tags:
            String(localized: "ouraEndpoint.tags", defaultValue: "Tags", comment: "Oura collection name: legacy tags")
        case .enhancedTags:
            String(localized: "ouraEndpoint.enhancedTags", defaultValue: "Enhanced tags", comment: "Oura collection name: enhanced tags")
        case .restMode:
            String(localized: "ouraEndpoint.restMode", defaultValue: "Rest mode", comment: "Oura collection name: rest mode periods")
        case .ringBattery:
            String(localized: "ouraEndpoint.ringBattery", defaultValue: "Ring battery", comment: "Oura collection name: ring battery level")
        case .ringConfiguration:
            String(localized: "ouraEndpoint.ringConfiguration", defaultValue: "Ring details", comment: "Oura collection name: ring hardware details")
        }
    }

    /// Oura's effective production scope mapping. Some newer scopes are not yet listed in
    /// the generated V2 OpenAPI security scheme but are named by the live API on denial.
    var requiredScope: String? {
        switch self {
        case .personalInfo:
            "personal"
        case .heartRate:
            "heartrate"
        case .dailyActivity, .dailyReadiness, .dailySleep, .detailedSleep,
             .sleepTime, .dailyStress, .restMode:
            "daily"
        case .dailyResilience:
            "stress"
        case .cardiovascularAge, .vo2Max:
            "heart_health"
        case .dailySpO2:
            "spo2"
        case .workouts:
            "workout"
        case .sessions:
            "session"
        case .tags, .enhancedTags:
            "tag"
        case .ringBattery, .ringConfiguration:
            "ring_configuration"
        }
    }
}

enum OuraEndpointState: Equatable, Sendable {
    case idle
    case syncing
    case available(Int)
    /// Oura had more pages than one sync is allowed to walk. The count is real, but it is a
    /// prefix of the collection and must never be presented as the complete set.
    case partial(Int)
    case permissionMissing
    case failed(String)

    /// How many records the collection currently holds, or nil when it holds none because
    /// it was never fetched, is in flight, or failed.
    var recordCount: Int? {
        switch self {
        case .available(let count), .partial(let count): return count
        case .idle, .syncing, .permissionMissing, .failed: return nil
        }
    }

    /// False whenever the screen would overstate what HeartSync actually has.
    var isComplete: Bool {
        switch self {
        case .available: true
        case .idle, .syncing, .partial, .permissionMissing, .failed: false
        }
    }
}

/// Lets `OuraManager.load` notice a truncated page walk without knowing the record type.
/// `load` is generic over whatever the collection's request returns, so the flag has to be
/// reachable through an existential rather than the concrete `PagedResult` element type.
protocol OuraTruncatableResult {
    var isTruncated: Bool { get }
}

extension OuraClient.PagedResult: OuraTruncatableResult {}

struct OuraEndpointIssue: Identifiable, Equatable, Sendable {
    var endpoint: OuraEndpoint
    var message: String
    var isPermissionIssue: Bool

    var id: String { endpoint.rawValue }
}

/// Versioned, token-free cache of recent Oura records. OAuth credentials remain exclusively
/// in Keychain; this object is safe to persist with the rest of HeartSync's local data.
struct OuraSnapshot: Codable, Hashable, Sendable {
    var schemaVersion = 1
    var fetchedAt: Date?
    var personalInfo: OuraClient.PersonalInfo?
    var heartRates: [OuraClient.HeartRatePoint] = []
    var activities: [OuraClient.DailyActivity] = []
    var readiness: [OuraClient.DailyReadiness] = []
    var sleepScores: [OuraClient.DailySleep] = []
    var sleeps: [OuraClient.SleepDocument] = []
    var sleepTimes: [OuraClient.SleepTimeDocument] = []
    var oxygen: [OuraClient.DailySpO2] = []
    var stress: [OuraClient.DailyStress] = []
    var resilience: [OuraClient.DailyResilience] = []
    var cardiovascularAge: [OuraClient.DailyCardiovascularAge] = []
    var vo2Max: [OuraClient.VO2MaxDocument] = []
    var workouts: [OuraClient.Workout] = []
    var sessions: [OuraClient.SessionDocument] = []
    var tags: [OuraClient.TagDocument] = []
    var enhancedTags: [OuraClient.EnhancedTagDocument] = []
    var restModePeriods: [OuraClient.RestModePeriod] = []
    var batteryLevels: [OuraClient.RingBatteryLevel] = []
    var ringConfigurations: [OuraClient.RingConfiguration] = []

    /// Per-collection high-water mark, keyed by `OuraEndpoint.rawValue`: the instant through
    /// which that collection was last fetched successfully. The next sync asks only for what
    /// came after it (less a deliberate overlap), instead of re-downloading the same
    /// fortnight every quarter of an hour.
    ///
    /// Defaulted and keyed by string so an archive written by the shipping build still
    /// decodes; an absent mark simply means "fetch the full window".
    var collectionSyncMarks: [String: Date] = [:]

    /// When the last full-window pass completed. Incremental fetches can only ever see what
    /// Oura chose to return for recent days, so a periodic full backfill still runs to pick
    /// up late corrections and anything an earlier failure missed.
    var lastFullBackfillAt: Date?

    /// Collections whose last page walk hit the client's page ceiling, by
    /// `OuraEndpoint.rawValue`. Persisted so a relaunch does not describe a cached prefix as
    /// a complete collection.
    var truncatedCollections: Set<String> = []

    var hasData: Bool {
        personalInfo != nil || totalRecordCount > 0
    }

    var totalRecordCount: Int {
        heartRates.count + activities.count + readiness.count + sleepScores.count
            + sleeps.count + sleepTimes.count + oxygen.count + stress.count
            + resilience.count + cardiovascularAge.count + vo2Max.count + workouts.count
            + sessions.count + tags.count + enhancedTags.count + restModePeriods.count
            + batteryLevels.count + ringConfigurations.count
    }

    /// Newest cached heart-rate sample.
    ///
    /// Parses each timestamp once rather than inside a comparator: `heartRates` is by far
    /// the largest collection in the snapshot — a fortnight of five-minute samples is
    /// thousands of records — and `max(by:)` would parse both sides of every comparison,
    /// on the main thread, each time the dashboard read this. A sample whose timestamp
    /// cannot be parsed is not evidence of age, so when none parses the last cached sample
    /// is returned, which is what the comparator did.
    var latestHeartRate: OuraClient.HeartRatePoint? {
        var newest: (point: OuraClient.HeartRatePoint, date: Date)?
        for point in heartRates {
            guard let date = OuraClient.parseTimestamp(point.timestamp) else { continue }
            if let current = newest, date <= current.date { continue }
            newest = (point, date)
        }
        return newest?.point ?? heartRates.last
    }

    var latestActivity: OuraClient.DailyActivity? { activities.max { $0.day < $1.day } }
    var latestReadiness: OuraClient.DailyReadiness? { readiness.max { $0.day < $1.day } }
    var latestSleepScore: OuraClient.DailySleep? { sleepScores.max { $0.day < $1.day } }
    var latestSleepTime: OuraClient.SleepTimeDocument? { sleepTimes.max { $0.day < $1.day } }
    var latestOxygen: OuraClient.DailySpO2? { oxygen.max { $0.day < $1.day } }
    var latestStress: OuraClient.DailyStress? { stress.max { $0.day < $1.day } }
    var latestResilience: OuraClient.DailyResilience? { resilience.max { $0.day < $1.day } }
    var latestCardiovascularAge: OuraClient.DailyCardiovascularAge? { cardiovascularAge.max { $0.day < $1.day } }
    var latestVO2Max: OuraClient.VO2MaxDocument? { vo2Max.max { $0.day < $1.day } }

    var latestSleep: OuraClient.SleepDocument? {
        sleeps
            .filter { $0.type != "deleted" && $0.type != "rest" }
            .max {
                (OuraClient.parseTimestamp($0.bedtime_end) ?? OuraClient.parseDay($0.day) ?? .distantPast)
                    < (OuraClient.parseTimestamp($1.bedtime_end) ?? OuraClient.parseDay($1.day) ?? .distantPast)
            }
    }

    var latestBatteryLevel: OuraClient.RingBatteryLevel? {
        batteryLevels.max { $0.timestamp_unix < $1.timestamp_unix }
    }

    var currentRing: OuraClient.RingConfiguration? {
        ringConfigurations.max {
            (OuraClient.parseTimestamp($0.set_up_at) ?? .distantPast)
                < (OuraClient.parseTimestamp($1.set_up_at) ?? .distantPast)
        }
    }
}

extension OuraSnapshot {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fetchedAt
        case personalInfo
        case heartRates
        case activities
        case readiness
        case sleepScores
        case sleeps
        case sleepTimes
        case oxygen
        case stress
        case resilience
        case cardiovascularAge
        case vo2Max
        case workouts
        case sessions
        case tags
        case enhancedTags
        case restModePeriods
        case batteryLevels
        case ringConfigurations
        case collectionSyncMarks
        case lastFullBackfillAt
        case truncatedCollections
    }

    /// Reads both the current cache and the bare snapshot written before incremental sync.
    ///
    /// Synthesised `Decodable` does not use a stored property's declaration-time default
    /// when its key is absent. Without this initializer, the newly added non-optional
    /// `collectionSyncMarks` and `truncatedCollections` keys make every existing Oura cache
    /// fail decoding and get preserved aside as corrupt. All collections default to empty
    /// as an additional compatibility guard for snapshots written before a collection was
    /// introduced; missing cached data means "fetch it", not "discard the whole cache".
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        fetchedAt = try values.decodeIfPresent(Date.self, forKey: .fetchedAt)
        personalInfo = try values.decodeIfPresent(OuraClient.PersonalInfo.self, forKey: .personalInfo)
        heartRates = try values.decodeIfPresent([OuraClient.HeartRatePoint].self, forKey: .heartRates) ?? []
        activities = try values.decodeIfPresent([OuraClient.DailyActivity].self, forKey: .activities) ?? []
        readiness = try values.decodeIfPresent([OuraClient.DailyReadiness].self, forKey: .readiness) ?? []
        sleepScores = try values.decodeIfPresent([OuraClient.DailySleep].self, forKey: .sleepScores) ?? []
        sleeps = try values.decodeIfPresent([OuraClient.SleepDocument].self, forKey: .sleeps) ?? []
        sleepTimes = try values.decodeIfPresent([OuraClient.SleepTimeDocument].self, forKey: .sleepTimes) ?? []
        oxygen = try values.decodeIfPresent([OuraClient.DailySpO2].self, forKey: .oxygen) ?? []
        stress = try values.decodeIfPresent([OuraClient.DailyStress].self, forKey: .stress) ?? []
        resilience = try values.decodeIfPresent([OuraClient.DailyResilience].self, forKey: .resilience) ?? []
        cardiovascularAge = try values.decodeIfPresent([OuraClient.DailyCardiovascularAge].self, forKey: .cardiovascularAge) ?? []
        vo2Max = try values.decodeIfPresent([OuraClient.VO2MaxDocument].self, forKey: .vo2Max) ?? []
        workouts = try values.decodeIfPresent([OuraClient.Workout].self, forKey: .workouts) ?? []
        sessions = try values.decodeIfPresent([OuraClient.SessionDocument].self, forKey: .sessions) ?? []
        tags = try values.decodeIfPresent([OuraClient.TagDocument].self, forKey: .tags) ?? []
        enhancedTags = try values.decodeIfPresent([OuraClient.EnhancedTagDocument].self, forKey: .enhancedTags) ?? []
        restModePeriods = try values.decodeIfPresent([OuraClient.RestModePeriod].self, forKey: .restModePeriods) ?? []
        batteryLevels = try values.decodeIfPresent([OuraClient.RingBatteryLevel].self, forKey: .batteryLevels) ?? []
        ringConfigurations = try values.decodeIfPresent([OuraClient.RingConfiguration].self, forKey: .ringConfigurations) ?? []
        collectionSyncMarks = try values.decodeIfPresent([String: Date].self, forKey: .collectionSyncMarks) ?? [:]
        lastFullBackfillAt = try values.decodeIfPresent(Date.self, forKey: .lastFullBackfillAt)
        truncatedCollections = try values.decodeIfPresent(Set<String>.self, forKey: .truncatedCollections) ?? []
    }
}
