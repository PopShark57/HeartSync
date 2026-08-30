import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Oura data models")
struct OuraDataModelTests {

    @Test("Daily activity decodes Oura movement totals and sampled MET data")
    func dailyActivityDecoding() throws {
        let activity = try decode(OuraClient.DailyActivity.self, OuraFixtures.dailyActivity)

        #expect(activity.id == "activity-current")
        #expect(activity.day == "2026-08-28")
        #expect(activity.score == 88)
        #expect(activity.active_calories == 456)
        #expect(activity.average_met_minutes == 1.75)
        #expect(activity.class_5_min == "012345")
        #expect(activity.contributors.meet_daily_targets == 85)
        #expect(activity.met?.interval == 60)
        #expect(activity.met?.items == [1.0, nil, 2.4])
        #expect(activity.steps == 9_123)
        #expect(activity.total_calories == 2_300)
    }

    @Test("Detailed sleep decodes movement, stages, signals, and readiness")
    func detailedSleepDecoding() throws {
        let sleep = try decode(OuraClient.SleepDocument.self, OuraFixtures.detailedSleep)

        #expect(sleep.id == "sleep-current")
        #expect(sleep.average_hrv == 42)
        #expect(sleep.deep_sleep_duration == 5_400)
        #expect(sleep.movement_30_sec == "1143222134")
        #expect(sleep.sleep_phase_5_min == "4433221114")
        #expect(sleep.heart_rate?.items == [54, nil, 52])
        #expect(sleep.hrv?.interval == 300)
        #expect(sleep.readiness?.score == 82)
        #expect(sleep.readiness?.contributors?.hrv_balance == 79)
        #expect(sleep.total_sleep_duration == 25_200)
        #expect(sleep.type == "long_sleep")
    }

    @Test("Daily scores, stress, resilience, and cardiovascular age decode")
    func dailyWellnessDecoding() throws {
        let readiness = try decode(OuraClient.DailyReadiness.self, OuraFixtures.readiness)
        let sleep = try decode(OuraClient.DailySleep.self, OuraFixtures.dailySleep)
        let stress = try decode(OuraClient.DailyStress.self, OuraFixtures.stress)
        let resilience = try decode(OuraClient.DailyResilience.self, OuraFixtures.resilience)
        let cardiovascularAge = try decode(
            OuraClient.DailyCardiovascularAge.self,
            OuraFixtures.cardiovascularAge
        )

        #expect(readiness.score == 84)
        #expect(readiness.temperature_deviation == 0.12)
        #expect(readiness.contributors.resting_heart_rate == 91)
        #expect(sleep.score == 87)
        #expect(sleep.contributors.deep_sleep == 76)
        #expect(stress.day_summary == "restored")
        #expect(stress.recovery_high == 7_200)
        #expect(stress.stress_high == 1_800)
        #expect(resilience.level == "strong")
        #expect(resilience.contributors.daytime_recovery == 74.5)
        #expect(resilience.contributors.sleep_recovery == 81)
        #expect(resilience.contributors.stress == 69.25)
        #expect(cardiovascularAge.pulse_wave_velocity == 6.7)
        #expect(cardiovascularAge.vascular_age == 36)
    }

    @Test("Ring battery and configuration decode current API shapes")
    func ringDecoding() throws {
        let battery = try decode(OuraClient.RingBatteryLevel.self, OuraFixtures.battery)
        let ring = try decode(OuraClient.RingConfiguration.self, OuraFixtures.ring)

        #expect(battery.timestamp_unix == 1_777_030_400_000)
        #expect(battery.level == 73)
        #expect(battery.charging == false)
        #expect(battery.in_charger == false)
        #expect(ring.id == "ring-current")
        #expect(ring.color == "brushed_silver")
        #expect(ring.design == "horizon")
        #expect(ring.firmware_version == "3.1.0")
        #expect(ring.hardware_type == "gen4")
        #expect(ring.size == 10)
    }

