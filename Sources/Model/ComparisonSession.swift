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
            "\(interval.start.formatted(date: .abbreviated, time: .shortened)) to \(interval.end.formatted(date: .omitted, time: .shortened))"
        }
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
    func revisitDisclosure(currentReadingCount: Int) -> String? {
        guard let previous = lastViewedReadingCount else { return nil }
        let difference = currentReadingCount - previous
        if difference > 0 {
            return "\(difference) \(difference == 1 ? "reading has" : "readings have") been imported for this period since you last opened it, so this result may differ from what you saw."
        }
        if difference < 0 {
            let removed = -difference
            return "\(removed) \(removed == 1 ? "reading is" : "readings are") no longer stored for this period — removed upstream, or compacted by retention."
        }
        return nil
    }
}
