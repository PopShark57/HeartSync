import Foundation

/// A five-minute code string from Oura — sleep stages or activity classes — as timed runs.
///
/// Oura publishes `sleep_phase_5_min` and `class_5_min` as one character per five minutes
/// from a known start: `bedtime_start` for a sleep, the activity day's `timestamp` (4 a.m.
/// in the ring's zone) for movement. Drawing each run of identical codes as one rectangle
/// on a clock turns an untimed ribbon into a chart a reader can place in the night or the
/// day (improvement 35).
///
/// These are Oura's classifications, drawn as delivered: HeartSync does not stage sleep or
/// classify movement. A code Oura does not define is left as a gap and counted, never
/// guessed into a stage or class.
struct OuraCategoryTimeline<Category: Hashable & Sendable>: Sendable {

    /// Consecutive intervals with the same code.
    struct Run: Identifiable, Hashable, Sendable {
        var category: Category
        var start: Date
        var end: Date
        /// Five-minute intervals in the run.
        var intervalCount: Int
        /// Position of the run's first interval in the code string, unique per run.
        var id: Int

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Oura's step for both code strings.
    static var intervalLength: TimeInterval { 300 }

    let start: Date
    /// Start plus one interval per code, recognised or not.
    let end: Date
    /// In time order, never overlapping.
    let runs: [Run]
    /// Intervals whose code Oura does not define, drawn as gaps.
    let unrecognisedCount: Int
    /// `runs[i].start` as reference-date seconds, ascending.
    private let runStarts: [Double]

    init(codes: String, start: Date, category: (Character) -> Category?) {
        let step = Self.intervalLength
        var runs: [Run] = []
        var unrecognised = 0
        var pending: (category: Category, first: Int, count: Int)?

        func close() {
            guard let current = pending else { return }
            runs.append(Run(
                category: current.category,
                start: start.addingTimeInterval(Double(current.first) * step),
                end: start.addingTimeInterval(Double(current.first + current.count) * step),
                intervalCount: current.count,
                id: current.first
            ))
            pending = nil
        }

        var count = 0
        for (index, code) in codes.enumerated() {
            count += 1
            guard let category = category(code) else {
                close()
                unrecognised += 1
                continue
            }
            if let current = pending, current.category == category {
                pending = (category, current.first, current.count + 1)
            } else {
                close()
                pending = (category, index, 1)
            }
        }
        close()

        self.start = start
        self.end = start.addingTimeInterval(Double(count) * step)
        self.runs = runs
        self.unrecognisedCount = unrecognised
        self.runStarts = runs.map { $0.start.timeIntervalSinceReferenceDate }
    }

    /// The run covering `date`, or nil in a gap or outside the timeline.
    func run(at date: Date) -> Run? {
        guard let index = ChartLookup.lastIndex(
            atOrBefore: date.timeIntervalSinceReferenceDate,
            in: runStarts
        ) else { return nil }
        let run = runs[index]
        return date < run.end ? run : nil
    }

    /// Total time Oura assigned to `category`.
    func duration(of category: Category) -> TimeInterval {
        runs.filter { $0.category == category }.reduce(0) { $0 + $1.duration }
    }
}

extension OuraCategoryTimeline where Category == OuraSleepStage {
    /// A hypnogram for one sleep document. Nil without stages or a bedtime to time them
    /// from: an undated string cannot be put on a clock, and the section keeps its untimed
    /// ribbon instead.
    init?(sleep: OuraClient.SleepDocument) {
        guard let phases = sleep.sleep_phase_5_min, !phases.isEmpty,
              let start = OuraClient.parseTimestamp(sleep.bedtime_start)
        else { return nil }
        self.init(codes: phases, start: start, category: OuraSleepStage.init(code:))
    }
}

extension OuraCategoryTimeline where Category == OuraMovementClass {
    /// The activity day's movement classes. Nil without classes or the day's own start
    /// time: a cache written before HeartSync read `timestamp` keeps the untimed ribbon
    /// until the next sync fills it in, rather than guessing when the day began.
    init?(activity: OuraClient.DailyActivity) {
        guard let classes = activity.class_5_min, !classes.isEmpty,
              let start = OuraClient.parseTimestamp(activity.timestamp)
        else { return nil }
        self.init(codes: classes, start: start, category: OuraMovementClass.init(code:))
    }
}