    @Test("Snapshot counts records and selects the newest usable values")
    func snapshotSelectorsAndCount() throws {
        let activity = try decode(OuraClient.DailyActivity.self, OuraFixtures.dailyActivity)
        var oldActivity = activity
        oldActivity.id = "activity-old"
        oldActivity.day = "2026-08-27"

        let readiness = try decode(OuraClient.DailyReadiness.self, OuraFixtures.readiness)
        var oldReadiness = readiness
        oldReadiness.id = "readiness-old"
        oldReadiness.day = "2026-08-27"

        let dailySleep = try decode(OuraClient.DailySleep.self, OuraFixtures.dailySleep)
        var oldDailySleep = dailySleep
        oldDailySleep.id = "daily-sleep-old"
        oldDailySleep.day = "2026-08-27"

        let sleep = try decode(OuraClient.SleepDocument.self, OuraFixtures.detailedSleep)
        var oldSleep = sleep
        oldSleep.id = "sleep-old"
        oldSleep.day = "2026-08-27"
        oldSleep.bedtime_end = "2026-08-27T07:00:00-04:00"
        var newerRest = sleep
        newerRest.id = "rest-newer"
        newerRest.day = "2026-08-29"
        newerRest.bedtime_end = "2026-08-29T15:00:00-04:00"
        newerRest.type = "rest"

        let oxygen = try decode(OuraClient.DailySpO2.self, OuraFixtures.oxygen)
        var oldOxygen = oxygen
        oldOxygen.id = "oxygen-old"
        oldOxygen.day = "2026-08-27"

        let stress = try decode(OuraClient.DailyStress.self, OuraFixtures.stress)
        var oldStress = stress
        oldStress.id = "stress-old"
        oldStress.day = "2026-08-27"

        let resilience = try decode(OuraClient.DailyResilience.self, OuraFixtures.resilience)
        var oldResilience = resilience
        oldResilience.id = "resilience-old"
        oldResilience.day = "2026-08-27"

        let cardiovascularAge = try decode(
            OuraClient.DailyCardiovascularAge.self,
            OuraFixtures.cardiovascularAge
        )
        var oldCardiovascularAge = cardiovascularAge
        oldCardiovascularAge.id = "cardio-old"
        oldCardiovascularAge.day = "2026-08-27"

        let vo2Max = try decode(OuraClient.VO2MaxDocument.self, OuraFixtures.vo2Max)
        var oldVO2Max = vo2Max
        oldVO2Max.id = "vo2-old"
        oldVO2Max.day = "2026-08-27"

        let battery = try decode(OuraClient.RingBatteryLevel.self, OuraFixtures.battery)
        var oldBattery = battery
        oldBattery.timestamp = "2026-04-22T11:00:00Z"
        oldBattery.timestamp_unix -= 3_600_000
        oldBattery.level = 69

        let ring = try decode(OuraClient.RingConfiguration.self, OuraFixtures.ring)
        var oldRing = ring
        oldRing.id = "ring-old"
        oldRing.set_up_at = "2025-01-01T00:00:00Z"

        var snapshot = OuraSnapshot()
        snapshot.heartRates = [
            .init(bpm: 61, source: "rest", timestamp: "2026-08-28T10:00:00Z"),
            .init(bpm: 64, source: "awake", timestamp: "2026-08-28T11:00:00Z"),
        ]
        snapshot.activities = [activity, oldActivity]
        snapshot.readiness = [readiness, oldReadiness]
        snapshot.sleepScores = [dailySleep, oldDailySleep]
        snapshot.sleeps = [newerRest, sleep, oldSleep]
        snapshot.oxygen = [oxygen, oldOxygen]
        snapshot.stress = [stress, oldStress]
        snapshot.resilience = [resilience, oldResilience]
        snapshot.cardiovascularAge = [cardiovascularAge, oldCardiovascularAge]
        snapshot.vo2Max = [vo2Max, oldVO2Max]
        snapshot.batteryLevels = [battery, oldBattery]
        snapshot.ringConfigurations = [ring, oldRing]

        #expect(snapshot.hasData)
        #expect(snapshot.totalRecordCount == 25)
        #expect(snapshot.latestHeartRate?.bpm == 64)
        #expect(snapshot.latestActivity?.id == "activity-current")
        #expect(snapshot.latestReadiness?.id == "readiness-current")
        #expect(snapshot.latestSleepScore?.id == "daily-sleep-current")
        #expect(snapshot.latestSleep?.id == "sleep-current")
        #expect(snapshot.latestOxygen?.id == "oxygen-current")
        #expect(snapshot.latestStress?.id == "stress-current")
        #expect(snapshot.latestResilience?.id == "resilience-current")
        #expect(snapshot.latestCardiovascularAge?.id == "cardio-current")
        #expect(snapshot.latestVO2Max?.id == "vo2-current")
        #expect(snapshot.latestBatteryLevel?.level == 73)
        #expect(snapshot.currentRing?.id == "ring-current")
        #expect(!OuraSnapshot().hasData)
        #expect(OuraSnapshot().totalRecordCount == 0)
    }

