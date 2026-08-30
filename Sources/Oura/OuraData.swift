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

    var title: String {
        switch self {
        case .personalInfo:       "Profile"
        case .heartRate:          "Heart rate"
        case .dailyActivity:      "Activity"
        case .dailyReadiness:     "Readiness"
        case .dailySleep:         "Sleep score"
        case .detailedSleep:      "Sleep signals"
        case .sleepTime:          "Bedtime guidance"
        case .dailySpO2:          "Blood oxygen"
        case .dailyStress:        "Stress"
        case .dailyResilience:    "Resilience"
        case .cardiovascularAge:  "Cardiovascular age"
        case .vo2Max:             "VO₂ max"
        case .workouts:           "Workouts"
        case .sessions:           "Sessions"
        case .tags:               "Tags"
        case .enhancedTags:       "Enhanced tags"
        case .restMode:           "Rest mode"
        case .ringBattery:        "Ring battery"
        case .ringConfiguration:  "Ring details"
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
    case permissionMissing
    case failed(String)
}

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

    var latestHeartRate: OuraClient.HeartRatePoint? {
        heartRates.max {
            (OuraClient.parseTimestamp($0.timestamp) ?? .distantPast)
                < (OuraClient.parseTimestamp($1.timestamp) ?? .distantPast)
        }
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
