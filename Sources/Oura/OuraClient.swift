import Foundation

/// Talks to the supported Oura Cloud API v2 collections using an OAuth bearer token.
/// Oura publishes processed movement classifications, but not raw ring accelerometer data.
struct OuraClient: Sendable {

    enum Failure: LocalizedError, Equatable {
        case missingToken
        case unauthorized(String?)
        case forbidden(String?)
        case rateLimited(retryAfter: Int?, detail: String?)
        case http(Int, String?)
        case transport(String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .missingToken:
                "No Oura authorization is saved. Connect your Oura account to sync."
            case .unauthorized(let detail):
                detail ?? "Oura authorization expired or was revoked. Connect your account again."
            case .forbidden(let detail):
                detail ?? "Oura denied this data request. Its permission may be missing, or the Oura membership may not include API access."
            case .rateLimited(let retryAfter, let detail):
                if let detail { detail }
                else if let retryAfter { "Oura is rate-limiting requests. Try again in \(retryAfter) seconds." }
                else { "Oura is rate-limiting requests. HeartSync will try again later." }
            case .http(let code, let detail):
                detail ?? "Oura returned HTTP \(code)."
            case .transport(let message):
                "Could not reach Oura: \(message)"
            case .decoding(let message):
                "Oura returned data HeartSync could not read: \(message)"
            }
        }
    }

    private let baseURL = URL(string: "https://api.ouraring.com/v2/usercollection/")!
    private let accessToken: String
    private let session: URLSession

    init(accessToken: String, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.session = session
    }

    // MARK: - Shared response shapes

    private struct Page<T: Decodable & Sendable>: Decodable, Sendable {
        var data: [T]
        var next_token: String?
    }

    private struct APIProblem: Decodable, Sendable {
        var status: Int?
        var title: String?
        var detail: String?
        var error: String?
        var error_description: String?

        var bestMessage: String? {
            for candidate in [detail, error_description, title, error] {
                if let candidate, !candidate.isEmpty { return candidate }
            }
            return nil
        }
    }

    struct Sample: Codable, Hashable, Sendable {
        var interval: Double
        var items: [Double?]
        var timestamp: String
    }

    /// Oura uses separate contributor objects, but their fields do not overlap. One tolerant
    /// model keeps score cards data-driven and remains forward-compatible with omitted fields.
    struct ScoreContributors: Codable, Hashable, Sendable {
        var meet_daily_targets: Int?
        var move_every_hour: Int?
        var recovery_time: Int?
        var stay_active: Int?
        var training_frequency: Int?
        var training_volume: Int?
        var activity_balance: Int?
        var body_temperature: Int?
        var hrv_balance: Int?
        var previous_day_activity: Int?
        var previous_night: Int?
        var recovery_index: Int?
        var resting_heart_rate: Int?
        var sleep_balance: Int?
        var sleep_regularity: Int?
        var deep_sleep: Int?
        var efficiency: Int?
        var latency: Int?
        var rem_sleep: Int?
        var restfulness: Int?
        var timing: Int?
        var total_sleep: Int?
    }

    // MARK: - Biometrics and scores

    struct HeartRatePoint: Codable, Hashable, Sendable {
        var bpm: Int
        /// `awake`, `rest`, `sleep`, `session`, or `live` when Oura supplies context.
        var source: String?
        var timestamp: String
    }

    struct DailySpO2: Codable, Hashable, Sendable {
        struct Percentage: Codable, Hashable, Sendable { var average: Double? }
        var id: String
        var day: String
        var spo2_percentage: Percentage?
        var breathing_disturbance_index: Int? = nil
    }

    struct SleepReadiness: Codable, Hashable, Sendable {
        var contributors: ScoreContributors?
        var score: Int?
        var temperature_deviation: Double?
        var temperature_trend_deviation: Double?
    }

    struct SleepDocument: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var bedtime_start: String?
        var bedtime_end: String?
        /// Oura's `average_hrv` is an RMSSD-style measure in milliseconds.
        var average_hrv: Double?
        var average_heart_rate: Double?
        var lowest_heart_rate: Double?
        var average_breath: Double?
        var awake_time: Int? = nil
        var deep_sleep_duration: Int? = nil
        var efficiency: Int? = nil
        var heart_rate: Sample? = nil
        var hrv: Sample? = nil
        var latency: Int? = nil
        var light_sleep_duration: Int? = nil
        var low_battery_alert: Bool? = nil
        var movement_30_sec: String? = nil
        var readiness: SleepReadiness? = nil
        var readiness_score_delta: Int? = nil
        var rem_sleep_duration: Int? = nil
        var restless_periods: Int? = nil
        var ring_id: String? = nil
        var sleep_phase_5_min: String? = nil
        var sleep_score_delta: Int? = nil
        var time_in_bed: Int? = nil
        var total_sleep_duration: Int? = nil
        var type: String? = nil
    }

    struct DailyActivity: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var score: Int?
        var active_calories: Int
        var average_met_minutes: Double
        /// Five-minute Oura-processed classes: 0 non-wear through 5 high activity.
        var class_5_min: String?
        var contributors: ScoreContributors
        var equivalent_walking_distance: Int
        var high_activity_time: Int
        var inactivity_alerts: Int
        var low_activity_time: Int
        var medium_activity_time: Int
        var met: Sample?
        var non_wear_time: Int
        var resting_time: Int
        var sedentary_time: Int
        var steps: Int
        var target_calories: Int
        var target_meters: Int
        var total_calories: Int
    }

    struct DailyReadiness: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var score: Int?
        var temperature_deviation: Double?
        var temperature_trend_deviation: Double?
        var contributors: ScoreContributors
    }

    struct DailySleep: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var score: Int?
        var contributors: ScoreContributors
    }

    struct DailyStress: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var day_summary: String?
        var recovery_high: Int?
        var stress_high: Int?
    }

    struct DailyResilience: Codable, Hashable, Sendable {
        struct Contributors: Codable, Hashable, Sendable {
            var daytime_recovery: Double?
            var sleep_recovery: Double?
            var stress: Double?
        }
        var id: String
        var day: String
        var level: String
        var contributors: Contributors
    }

    struct DailyCardiovascularAge: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var pulse_wave_velocity: Double?
        var vascular_age: Int?
    }

    struct VO2MaxDocument: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var timestamp: String?
        var vo2_max: Double?
    }

    // MARK: - Activity, context, and ring

    struct Workout: Codable, Hashable, Sendable {
        var id: String
        var activity: String
        var calories: Double?
        var day: String
        var distance: Double?
        var end_datetime: String
        var intensity: String
        var label: String?
        var source: String
        var start_datetime: String
    }

    struct SessionDocument: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var end_datetime: String
        var heart_rate: Sample?
        var heart_rate_variability: Sample?
        var mood: String?
        /// Oura-processed motion counts; this is not raw accelerometer data.
        var motion_count: Sample?
        var start_datetime: String
        var type: String
    }

    struct TagDocument: Codable, Hashable, Sendable {
        var id: String
        var day: String
        var text: String?
        var timestamp: String
        var tags: [String]
    }

    struct EnhancedTagDocument: Codable, Hashable, Sendable {
        var id: String
        var tag_type_code: String?
        var start_time: String
        var end_time: String?
        var start_day: String
        var end_day: String?
        var comment: String?
        var custom_name: String?
    }

    struct SleepTimeDocument: Codable, Hashable, Sendable {
        struct Window: Codable, Hashable, Sendable {
            var day_tz: Int
            var end_offset: Int
            var start_offset: Int
        }
        var id: String
        var day: String
        var optimal_bedtime: Window?
        var recommendation: String?
        var status: String?
    }

    struct RestModePeriod: Codable, Hashable, Sendable {
        struct Episode: Codable, Hashable, Sendable {
            var tags: [String]
            var timestamp: String
        }
        var id: String
        var end_day: String?
        var end_time: String?
        var episodes: [Episode]
        var start_day: String
        var start_time: String?
    }

    struct RingBatteryLevel: Codable, Hashable, Sendable {
        var timestamp: String
        var timestamp_unix: Int64
        var charging: Bool?
        var in_charger: Bool?
        var level: Int
    }

    struct RingConfiguration: Codable, Hashable, Sendable {
        var id: String
        var color: String?
        var design: String?
        var firmware_version: String?
        var hardware_type: String?
        var set_up_at: String?
        var size: Int?
    }

    struct PersonalInfo: Codable, Hashable, Sendable {
        var id: String? = nil
        var age: Int?
        var weight: Double?
        var height: Double?
        var biological_sex: String?
        var email: String?
    }

    // MARK: - Requests

    func personalInfo() async throws -> PersonalInfo {
        try await get(PersonalInfo.self, path: "personal_info", query: [])
    }

    func heartRate(from start: Date, to end: Date) async throws -> [HeartRatePoint] {
        try await paged(HeartRatePoint.self, path: "heartrate", query: Self.dateTimeQuery(start, end))
    }

    func ringBatteryLevels(from start: Date, to end: Date) async throws -> [RingBatteryLevel] {
        try await paged(RingBatteryLevel.self, path: "ring_battery_level", query: Self.dateTimeQuery(start, end))
    }

    func dailyActivity(from start: Date, to end: Date) async throws -> [DailyActivity] {
        try await paged(DailyActivity.self, path: "daily_activity", query: Self.dayQuery(start, end))
    }

    func dailyReadiness(from start: Date, to end: Date) async throws -> [DailyReadiness] {
        try await paged(DailyReadiness.self, path: "daily_readiness", query: Self.dayQuery(start, end))
    }

    func dailySleep(from start: Date, to end: Date) async throws -> [DailySleep] {
        try await paged(DailySleep.self, path: "daily_sleep", query: Self.dayQuery(start, end))
    }

    func dailySpO2(from start: Date, to end: Date) async throws -> [DailySpO2] {
        try await paged(DailySpO2.self, path: "daily_spo2", query: Self.dayQuery(start, end))
    }

    func dailyStress(from start: Date, to end: Date) async throws -> [DailyStress] {
        try await paged(DailyStress.self, path: "daily_stress", query: Self.dayQuery(start, end))
    }

    func dailyResilience(from start: Date, to end: Date) async throws -> [DailyResilience] {
        try await paged(DailyResilience.self, path: "daily_resilience", query: Self.dayQuery(start, end))
    }

    func dailyCardiovascularAge(from start: Date, to end: Date) async throws -> [DailyCardiovascularAge] {
        try await paged(DailyCardiovascularAge.self, path: "daily_cardiovascular_age", query: Self.dayQuery(start, end))
    }

    func sleep(from start: Date, to end: Date) async throws -> [SleepDocument] {
        try await paged(SleepDocument.self, path: "sleep", query: Self.dayQuery(start, end))
    }

    func sleepTime(from start: Date, to end: Date) async throws -> [SleepTimeDocument] {
        try await paged(SleepTimeDocument.self, path: "sleep_time", query: Self.dayQuery(start, end))
    }

    func vo2Max(from start: Date, to end: Date) async throws -> [VO2MaxDocument] {
        try await paged(VO2MaxDocument.self, path: "vO2_max", query: Self.dayQuery(start, end))
    }

    func workouts(from start: Date, to end: Date) async throws -> [Workout] {
        try await paged(Workout.self, path: "workout", query: Self.dayQuery(start, end))
    }

    func sessions(from start: Date, to end: Date) async throws -> [SessionDocument] {
        try await paged(SessionDocument.self, path: "session", query: Self.dayQuery(start, end))
    }

    func tags(from start: Date, to end: Date) async throws -> [TagDocument] {
        try await paged(TagDocument.self, path: "tag", query: Self.dayQuery(start, end))
    }

    func enhancedTags(from start: Date, to end: Date) async throws -> [EnhancedTagDocument] {
        try await paged(EnhancedTagDocument.self, path: "enhanced_tag", query: Self.dayQuery(start, end))
    }

    func restModePeriods(from start: Date, to end: Date) async throws -> [RestModePeriod] {
        try await paged(RestModePeriod.self, path: "rest_mode_period", query: Self.dayQuery(start, end))
    }

    func ringConfigurations() async throws -> [RingConfiguration] {
        try await paged(RingConfiguration.self, path: "ring_configuration", query: [])
    }

    // MARK: - Transport

    private func paged<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem]
    ) async throws -> [T] {
        var results: [T] = []
        var nextToken: String?
        var pagesRemaining = 25

        repeat {
            var pageQuery = query
            if let nextToken { pageQuery.append(URLQueryItem(name: "next_token", value: nextToken)) }
            let page: Page<T> = try await get(Page<T>.self, path: path, query: pageQuery)
            results.append(contentsOf: page.data)
            nextToken = page.next_token
            pagesRemaining -= 1
        } while nextToken != nil && pagesRemaining > 0

        return results
    }

    private func get<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem]
    ) async throws -> T {
        guard !accessToken.isEmpty else { throw Failure.missingToken }

        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw Failure.transport("Bad URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.transport("No HTTP response") }
        let detail = (try? JSONDecoder().decode(APIProblem.self, from: data))?.bestMessage
        switch http.statusCode {
        case 200...299: break
        case 401: throw Failure.unauthorized(detail)
        case 403: throw Failure.forbidden(detail)
        case 429:
            throw Failure.rateLimited(
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init),
                detail: detail
            )
        default: throw Failure.http(http.statusCode, detail)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.decoding(error.localizedDescription)
        }
    }

    // MARK: - Dates

    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        return iso8601.date(from: string) ?? iso8601Fractional.date(from: string)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func parseDay(_ string: String) -> Date? { dayFormatter.date(from: string) }

    private static func dayQuery(_ start: Date, _ end: Date) -> [URLQueryItem] {
        [
            URLQueryItem(name: "start_date", value: dayFormatter.string(from: start)),
            URLQueryItem(name: "end_date", value: dayFormatter.string(from: end)),
        ]
    }

    private static func dateTimeQuery(_ start: Date, _ end: Date) -> [URLQueryItem] {
        [
            URLQueryItem(name: "start_datetime", value: iso8601.string(from: start)),
            URLQueryItem(name: "end_datetime", value: iso8601.string(from: end)),
        ]
    }
}