    @MainActor
    @Test("Corrected Oura readings replace the same stable id instead of duplicating")
    func correctedOuraReadingUpsert() {
        let store = HealthStore()
        let stableID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let timestamp = Date(timeIntervalSince1970: 1_777_030_400)
        let first = Reading(
            id: stableID,
            sourceID: DataSource.ouraSourceID,
            kind: .heartRate,
            value: 61,
            start: timestamp
        )
        let corrected = Reading(
            id: stableID,
            sourceID: DataSource.ouraSourceID,
            kind: .heartRate,
            value: 63,
            start: timestamp
        )

        #expect(store.upsert(contentsOf: [first]) == 1)
        #expect(store.upsert(contentsOf: [corrected]) == 1)
        #expect(store.readings.count == 1)
        #expect(store.readings.first?.id == stableID)
        #expect(store.readings.first?.value == 63)
        #expect(store.upsert(contentsOf: [corrected]) == 0)
        #expect(store.readings.count == 1)
    }
}

@Suite("Oura API transport")
struct OuraDataTransportTests {

    @Test("Daily and time-series collections use their documented query styles")
    func requestPathsAndQueries() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OuraRequestShapeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OuraClient(accessToken: "test-token", session: session)
        let dayStart = try #require(OuraClient.parseDay("2026-08-01"))
        let dayEnd = try #require(OuraClient.parseDay("2026-08-03"))
        let timeStart = try #require(OuraClient.parseTimestamp("2026-08-01T12:00:00Z"))
        let timeEnd = try #require(OuraClient.parseTimestamp("2026-08-03T12:00:00Z"))

