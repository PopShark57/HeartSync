import Foundation
import Testing
@testable import HeartSyncChecker

/// The Oura cards as real charts (improvement 35): a timed hypnogram and movement chart,
/// a legend that names every code the colour map draws, fourteen-day trends built only
/// from cached documents, and a selectable heart-rate line.
@Suite("Oura charts")
struct OuraChartTests {

    private let bedtime = "2026-09-02T23:10:00+00:00"
    private var bedtimeDate: Date { OuraClient.parseTimestamp(bedtime)! }

    private func sleep(
        _ id: String,
        day: String,
        phases: String? = nil,
        start: String? = nil,
        end: String? = nil,
        hrv: Double? = nil,
        lowest: Double? = nil,
        type: String? = "long_sleep"
    ) -> OuraClient.SleepDocument {
        OuraClient.SleepDocument(
            id: id,
            day: day,
            bedtime_start: start,
            bedtime_end: end,
            average_hrv: hrv,
            lowest_heart_rate: lowest,
            sleep_phase_5_min: phases,
            type: type
        )
    }

    // MARK: - Hypnogram

    @Test("Stages become timed runs from bedtime, five minutes per code")
    func hypnogramRuns() throws {
        // Awake 10 min, REM 10, light 10, deep 15, awake 5.
        let timeline = try #require(OuraCategoryTimeline<OuraSleepStage>(
            sleep: sleep("s", day: "2026-09-03", phases: "4433221114", start: bedtime)
        ))
        #expect(timeline.runs.map(\.category) == [.awake, .rem, .light, .deep, .awake])
        #expect(timeline.runs.map(\.intervalCount) == [2, 2, 2, 3, 1])
        #expect(timeline.start == bedtimeDate)
        #expect(timeline.end == bedtimeDate.addingTimeInterval(10 * 300))
        #expect(timeline.runs.first?.start == bedtimeDate)
        #expect(timeline.runs.last?.end == timeline.end)
        // Runs tile the night with no overlap and no hole.
        for (earlier, later) in zip(timeline.runs, timeline.runs.dropFirst()) {
            #expect(earlier.end == later.start)
        }
        #expect(timeline.duration(of: .deep) == 900)
        #expect(timeline.duration(of: .awake) == 900)
        #expect(Set(timeline.runs.map(\.id)).count == timeline.runs.count)
    }

    @Test("The stage at a chosen moment is found with its own start and end")
    func stageAtAMoment() throws {
        let timeline = try #require(OuraCategoryTimeline<OuraSleepStage>(
            sleep: sleep("s", day: "2026-09-03", phases: "4433221114", start: bedtime)
        ))
        // 23:22 falls inside the REM run, 23:20–23:30.
        let rem = try #require(timeline.run(at: bedtimeDate.addingTimeInterval(12 * 60)))
        #expect(rem.category == .rem)
        #expect(rem.start == bedtimeDate.addingTimeInterval(600))
        #expect(rem.end == bedtimeDate.addingTimeInterval(1_200))
        // A run's end belongs to the next run, not to both.
        #expect(timeline.run(at: rem.end)?.category == .light)
        #expect(timeline.run(at: bedtimeDate)?.category == .awake)
        #expect(timeline.run(at: bedtimeDate.addingTimeInterval(-1)) == nil)
        #expect(timeline.run(at: timeline.end) == nil)
    }

    @Test("A code Oura does not define is a counted gap, never a guessed stage")
    func unknownCodesAreGaps() throws {
        let timeline = try #require(OuraCategoryTimeline<OuraSleepStage>(
            sleep: sleep("s", day: "2026-09-03", phases: "11x9922", start: bedtime)
        ))
        #expect(timeline.unrecognisedCount == 3)
        #expect(timeline.runs.map(\.category) == [.deep, .light])
        #expect(timeline.run(at: bedtimeDate.addingTimeInterval(2 * 300 + 10)) == nil)
        #expect(timeline.end == bedtimeDate.addingTimeInterval(7 * 300))
    }

    @Test("Without stages or a bedtime the section keeps its untimed ribbon")
    func hypnogramNeedsStagesAndABedtime() {
        #expect(OuraCategoryTimeline<OuraSleepStage>(sleep: sleep("s", day: "2026-09-03", phases: "1234", start: nil)) == nil)
        #expect(OuraCategoryTimeline<OuraSleepStage>(sleep: sleep("s", day: "2026-09-03", phases: "", start: bedtime)) == nil)
        #expect(OuraCategoryTimeline<OuraSleepStage>(sleep: sleep("s", day: "2026-09-03", phases: nil, start: bedtime)) == nil)
        #expect(OuraCategoryTimeline<OuraSleepStage>(sleep: sleep("s", day: "2026-09-03", phases: "1234", start: "not a time")) == nil)
    }

    // MARK: - Movement

    private func activity(timestamp: String?, classes: String? = "001233334555524001") throws -> OuraClient.DailyActivity {
        let timestampField = timestamp.map { "\"timestamp\":\"\($0)\"," } ?? ""
        let classField = classes.map { "\"class_5_min\":\"\($0)\"," } ?? ""
        let json = """
        {
          "id":"activity","day":"2026-09-03","score":81,\(timestampField)\(classField)
          "active_calories":400,"average_met_minutes":1.6,"contributors":{},
          "equivalent_walking_distance":6000,"high_activity_time":600,"inactivity_alerts":1,
          "low_activity_time":5400,"medium_activity_time":1800,"non_wear_time":900,
          "resting_time":28800,"sedentary_time":30000,"steps":8000,"target_calories":500,
          "target_meters":9000,"total_calories":2200
        }
        """
        return try JSONDecoder().decode(OuraClient.DailyActivity.self, from: Data(json.utf8))
    }

    @Test("Movement classes are timed from the activity day's own start")
    func movementIsTimed() throws {
        let day = try activity(timestamp: "2026-09-03T04:00:00-04:00")
        let timeline = try #require(OuraCategoryTimeline<OuraMovementClass>(activity: day))
        #expect(timeline.start == OuraClient.parseTimestamp("2026-09-03T04:00:00-04:00"))
        #expect(timeline.runs.first?.category == .nonWear)
        #expect(timeline.runs.first?.intervalCount == 2)
        #expect(timeline.runs.map(\.category).contains(.high))
        #expect(timeline.end == timeline.start.addingTimeInterval(18 * 300))
        #expect(timeline.unrecognisedCount == 0)
    }

    @Test("A cache from before the day's start was read decodes, and draws no guessed clock")
    func legacyActivityWithoutTimestamp() throws {
        let legacy = try activity(timestamp: nil)
        #expect(legacy.timestamp == nil)
        #expect(legacy.class_5_min == "001233334555524001")
        #expect(OuraCategoryTimeline<OuraMovementClass>(activity: legacy) == nil)

        // A whole cached snapshot written before the field existed still decodes.
        var snapshot = OuraSnapshot()
        snapshot.activities = [legacy]
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(OuraSnapshot.self, from: encoded)
        #expect(decoded.activities.first?.timestamp == nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("timestamp\":null"))
    }

    @Test("The legend names every code the movement colour map can draw, non-wear included")
    func legendCoversEveryCode() {
        let codes = OuraMovementClass.allCases.map(\.code)
        #expect(Set(codes) == Set("012345"))
        #expect(OuraMovementClass.allCases.map(\.title).contains("Non-wear"))
        for movement in OuraMovementClass.allCases {
            #expect(OuraMovementClass(code: movement.code) == movement)
        }
        #expect(OuraMovementClass(code: "6") == nil)
        // Rows stack by activity, lowest for the ring being off.
        #expect(OuraMovementClass.allCases.map(\.level) == [0, 1, 2, 3, 4, 5])
    }

    // MARK: - Trends

    private func readiness(_ day: String, score: Int?, deviation: Double? = nil, id: String? = nil) -> OuraClient.DailyReadiness {
        OuraClient.DailyReadiness(
            id: id ?? "r-\(day)",
            day: day,
            score: score,
            temperature_deviation: deviation,
            contributors: OuraClient.ScoreContributors()
        )
    }

    @Test("A trend spans fourteen calendar days ending at the newest cached day, gaps included")
    func trendSpansFourteenDays() throws {
        let trend = OuraDailyTrend.readinessScore([
            readiness("2026-09-14", score: 80),
            readiness("2026-09-12", score: 71),
            readiness("2026-09-03", score: 90),
            readiness("2026-08-20", score: 60),
            readiness("2026-09-13", score: nil),
        ])
        #expect(trend.days.count == 14)
        #expect(trend.days.first?.key == "2026-09-01")
        #expect(trend.days.last?.key == "2026-09-14")
        // Outside the fortnight: not drawn.
        #expect(!trend.days.contains { $0.value == 60 })
        // A document without a score and a day without a document are both gaps.
        #expect(trend.day(forKey: "2026-09-13")?.value == nil)
        #expect(trend.day(forKey: "2026-09-10")?.value == nil)
        #expect(trend.reportedDayCount == 3)
        #expect(trend.latest?.key == "2026-09-14")
        #expect(trend.latest?.value == 80)
        #expect(trend.lowest == 71)
        #expect(trend.highest == 90)
        #expect(trend.isDrawable)
        // Keys follow Oura's calendar day at UTC midnight, as the headline labels do.
        #expect(trend.days.last?.date == OuraClient.parseDay("2026-09-14"))
    }

    @Test("The first document for a day wins, matching the card's headline value")
    func firstDocumentPerDayWins() {
        let documents = [
            readiness("2026-09-14", score: 82, id: "first"),
            readiness("2026-09-14", score: 40, id: "second"),
        ]
        let snapshotLatest = OuraSnapshot(readiness: documents).latestReadiness
        let trend = OuraDailyTrend.readinessScore(documents)
        #expect(snapshotLatest?.id == "first")
        #expect(trend.latest?.value == 82)
    }

    @Test("One value is not a trend, and an empty collection draws nothing")
    func trendNeedsTwoDays() {
        #expect(!OuraDailyTrend.readinessScore([readiness("2026-09-14", score: 80)]).isDrawable)
        #expect(OuraDailyTrend.readinessScore([]).days.isEmpty)
        #expect(OuraDailyTrend.readinessScore([]).latest == nil)
    }

    @Test("A trend line breaks at a missing day rather than drawing through it")
    func trendSegmentsBreakAtGaps() {
        let trend = OuraDailyTrend.readinessScore([
            readiness("2026-09-01", score: 70),
            readiness("2026-09-02", score: 71),
            readiness("2026-09-05", score: 72),
            readiness("2026-09-06", score: 73),
            readiness("2026-09-14", score: 74),
        ])
        let segments = trend.segments
        #expect(segments.map(\.index) == [0, 1, 4, 5, 13])
        #expect(segments.map(\.segment) == [0, 0, 1, 1, 2])
    }

    @Test("VoiceOver hears how many days reported, the range, and the latest day")
    func trendSummaryIsSpoken() {
        let trend = OuraDailyTrend.readinessScore([
            readiness("2026-09-12", score: 71),
            readiness("2026-09-14", score: 80),
        ])
        let spoken = trend.spokenSummary { "\(Int($0)) points" }
        #expect(spoken.hasPrefix("2 of 14 days reported, from 71 points to 80 points, latest 80 points on "))
        #expect(spoken.hasSuffix(OuraClient.dayLabel(for: OuraClient.parseDay("2026-09-14")!)))
        #expect(OuraDailyTrend.readinessScore([]).spokenSummary { "\($0)" } == "No values in the last 0 days")
    }

    @Test("Temperature is a signed deviation from the Oura baseline, never an absolute reading")
    func temperatureDeviationKeepsItsSign() {
        let trend = OuraDailyTrend.temperatureDeviation([
            readiness("2026-09-13", score: 80, deviation: -0.4),
            readiness("2026-09-14", score: 82, deviation: 0.25),
        ])
        #expect(trend.days.compactMap(\.value) == [-0.4, 0.25])
        #expect(trend.lowest == -0.4)
        // Nothing here resembles a body temperature.
        #expect(trend.days.allSatisfy { ($0.value ?? 0) < 5 })
    }

    @Test("Nightly trends use each day's main sleep, the one the headline shows")
    func nightlyTrendsUseTheMainSleep() throws {
        let sleeps = [
            sleep("night-13", day: "2026-09-13", start: "2026-09-12T23:00:00+00:00", end: "2026-09-13T07:00:00+00:00", hrv: 40, lowest: 50),
            sleep("night-14", day: "2026-09-14", start: "2026-09-13T23:00:00+00:00", end: "2026-09-14T07:00:00+00:00", hrv: 44, lowest: 52),
            sleep("nap-14", day: "2026-09-14", start: "2026-09-14T13:00:00+00:00", end: "2026-09-14T13:40:00+00:00", hrv: 60, lowest: 58, type: "late_nap"),
            sleep("deleted-14", day: "2026-09-14", start: "2026-09-14T15:00:00+00:00", end: "2026-09-14T16:00:00+00:00", hrv: 99, lowest: 30, type: "deleted"),
            sleep("rest-12", day: "2026-09-12", start: "2026-09-12T10:00:00+00:00", end: "2026-09-12T11:00:00+00:00", hrv: 90, lowest: 45, type: "rest"),
        ]
        let rmssd = OuraDailyTrend.rmssd(sleeps)
        let lowest = OuraDailyTrend.lowestHeartRate(sleeps)
        // The newest day's value is the document `latestSleep` picks for the headline.
        let headline = try #require(OuraSnapshot(sleeps: sleeps).latestSleep)
        #expect(headline.id == "nap-14")
        #expect(rmssd.latest?.value == headline.average_hrv)
        #expect(lowest.latest?.value == headline.lowest_heart_rate)
        #expect(rmssd.day(forKey: "2026-09-13")?.value == 40)
        // Deleted and rest periods never enter a nightly trend.
        #expect(rmssd.day(forKey: "2026-09-12")?.value == nil)
        #expect(!rmssd.days.contains { $0.value == 99 })
    }

    // MARK: - UI-test fixture

    @MainActor
    @Test("The chart fixture the UI test opens draws every new chart")
    func chartFixtureDrawsEveryChart() throws {
        let manager = OuraManager(archive: ReadingArchive(directory: FileManager.default.temporaryDirectory))
        manager.injectChartFixtureForUITesting(now: Date(timeIntervalSince1970: 1_790_000_000))
        let cached = manager.snapshot

        let night = try #require(cached.latestSleep)
        let hypnogram = try #require(OuraCategoryTimeline<OuraSleepStage>(sleep: night))
        #expect(Set(hypnogram.runs.map(\.category)) == Set(OuraSleepStage.allCases))

        let today = try #require(cached.latestActivity)
        let movement = try #require(OuraCategoryTimeline<OuraMovementClass>(activity: today))
        #expect(Set(movement.runs.map(\.category)) == Set(OuraMovementClass.allCases))
        #expect(movement.end.timeIntervalSince(movement.start) == 86_400)

        let trends = [
            OuraDailyTrend.readinessScore(cached.readiness),
            .sleepScore(cached.sleepScores),
            .activityScore(cached.activities),
            .rmssd(cached.sleeps),
            .lowestHeartRate(cached.sleeps),
            .temperatureDeviation(cached.readiness),
        ]
        #expect(trends.allSatisfy { $0.isDrawable })
        // One missing day each, drawn as a gap rather than filled.
        #expect(OuraDailyTrend.readinessScore(cached.readiness).reportedDayCount == 13)
        #expect(OuraDailyTrend.rmssd(cached.sleeps).reportedDayCount == 13)

        // The charging gap breaks the heart-rate line.
        let heart = OuraHeartRateSeries(heartRates: cached.heartRates)
        #expect(Set(heart.points.map(\.segment)).count >= 2)
    }

    // MARK: - Heart-rate selection

    @Test("The heart-rate chart selects the nearest drawn sample, and nothing in a gap")
    func heartRateSelection() throws {
        let anchor = Date(timeIntervalSince1970: 1_756_000_000)
        func sample(_ bpm: Int, minutesBefore: Int) -> OuraClient.HeartRatePoint {
            OuraClient.HeartRatePoint(
                bpm: bpm,
                source: "awake",
                timestamp: OuraClient.iso8601.string(from: anchor.addingTimeInterval(-Double(minutesBefore) * 60))
            )
        }
        let series = OuraHeartRateSeries(heartRates:
            (0..<10).map { sample(60 + $0, minutesBefore: 300 + $0 * 5) }
            + (0..<10).map { sample(70 + $0, minutesBefore: $0 * 5) }
        )
        let domain = try #require(series.domain)
        #expect(domain.upperBound == anchor)
        #expect(domain.lowerBound == anchor.addingTimeInterval(-86_400))

        let nearNewest = try #require(series.point(nearest: anchor.addingTimeInterval(-60), within: 600))
        #expect(nearNewest.date == anchor)
        #expect(nearNewest.bpm == 70)
        // Three hours from any sample, inside the ten-minute catchment: nothing.
        #expect(series.point(nearest: anchor.addingTimeInterval(-3 * 3_600), within: 600) == nil)
        #expect(series.point(nearest: anchor.addingTimeInterval(-3 * 3_600)) != nil)
        #expect(series.point(id: nearNewest.id) == nearNewest)
        #expect(series.point(id: nil) == nil)
        #expect(OuraHeartRateSeries(heartRates: []).domain == nil)
    }
}
