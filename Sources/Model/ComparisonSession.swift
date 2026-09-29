import Foundation

/// A comparison period: either a rolling preset or an exact, fixed span.
///
/// `TimeRange` alone is always relative to `.now`, which is right for browsing and wrong
/// for revisiting. Re-opening "the walk I did on Tuesday" a day later must analyse the same
/// seconds, not a window that has slid forward — otherwise late-arriving cloud or HealthKit
/// data for that walk can never be compared against what was there before.
enum ComparisonPeriod: Hashable, Sendable {
    case rolling(TimeRange)
    case fixed(DateInterval)

    /// Resolved span. A rolling period resolves against the current time on each read; a
    /// fixed one returns the same interval forever.
    var interval: DateInterval {
        switch self {
        case .rolling(let range): range.interval
        case .fixed(let interval): interval
        }
    }

    /// Whether re-reading this period yields the same seconds every time.
    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .rolling(let range): range.title
        case .fixed(let interval):
            String(
                localized: "comparisonPeriod.fixed",
                defaultValue: "\(interval.start.formatted(date: .abbreviated, time: .shortened)) to \(interval.end.formatted(date: .omitted, time: .shortened))",
                comment: "A saved comparison's exact span. The first argument is the start date and time, the second the end time."
            )
        }
    }

    /// The preset whose zoom suits this period: its own preset when rolling, otherwise the
    /// shortest preset that covers the fixed span. Chart bucket and axis labels follow it.
    var displayRange: TimeRange {
        switch self {
        case .rolling(let range): range
        case .fixed(let interval): TimeRange.fitting(duration: interval.duration)
        }
    }

    /// Chart bucket for this period, never finer than the preset that fits it.
    var chartBucket: TimeInterval { displayRange.chartBucket }

    /// The rolling preset, or nil for a fixed span that no picker selection describes.
    var rollingRange: TimeRange? {
        if case .rolling(let range) = self { return range }
        return nil
    }
}

/// A saved, re-openable comparison.
///
/// Stores only the *selection* — an exact period, the sources, and the user's own label for
/// what they were doing. It never stores readings or results: re-opening re-runs the
/// analysis against the current database, which is the point, because data for that period
/// keeps arriving from HealthKit and Oura after the fact.
///
/// A saved session is therefore not an exported result. `PairwiseExporter` produces the
/// artefact that does not change; this produces a view that deliberately does.
struct ComparisonSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// User-entered title. Empty is allowed; the list falls back to the period.
    var title: String
    /// User-entered context such as "resting", "walk", "run".
    ///
    /// Explicitly the user's own words. HeartSync does not read workout metadata from
    /// HealthKit, and must not imply that this label came from a recorded workout.
    var context: String
    /// The exact span analysed. Fixed by construction: a saved session that slid with the
    /// clock would not be the same session.
    var interval: DateInterval
    /// Sources selected when the session was saved. A source that no longer exists is
    /// reported as missing rather than silently dropped.
    var sourceIDs: [String]
    /// Metric the session focused on, when it focused on one.
    var metric: MetricKind?
    var createdAt: Date
    /// Readings that existed for this period the last time it was viewed, so a revisit can
    /// say whether the result now includes data imported since. Nil for a session that has
    /// never been re-opened.
    var lastViewedReadingCount: Int?
    /// Fingerprint of the readings behind `lastViewedReadingCount`. A count alone cannot tell
    /// five readings added and five removed from "unchanged". Nil for a session last viewed
    /// by a build that predates it, whose count also covered every source, not only the
    /// session's own, so it is not comparable with a current summary.
    var lastViewedFingerprint: Int64?
    var lastViewedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        context: String = "",
        interval: DateInterval,
        sourceIDs: [String],
        metric: MetricKind? = nil,
        createdAt: Date = .now,
        lastViewedReadingCount: Int? = nil,
        lastViewedFingerprint: Int64? = nil,
        lastViewedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.context = context
        self.interval = interval
        self.sourceIDs = sourceIDs
        self.metric = metric
        self.createdAt = createdAt
        self.lastViewedReadingCount = lastViewedReadingCount
        self.lastViewedFingerprint = lastViewedFingerprint
        self.lastViewedAt = lastViewedAt
    }

    var period: ComparisonPeriod { .fixed(interval) }

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? interval.start.formatted(date: .abbreviated, time: .shortened)
            : title
    }

    /// Sources from this session that are no longer in the store.
    ///
    /// Reported rather than dropped: a comparison missing one of its two devices is not the
    /// same comparison, and silently showing the remaining one would misrepresent it.
    func missingSourceIDs(in known: [DataSource]) -> [String] {
        let ids = Set(known.map(\.id))
        return sourceIDs.filter { !ids.contains($0) }
    }

    /// How this session's data has changed since it was last opened.
    ///
    /// Time zones do not enter into it: the interval is absolute, so a device that changes
    /// zone re-reads exactly the same seconds and only the rendered wall-clock text moves.
    ///
    /// - Parameter currentFingerprint: identity summary of the readings now stored for the
    ///   period. When supplied it is compared as well as the count, so a replacement that
    ///   leaves the count unchanged is still disclosed.
    func revisitDisclosure(currentReadingCount: Int, currentFingerprint: Int64? = nil) -> String? {
        guard let previous = lastViewedReadingCount else { return nil }
        if let currentFingerprint {
            // An older baseline counted other sources' readings too; comparing against it
            // would report changes that never happened.
            guard let previousFingerprint = lastViewedFingerprint else { return nil }
            if currentReadingCount == previous, currentFingerprint != previousFingerprint {
                return String(
                    localized: "session.revisit.replaced",
                    defaultValue: "The readings stored for this period are not the same ones you saw when you last opened it (some were replaced, corrected, or removed and others added), so this result may differ.",
                    comment: "Shown when reopening a saved comparison whose period holds the same number of readings, but not the same readings."
                )
            }
        }
        let difference = currentReadingCount - previous
        if difference > 0 {
            return String(
                localized: "session.revisit.added",
                defaultValue: "\(difference) readings have been imported for this period since you last opened it, so this result may differ from what you saw.",
                comment: "Shown when reopening a saved comparison whose period now holds more readings. The argument is how many were added."
            )
        }
        if difference < 0 {
            let removed = -difference
            return String(
                localized: "session.revisit.removed",
                defaultValue: "\(removed) readings are no longer stored for this period \u{2014} removed upstream, or compacted by retention.",
                comment: "Shown when reopening a saved comparison whose period now holds fewer readings. The argument is how many are gone."
            )
        }
        return nil
    }
}