        #expect(try await client.dailyActivity(from: dayStart, to: dayEnd).isEmpty)
        #expect(try await client.heartRate(from: timeStart, to: timeEnd).isEmpty)
    }

    @Test("Structured Oura 403 detail is retained")
    func structuredForbiddenDetail() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OuraForbiddenURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OuraClient(accessToken: "test-token", session: session)
        let start = try #require(OuraClient.parseTimestamp("2026-08-01T12:00:00Z"))
        let end = try #require(OuraClient.parseTimestamp("2026-08-03T12:00:00Z"))

        do {
            _ = try await client.dailyActivity(from: start, to: end)
            Issue.record("Expected a structured forbidden response")
        } catch let failure as OuraClient.Failure {
            #expect(failure == .forbidden("Missing required scope: daily"))
        }
    }
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private enum OuraFixtures {
    static let dailyActivity = #"""
    {
      "id":"activity-current","day":"2026-08-28","score":88,
      "active_calories":456,"average_met_minutes":1.75,"class_5_min":"012345",
      "contributors":{"meet_daily_targets":85,"move_every_hour":90,"stay_active":82},
      "equivalent_walking_distance":7350,"high_activity_met_minutes":72,
      "high_activity_time":900,"inactivity_alerts":2,"low_activity_met_minutes":100,
      "low_activity_time":3600,"medium_activity_met_minutes":80,"medium_activity_time":1800,
      "met":{"interval":60,"items":[1.0,null,2.4],"timestamp":"2026-08-28T04:00:00-04:00"},
      "meters_to_target":1000,"non_wear_time":120,"resting_time":36000,
      "sedentary_met_minutes":300,"sedentary_time":18000,"steps":9123,
      "target_calories":500,"target_meters":8000,
      "timestamp":"2026-08-28T04:00:00-04:00","total_calories":2300
    }
    """#

    static let detailedSleep = #"""
    {
      "id":"sleep-current","day":"2026-08-28",
      "bedtime_start":"2026-08-27T23:00:00-04:00","bedtime_end":"2026-08-28T07:00:00-04:00",
      "average_breath":14.2,"average_heart_rate":56.4,"average_hrv":42,"lowest_heart_rate":49,
      "awake_time":1800,"deep_sleep_duration":5400,"efficiency":91,
      "heart_rate":{"interval":300,"items":[54,null,52],"timestamp":"2026-08-27T23:00:00-04:00"},
      "hrv":{"interval":300,"items":[39,42,45],"timestamp":"2026-08-27T23:00:00-04:00"},
      "latency":720,"light_sleep_duration":12600,"low_battery_alert":false,
      "movement_30_sec":"1143222134",
      "readiness":{"contributors":{"hrv_balance":79,"resting_heart_rate":88},"score":82,
                   "temperature_deviation":0.1,"temperature_trend_deviation":0.03},
      "rem_sleep_duration":7200,"restless_periods":12,"ring_id":"encrypted-ring",
      "sleep_phase_30_sec":"4433221114","sleep_phase_5_min":"4433221114",
      "time_in_bed":28800,"total_sleep_duration":25200,"type":"long_sleep","period":1
    }
    """#

    static let readiness = #"""
    {"id":"readiness-current","day":"2026-08-28","score":84,
     "temperature_deviation":0.12,"temperature_trend_deviation":0.04,
     "contributors":{"activity_balance":80,"hrv_balance":78,"resting_heart_rate":91},
     "timestamp":"2026-08-28T04:00:00-04:00"}
    """#

    static let dailySleep = #"""
    {"id":"daily-sleep-current","day":"2026-08-28","score":87,
     "contributors":{"deep_sleep":76,"efficiency":92,"rem_sleep":81,"total_sleep":88},
     "timestamp":"2026-08-28T04:00:00-04:00"}
    """#

    static let stress = #"""
    {"id":"stress-current","day":"2026-08-28","day_summary":"restored",
     "recovery_high":7200,"stress_high":1800}
    """#

    static let resilience = #"""
    {"id":"resilience-current","day":"2026-08-28","level":"strong",
     "contributors":{"daytime_recovery":74.5,"sleep_recovery":81.0,"stress":69.25}}
    """#

    static let cardiovascularAge = #"""
    {"id":"cardio-current","day":"2026-08-28","pulse_wave_velocity":6.7,"vascular_age":36}
    """#

    static let oxygen = #"""
    {"id":"oxygen-current","day":"2026-08-28","spo2_percentage":{"average":96.4},
     "breathing_disturbance_index":2}
    """#

    static let vo2Max = #"""
    {"id":"vo2-current","day":"2026-08-28","timestamp":"2026-08-28T12:00:00Z","vo2_max":46.2}
    """#

    static let battery = #"""
    {"timestamp":"2026-04-22T12:00:00Z","timestamp_unix":1777030400000,
     "charging":false,"in_charger":false,"level":73}
    """#

    static let ring = #"""
    {"id":"ring-current","color":"brushed_silver","design":"horizon",
     "firmware_version":"3.1.0","hardware_type":"gen4",
     "set_up_at":"2026-01-15T12:00:00Z","size":10}
    """#
}

private enum OuraURLProtocolError: LocalizedError {
    case unexpectedRequest(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedRequest(let message): message
        }
    }
}

private final class OuraRequestShapeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url,
                  url.scheme == "https",
                  url.host == "api.ouraring.com",
                  request.httpMethod == "GET",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token",
                  request.value(forHTTPHeaderField: "Accept") == "application/json",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { throw OuraURLProtocolError.unexpectedRequest("Missing URL or request headers") }

            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                item in item.value.map { (item.name, $0) }
            })
            switch components.path {
            case "/v2/usercollection/daily_activity":
                guard query["start_date"] == "2026-08-01",
                      query["end_date"] == "2026-08-03",
                      query["start_datetime"] == nil,
                      query["end_datetime"] == nil
                else { throw OuraURLProtocolError.unexpectedRequest("Daily query used the wrong parameters") }
            case "/v2/usercollection/heartrate":
                guard query["start_datetime"] == "2026-08-01T12:00:00Z",
                      query["end_datetime"] == "2026-08-03T12:00:00Z",
                      query["start_date"] == nil,
                      query["end_date"] == nil
                else { throw OuraURLProtocolError.unexpectedRequest("Time-series query used the wrong parameters") }
            default:
                throw OuraURLProtocolError.unexpectedRequest("Unexpected path: \(components.path)")
            }

            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"data":[],"next_token":null}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class OuraForbiddenURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: OuraURLProtocolError.unexpectedRequest("Missing URL")
            )
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data(
            #"{"status":403,"title":"Forbidden","detail":"Missing required scope: daily"}"#.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
