import Foundation

/// One resolved pass over the cached Oura heart-rate samples for the dashboard chart.
///
/// Everything the Heart rate card draws — the plotted line, the area baseline, the range
/// label, and the thinning note — is a projection of this single value, built once per
/// update and threaded through the section.
///
/// That is not only tidiness. `OuraHeartRateSection` previously derived its points inside
/// computed properties, and the area mark's baseline read one of them from inside the
/// `Chart` content closure. Swift Charts runs that closure once per plotted sample, so
/// every sample re-parsed, re-sorted, and re-filtered the *entire* cached collection: a
/// fortnight of five-minute samples turned a 288-point chart into roughly a million
/// ISO-8601 parses, on the main thread, the moment the Oura tab appeared. The screen froze.
/// Deriving once and reading stored properties in the closure is what keeps it from
/// happening again.
///
/// Nothing here averages, interpolates, or invents a value: every plotted point is one of
/// Oura's own samples, and a sample whose timestamp cannot be parsed is dropped rather than
/// plotted at a guessed time.
struct OuraHeartRateSeries {

    /// One plotted sample, carrying Oura's own bpm value.
    struct Point: Identifiable, Equatable, Sendable {
        /// Oura's timestamp string plus the value, so a repeated instant cannot collapse
        /// two distinct samples into one chart identity.
        var id: String
        var date: Date
        var bpm: Double
    }

    /// Samples actually drawn, oldest first. Thinned from `sampleCount` when the window
    /// holds more than the chart can draw legibly.
    let points: [Point]

    /// How many cached samples fall inside the window, before thinning. `points.count` is
    /// what is drawn; this is what was there.
    let sampleCount: Int

    /// Lowest and highest bpm across every sample in the window, not merely the drawn ones,
    /// so the range label describes the cache rather than the thinning.
    let lowest: Int?
    let highest: Int?

    /// Baseline the area mark fills down to. Stored, because reading it is the one thing
    /// that happens once per plotted sample.
    let floor: Double

    /// True when the chart is showing a subset. The section says so on screen: silently
    /// drawing part of the window would misstate how much data is behind the line.
    var isThinned: Bool { points.count < sampleCount }

    /// The window drawn, measured back from the newest cached sample rather than from now —
    /// this is Oura's processed cloud series, and the ring may not have uploaded for hours.
    static let window: TimeInterval = 86_400

    /// Swift Charts emits one mark per sample per series, and Oura can return a sample a
    /// minute for a wearing day. Matches the bound the pairwise plot uses for the same
    /// reason; only the drawn set is thinned, never the cache.
    static let maximumPlottedSamples = 240

    init(heartRates: [OuraClient.HeartRatePoint]) {
        // One parse per cached sample, once. `parseTimestamp` is the expensive call on this
        // screen, so nothing below is allowed to parse a second time.
        var dated: [Point] = []
        dated.reserveCapacity(heartRates.count)
        var newest: Date?
        for sample in heartRates {
            guard let date = OuraClient.parseTimestamp(sample.timestamp) else { continue }
            dated.append(Point(id: "\(sample.timestamp)-\(sample.bpm)", date: date, bpm: Double(sample.bpm)))
            if let current = newest {
                if date > current { newest = date }
            } else {
                newest = date
            }
        }

        let recent: [Point]
        if let newest {
            let cutoff = newest.addingTimeInterval(-Self.window)
            recent = dated.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        } else {
            recent = []
        }

        let values = recent.map(\.bpm)
        let low = values.min()
        let high = values.max()

        self.points = Self.thinned(recent, limit: Self.maximumPlottedSamples)
        self.sampleCount = recent.count
        self.lowest = low.map { Int($0) }
        self.highest = high.map { Int($0) }
        self.floor = max(0, (low ?? 40) - 8)
    }

    /// Evenly samples the window down to `limit` points, keeping the newest sample and the
    /// two extremes.
    ///
    /// Mirrors `PairwiseAnalysis.plotSample`: an evenly strided subset can walk straight
    /// past the night's lowest beat or the day's highest, and the range label above the
    /// chart names both — the drawn line has to reach them.
    private static func thinned(_ points: [Point], limit: Int) -> [Point] {
        guard limit > 0 else { return [] }
        guard points.count > limit else { return points }

        let step = Double(points.count) / Double(limit)
        var keep = Set((0..<limit).map { Int(Double($0) * step) })
        keep.insert(points.count - 1)
        if let lowest = points.indices.min(by: { points[$0].bpm < points[$1].bpm }) {
            keep.insert(lowest)
        }
        if let highest = points.indices.max(by: { points[$0].bpm < points[$1].bpm }) {
            keep.insert(highest)
        }

        return keep.sorted().map { points[$0] }
    }
}
