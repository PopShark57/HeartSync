import Foundation

/// Fourteen calendar days of one Oura daily value, for the small trend on a score or
/// biomarker card (improvement 35).
///
/// Built from the documents already in the cache — HeartSync syncs fourteen days of each
/// collection — so a trend adds no request, no scope, and no second copy of anything. A
/// day with no document, or a document without the value, stays a gap: it is never filled
/// from a neighbour or from another collection.
///
/// Days are Oura's calendar days anchored to UTC midnight, exactly as `OuraClient.parseDay`
/// reads them, and the chart keys each day by its `key` rather than binning dates by the
/// phone's calendar, which would move a day west of Greenwich.
struct OuraDailyTrend: Equatable, Sendable {

    struct Day: Identifiable, Equatable, Sendable {
        /// UTC midnight of Oura's calendar day.
        var date: Date
        /// `yyyy-MM-dd`, the chart's categorical key.
        var key: String
        /// Nil for a day without a value: a gap, not a zero.
        var value: Double?

        var id: String { key }
    }

    static let dayCount = 14

    /// Oldest first; `dayCount` days ending at the newest day in the collection.
    let days: [Day]

    /// The newest day that has a value — the one the card highlights.
    var latest: Day? { days.last { $0.value != nil } }

    var reportedDayCount: Int { days.count { $0.value != nil } }

    /// One value is a number, not a trend.
    var isDrawable: Bool { reportedDayCount >= 2 }

    var lowest: Double? { days.compactMap(\.value).min() }
    var highest: Double? { days.compactMap(\.value).max() }

    /// - Parameter entries: `(day, value)` per document in cache order. When a day has
    ///   more than one document, the first wins — the same document the card's headline
    ///   value comes from, so the highlighted day always matches the number above it.
    init(entries: [(day: String, value: Double?)], dayCount: Int = OuraDailyTrend.dayCount) {
        var byDate: [Date: Double?] = [:]
        var newest: Date?
        for entry in entries {
            guard let date = OuraClient.parseDay(entry.day) else { continue }
            if byDate[date] == nil { byDate[date] = .some(entry.value) }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        guard let newest, dayCount > 0 else {
            self.days = []
            return
        }
        self.days = (0..<dayCount).map { offset in
            let date = newest.addingTimeInterval(-Double(dayCount - 1 - offset) * 86_400)
            return Day(date: date, key: Self.key(for: date), value: byDate[date] ?? nil)
        }
    }

    /// The day with this chart key, for a selection.
    func day(forKey key: String?) -> Day? {
        guard let key else { return nil }
        return days.first { $0.key == key }
    }

    /// A reported day's place in the trend line.
    struct Segment: Identifiable, Equatable, Sendable {
        /// Index into `days`.
        var index: Int
        /// Advances at every missing day, so the line breaks there.
        var segment: Int

        var id: Int { index }
    }

    /// Consecutive-day runs, so a trend line breaks at a missing day instead of drawing
    /// through it.
    var segments: [Segment] {
        var result: [Segment] = []
        var segment = 0
        var previous: Int?
        for (index, day) in days.enumerated() where day.value != nil {
            if let previous, index - previous > 1 { segment += 1 }
            result.append(Segment(index: index, segment: segment))
            previous = index
        }
        return result
    }

    /// The trend in one sentence for VoiceOver: how many days reported, the range, and the
    /// latest value with its day. `format` renders a value with its unit.
    func spokenSummary(format: (Double) -> String) -> String {
        guard let latest, let value = latest.value, let lowest, let highest else {
            return "No values in the last \(days.count) days"
        }
        return "\(reportedDayCount) of \(days.count) days reported, from \(format(lowest)) to \(format(highest)), latest \(format(value)) on \(OuraClient.dayLabel(for: latest.date))"
    }

    private static func key(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension OuraDailyTrend {
    static func readinessScore(_ documents: [OuraClient.DailyReadiness]) -> OuraDailyTrend {
        OuraDailyTrend(entries: documents.map { ($0.day, $0.score.map(Double.init)) })
    }

    static func sleepScore(_ documents: [OuraClient.DailySleep]) -> OuraDailyTrend {
        OuraDailyTrend(entries: documents.map { ($0.day, $0.score.map(Double.init)) })
    }

    static func activityScore(_ documents: [OuraClient.DailyActivity]) -> OuraDailyTrend {
        OuraDailyTrend(entries: documents.map { ($0.day, $0.score.map(Double.init)) })
    }

    /// Deviation from the user's own Oura baseline, in °C. Never an absolute temperature.
    static func temperatureDeviation(_ documents: [OuraClient.DailyReadiness]) -> OuraDailyTrend {
        OuraDailyTrend(entries: documents.map { ($0.day, $0.temperature_deviation) })
    }

    /// Nightly average HRV, which Oura computes as RMSSD — never SDNN.
    static func rmssd(_ sleeps: [OuraClient.SleepDocument]) -> OuraDailyTrend {
        OuraDailyTrend(entries: mainSleeps(sleeps).map { ($0.day, $0.average_hrv) })
    }

    /// Lowest heart rate of each night's main sleep.
    static func lowestHeartRate(_ sleeps: [OuraClient.SleepDocument]) -> OuraDailyTrend {
        OuraDailyTrend(entries: mainSleeps(sleeps).map { ($0.day, $0.lowest_heart_rate) })
    }

    /// One sleep document per day, chosen as `OuraSnapshot.latestSleep` chooses overall:
    /// deleted and rest periods excluded, then the latest to end. The newest day's entry is
    /// therefore the document the biomarker card's headline value comes from.
    static func mainSleeps(_ sleeps: [OuraClient.SleepDocument]) -> [OuraClient.SleepDocument] {
        let eligible = sleeps.filter { $0.type != "deleted" && $0.type != "rest" }
        var chosen: [String: OuraClient.SleepDocument] = [:]
        var order: [String] = []
        for sleep in eligible {
            guard let current = chosen[sleep.day] else {
                chosen[sleep.day] = sleep
                order.append(sleep.day)
                continue
            }
            if endDate(current) < endDate(sleep) { chosen[sleep.day] = sleep }
        }
        return order.compactMap { chosen[$0] }
    }

    private static func endDate(_ sleep: OuraClient.SleepDocument) -> Date {
        OuraClient.parseTimestamp(sleep.bedtime_end) ?? OuraClient.parseDay(sleep.day) ?? .distantPast
    }
}
