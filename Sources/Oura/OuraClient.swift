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

        /// User-facing failure text.
        ///
        /// Where Oura itself supplied a `detail`, that server string is shown unchanged:
        /// it is already the most specific explanation available and HeartSync must not
        /// paraphrase it. Only HeartSync's own fallback wording is localized.
        var errorDescription: String? {
            switch self {
            case .missingToken:
                String(localized: "oura.failure.missingToken", defaultValue: "No Oura authorization is saved. Connect your Oura account to sync.", comment: "Oura API error: no credential in Keychain. Oura is a brand name and is not translated.")
            case .unauthorized(let detail):
                detail ?? String(localized: "oura.failure.unauthorized", defaultValue: "Oura authorization expired or was revoked. Connect your account again.", comment: "Oura API error: HTTP 401 with no server detail")
            case .forbidden(let detail):
                detail ?? String(localized: "oura.failure.forbidden", defaultValue: "Oura denied this data request. Its permission may be missing, or the Oura membership may not include API access.", comment: "Oura API error: HTTP 403 with no server detail")
            case .rateLimited(let retryAfter, let detail):
                if let detail { detail }
                else if let retryAfter {
                    String(localized: "oura.failure.rateLimited.retryAfter", defaultValue: "Oura is rate-limiting requests. Try again in \(retryAfter) seconds.", comment: "Oura API error: HTTP 429 where the server sent a Retry-After delay in seconds")
                } else {
                    String(localized: "oura.failure.rateLimited", defaultValue: "Oura is rate-limiting requests. HeartSync will try again later.", comment: "Oura API error: HTTP 429 with no Retry-After header")
                }
            case .http(let code, let detail):
                detail ?? String(localized: "oura.failure.http", defaultValue: "Oura returned HTTP \(code).", comment: "Oura API error: an unexpected HTTP status code with no server detail")
            case .transport(let message):
                String(localized: "oura.failure.transport", defaultValue: "Could not reach Oura: \(message)", comment: "Oura API error: the request never completed. The placeholder is the system network error.")
            case .decoding(let message):
                String(localized: "oura.failure.decoding", defaultValue: "Oura returned data HeartSync could not read: \(message)", comment: "Oura API error: the response did not decode. The placeholder is the decoding error.")
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

    /// The records of a paginated collection together with whether the page walk was cut
    /// short by this client's own ceiling.
    ///
    /// Returning a bare array made that ceiling invisible: the caller marked the collection
    /// available with a record count and the UI presented a partial fortnight as complete.
    /// Truncation therefore travels with the data. The `RandomAccessCollection` conformance
    /// keeps `count`, `isEmpty`, and iteration working for callers that only want records.
    struct PagedResult<Element: Sendable>: RandomAccessCollection, Sendable {
        var records: [Element]
        /// True when Oura still offered a `next_token` at the page ceiling, so the caller
        /// holds a prefix of the collection rather than all of it.
        var isTruncated: Bool

        var startIndex: Int { records.startIndex }
        var endIndex: Int { records.endIndex }
        subscript(position: Int) -> Element { records[position] }
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
        var email: String?
    }

    // MARK: - Requests

    func personalInfo() async throws -> PersonalInfo {
        try await get(PersonalInfo.self, path: "personal_info", query: [])
    }

    func heartRate(from start: Date, to end: Date) async throws -> PagedResult<HeartRatePoint> {
        try await paged(HeartRatePoint.self, path: "heartrate", query: Self.dateTimeQuery(start, end))
    }

    func ringBatteryLevels(from start: Date, to end: Date) async throws -> PagedResult<RingBatteryLevel> {
        try await paged(RingBatteryLevel.self, path: "ring_battery_level", query: Self.dateTimeQuery(start, end))
    }

    func dailyActivity(from start: Date, to end: Date) async throws -> PagedResult<DailyActivity> {
        try await paged(DailyActivity.self, path: "daily_activity", query: Self.dayQuery(start, end))
    }

    func dailyReadiness(from start: Date, to end: Date) async throws -> PagedResult<DailyReadiness> {
        try await paged(DailyReadiness.self, path: "daily_readiness", query: Self.dayQuery(start, end))
    }

    func dailySleep(from start: Date, to end: Date) async throws -> PagedResult<DailySleep> {
        try await paged(DailySleep.self, path: "daily_sleep", query: Self.dayQuery(start, end))
    }

    func dailySpO2(from start: Date, to end: Date) async throws -> PagedResult<DailySpO2> {
        try await paged(DailySpO2.self, path: "daily_spo2", query: Self.dayQuery(start, end))
    }

    func dailyStress(from start: Date, to end: Date) async throws -> PagedResult<DailyStress> {
        try await paged(DailyStress.self, path: "daily_stress", query: Self.dayQuery(start, end))
    }

    func dailyResilience(from start: Date, to end: Date) async throws -> PagedResult<DailyResilience> {
        try await paged(DailyResilience.self, path: "daily_resilience", query: Self.dayQuery(start, end))
    }

    func dailyCardiovascularAge(from start: Date, to end: Date) async throws -> PagedResult<DailyCardiovascularAge> {
        try await paged(DailyCardiovascularAge.self, path: "daily_cardiovascular_age", query: Self.dayQuery(start, end))
    }

    func sleep(from start: Date, to end: Date) async throws -> PagedResult<SleepDocument> {
        try await paged(SleepDocument.self, path: "sleep", query: Self.dayQuery(start, end))
    }

    func sleepTime(from start: Date, to end: Date) async throws -> PagedResult<SleepTimeDocument> {
        try await paged(SleepTimeDocument.self, path: "sleep_time", query: Self.dayQuery(start, end))
    }

    func vo2Max(from start: Date, to end: Date) async throws -> PagedResult<VO2MaxDocument> {
        try await paged(VO2MaxDocument.self, path: "vO2_max", query: Self.dayQuery(start, end))
    }

    func workouts(from start: Date, to end: Date) async throws -> PagedResult<Workout> {
        try await paged(Workout.self, path: "workout", query: Self.dayQuery(start, end))
    }

    func sessions(from start: Date, to end: Date) async throws -> PagedResult<SessionDocument> {
        try await paged(SessionDocument.self, path: "session", query: Self.dayQuery(start, end))
    }

    func tags(from start: Date, to end: Date) async throws -> PagedResult<TagDocument> {
        try await paged(TagDocument.self, path: "tag", query: Self.dayQuery(start, end))
    }

    func enhancedTags(from start: Date, to end: Date) async throws -> PagedResult<EnhancedTagDocument> {
        try await paged(EnhancedTagDocument.self, path: "enhanced_tag", query: Self.dayQuery(start, end))
    }

    func restModePeriods(from start: Date, to end: Date) async throws -> PagedResult<RestModePeriod> {
        try await paged(RestModePeriod.self, path: "rest_mode_period", query: Self.dayQuery(start, end))
    }

    func ringConfigurations() async throws -> PagedResult<RingConfiguration> {
        try await paged(RingConfiguration.self, path: "ring_configuration", query: [])
    }

    // MARK: - Transport

    /// Bounds one collection's page walk so a deep or looping cursor cannot hold a
    /// sequential sync open indefinitely.
    private static let maximumPages = 25

    /// A rate limit is retried at most this many times before the failure is surfaced.
    private static let maximumRateLimitRetries = 2

    /// The longest this client will sleep inline for a single `Retry-After`.
    ///
    /// A sync issues 19 sequential requests; sleeping through a minute-long wait on each of
    /// them would stall the cycle for a quarter of an hour. A longer wait is therefore not
    /// slept through at all — the failure is reported so `OuraManager` can back off its own
    /// sync cadence, which is the right place for a multi-minute wait.
    private static let maximumRateLimitWait: TimeInterval = 8

    private func paged<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem]
    ) async throws -> PagedResult<T> {
        var results: [T] = []
        var nextToken: String?
        var pagesRemaining = Self.maximumPages

        repeat {
            var pageQuery = query
            if let nextToken { pageQuery.append(URLQueryItem(name: "next_token", value: nextToken)) }
            let page: Page<T> = try await get(Page<T>.self, path: path, query: pageQuery)
            results.append(contentsOf: page.data)
            nextToken = page.next_token
            pagesRemaining -= 1
        } while nextToken != nil && pagesRemaining > 0

        // A surviving token means Oura had more to give: the caller holds a prefix, and
        // must not describe it as the whole collection.
        return PagedResult(records: results, isTruncated: nextToken != nil)
    }

    /// Performs one request, retrying only a rate limit and only within the bounds above.
    ///
    /// Task cancellation ends the wait immediately; the original rate-limit failure is then
    /// reported rather than the sleep's cancellation, because that is the condition the
    /// caller has to reason about.
    private func get<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem]
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await perform(type, path: path, query: query)
            } catch let failure as Failure {
                guard case .rateLimited(let retryAfter, _) = failure,
                      attempt < Self.maximumRateLimitRetries,
                      !Task.isCancelled,
                      let delay = Self.rateLimitDelay(retryAfter: retryAfter, attempt: attempt)
                else { throw failure }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    throw failure
                }
                attempt += 1
            }
        }
    }

    /// Nil means "do not retry here": Oura asked for longer than this client is willing to
    /// hold the sync open. Without a `Retry-After` header the wait doubles from one second.
    private static func rateLimitDelay(retryAfter: Int?, attempt: Int) -> TimeInterval? {
        guard let retryAfter else {
            return min(maximumRateLimitWait, TimeInterval(1 << attempt))
        }
        guard retryAfter > 0 else { return 0 }
        let requested = TimeInterval(retryAfter)
        return requested <= maximumRateLimitWait ? requested : nil
    }

    private func perform<T: Decodable & Sendable>(
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
        // The problem envelope is decoded only on a failure. Decoding it ahead of the status
        // check parsed every successful response twice, including multi-megabyte heart-rate
        // pages, for a detail string that a 2xx body never carries.
        switch http.statusCode {
        case 200...299: break
        case 401: throw Failure.unauthorized(Self.problemDetail(data))
        case 403: throw Failure.forbidden(Self.problemDetail(data))
        case 429:
            throw Failure.rateLimited(
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init),
                detail: Self.problemDetail(data)
            )
        default: throw Failure.http(http.statusCode, Self.problemDetail(data))
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure.decoding(error.localizedDescription)
        }
    }

    private static func problemDetail(_ data: Data) -> String? {
        (try? JSONDecoder().decode(APIProblem.self, from: data))?.bestMessage
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

    /// Oura's `day` is a calendar date in the ring's own timezone, and the API never says
    /// which zone that was. Parsing it in `TimeZone.current` made the decoded instant depend
    /// on where the phone was standing: after the user changed zones the same document
    /// produced a different `Reading.start`, silently moving archived history between
    /// comparison windows.
    ///
    /// UTC is used instead. Determinism matters more here than a few hours of nominal
    /// offset, because these readings are compared in 86,400-second epoch-aligned buckets
    /// and UTC midnight is exactly a bucket boundary — a day document lands inside one whole
    /// window instead of straddling two, in every timezone, forever.
    ///
    /// Reading identity is deliberately unaffected. `oura.spo2.<document id>`,
    /// `oura.sleep.<document id>.<tag>`, `oura.vo2.<document id>` and
    /// `oura.hr.<timestamp string>` are all derived from Oura's own strings and never from a
    /// parsed `Date`, so no stable id moves and `upsert` still corrects a reading in place
    /// rather than duplicating it. Archived readings keep their old `start` until the next
    /// sync re-fetches that day and upserts them under the same id.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Display formatter for day strings, anchored to the same zone as `dayFormatter`.
    ///
    /// `parseDay` returns UTC midnight, so rendering that date in the phone's zone would
    /// print "Aug 31" for `2026-09-01` anywhere west of Greenwich. Only the calendar date is
    /// zone-pinned; the format itself still follows the user's locale.
    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .gmt
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter
    }()

    static func parseDay(_ string: String) -> Date? { dayFormatter.date(from: string) }

    /// Nil when `day` is not a `yyyy-MM-dd` string; callers show the raw value instead.
    static func dayLabel(_ day: String) -> String? {
        guard let date = parseDay(day) else { return nil }
        return dayLabelFormatter.string(from: date)
    }

    /// For dates that came from `parseDay`, where the local zone must not shift the label.
    static func dayLabel(for date: Date) -> String { dayLabelFormatter.string(from: date) }

    /// Day queries are widened by a day on each side.
    ///
    /// The window bounds are instants, but the API filters on calendar dates in Oura's
    /// reckoning. Formatting those instants in UTC can name a date one short of what the
    /// user considers today or a fortnight ago. A day of padding absorbs that entirely; the
    /// extra documents are merged by id, so they cost one comparison, not a duplicate.
    static let dayQueryPadding: TimeInterval = 86_400

    private static func dayQuery(_ start: Date, _ end: Date) -> [URLQueryItem] {
        [
            URLQueryItem(
                name: "start_date",
                value: dayFormatter.string(from: start.addingTimeInterval(-dayQueryPadding))
            ),
            URLQueryItem(
                name: "end_date",
                value: dayFormatter.string(from: end.addingTimeInterval(dayQueryPadding))
            ),
        ]
    }

    private static func dateTimeQuery(_ start: Date, _ end: Date) -> [URLQueryItem] {
        [
            URLQueryItem(name: "start_datetime", value: iso8601.string(from: start)),
            URLQueryItem(name: "end_datetime", value: iso8601.string(from: end)),
        ]
    }
}
