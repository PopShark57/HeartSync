import Foundation

/// One resolved pass for the pairwise screen: the analysis and everything its charts draw.
///
/// The screen used to start `body` with a computed `analysis` that read every reading of
/// the metric in the range from SQLite, decoded it, and re-ran the pairwise analysis. Both
/// chart overlays write the selected window on every drag change, so scrubbing a 30-day
/// pair re-queried and re-windowed the whole range on every touch-move event — against a
/// `range.interval` relative to `.now`, so each pass also analysed a slightly different
/// span and a window at the leading edge could vanish mid-drag.
///
/// This is built once per load key in `.task(id:)`. A drag changes only a date in `@State`,
/// and every lookup it needs is a binary search over arrays prepared here. Statistics and
/// the export use `analysis`, which keeps every paired window; only `plotted` is thinned.
///
/// Selection itself (improvement 34) snaps the timeline to the nearest drawn window within
/// an on-screen radius, picks the difference plot's point nearest a tap in both x and y,
/// and steps window by window for VoiceOver — all against the arrays prepared here.
@MainActor
struct PairwiseSnapshot {
    let kind: MetricKind
    let period: ComparisonPeriod
    /// The exact seconds analysed, resolved once. A fixed period is a saved session's span,
    /// and the analysis — and any export made from it — carries exactly that span.
    let interval: DateInterval
    let analysis: PairwiseAnalysis
    /// Drawable subset of `analysis.observations`, in chronological order.
    let plotted: [PairwiseObservation]
    /// Line segment for each plotted window. A's and B's lines break at the same places,
    /// because both are drawn at the same paired windows: a stretch with no pairing is a
    /// gap in the comparison, not continuous agreement or disagreement.
    let timelineSegments: [Int]
    let timelineYDomain: ClosedRange<Double>
    /// The timeline's pinned x domain: the analysed span, widened back to its first window
    /// boundary. Pinning it keeps a stretch with no paired window visibly empty.
    let timelineXDomain: ClosedRange<Date>
    let differenceXDomain: ClosedRange<Double>
    let differenceYDomain: ClosedRange<Double>
    /// Set when the history read failed. The analysis is then empty for want of data, and
    /// the screen must say so rather than reporting "no overlapping windows".
    let queryFailure: HealthStoreQueryError?
    /// Store generation this snapshot read, and when, so a coalesced reload can say how far
    /// behind the newest reading it is.
    let generation: Int
    let resolvedAt: Date

    /// `plotted[i].start` as reference-date seconds, ascending (plotted is chronological).
    private let plottedStarts: [Double]

    /// Swift Charts emits one mark per observation per series, and a 30-day range of a
    /// 60-second metric can pair tens of thousands of windows. Statistics, the evidence
    /// card, and the export always use every paired window; only the drawn set is thinned.
    static let maximumPlottedObservations = 500

    /// Extra points kept regardless of the even sampling, so thinning cannot hide the
    /// outliers a Bland–Altman plot exists to show.
    static let maximumPlottedExtremes = 60

    init(
        store: HealthStore,
        kind: MetricKind,
        sourceA: String,
        sourceB: String,
        period: ComparisonPeriod
    ) {
        let interval = period.interval
        let outcome = store.readingsOutcome(kind: kind, in: interval)
        self.init(
            kind: kind,
            sourceA: sourceA,
            sourceB: sourceB,
            period: period,
            interval: interval,
            readings: outcome.valueOrEmpty,
            queryFailure: outcome.error,
            generation: store.changeToken
        )
    }

    /// Builds from readings already in hand. The store initialiser is the only production
    /// caller; tests use this to pin the projections without a database.
    init(
        kind: MetricKind,
        sourceA: String,
        sourceB: String,
        period: ComparisonPeriod,
        interval: DateInterval,
        readings: [Reading],
        queryFailure: HealthStoreQueryError? = nil,
        generation: Int = 0,
        resolvedAt: Date = .now
    ) {
        self.kind = kind
        self.period = period
        self.interval = interval
        self.queryFailure = queryFailure
        self.generation = generation
        self.resolvedAt = resolvedAt

        let analysis = ComparisonEngine.pairwiseAnalysis(
            from: readings,
            kind: kind,
            sourceA: sourceA,
            sourceB: sourceB,
            range: interval
        )
        self.analysis = analysis
        let plotted = analysis.plotSample(
            limit: Self.maximumPlottedObservations,
            extremes: Self.maximumPlottedExtremes
        )
        self.plotted = plotted
        // Adjacent paired windows sit one window apart. When the drawn set was thinned to
        // every n-th window, adjacent drawn points are n windows apart by construction, so
        // the threshold scales with the stride and only a genuine gap breaks the line.
        let stride = analysis.observations.count > Self.maximumPlottedObservations
            ? Double(analysis.observations.count) / Double(Self.maximumPlottedObservations)
            : 1
        self.timelineSegments = ChartSegmentation.segments(
            for: plotted.map(\.start),
            threshold: ChartSegmentation.windowThreshold(windowSize: analysis.windowSize, stride: stride)
        )
        self.plottedStarts = plotted.map { $0.start.timeIntervalSinceReferenceDate }
        let firstBoundary = analysis.windowSize > 0
            ? ComparisonEngine.floorToWindow(interval.start, size: analysis.windowSize)
            : interval.start
        self.timelineXDomain = min(firstBoundary, interval.end)...interval.end

        self.timelineYDomain = Self.paddedDomain(
            plotted.flatMap { [$0.sourceA.value, $0.sourceB.value] },
            kind: kind
        )
        self.differenceXDomain = Self.paddedDomain(plotted.map(\.pairedMean), kind: kind)
        self.differenceYDomain = Self.differenceDomain(analysis: analysis, plotted: plotted, kind: kind)
    }

    // MARK: - Selection lookups

    /// The plotted window whose start is nearest `date`, found by binary search. With a
    /// tolerance, a window farther away than that is not selected: the touch was in empty
    /// plot area, and the caller clears the selection instead.
    func observation(nearestStart date: Date, within tolerance: TimeInterval? = nil) -> PairwiseObservation? {
        ChartLookup.nearestIndex(
            in: plottedStarts,
            to: date.timeIntervalSinceReferenceDate,
            within: tolerance
        ).map { plotted[$0] }
    }

    /// The plotted window that starts exactly at `date`, found by binary search.
    func observation(startingAt date: Date?) -> PairwiseObservation? {
        guard let date, let index = ChartLookup.nearestIndex(
            in: plottedStarts,
            to: date.timeIntervalSinceReferenceDate
        ), plotted[index].start == date else { return nil }
        return plotted[index]
    }

    /// The plotted window drawn nearest `location` on the difference plot, measured on
    /// screen in both x and y, if it lies within `radius` points.
    ///
    /// Two-dimensional because the plot exists to show outliers, and outliers often share
    /// a paired mean with the dense cluster: picking by paired mean alone could never
    /// select them apart from it. `position` maps a window to its on-screen point through
    /// the chart's own scales. It runs once per tap, not per frame, so a linear pass over
    /// the drawn points is enough.
    func observation(
        nearestTo location: CGPoint,
        within radius: Double,
        position: (PairwiseObservation) -> CGPoint?
    ) -> PairwiseObservation? {
        ChartLookup.nearestIndex(to: location, in: plotted.map(position), within: radius)
            .map { plotted[$0] }
    }

    /// The plotted window `step` places after the one starting at `start` — before it, for
    /// a negative step. With nothing selected, stepping forward starts at the first window
    /// and stepping back at the last. Stops at either end rather than wrapping, so someone
    /// stepping with VoiceOver can tell where the data ends.
    func observation(steppingFrom start: Date?, by step: Int) -> PairwiseObservation? {
        guard !plotted.isEmpty, step != 0 else { return nil }
        guard let current = observation(startingAt: start),
              let index = plotted.firstIndex(where: { $0.start == current.start })
        else { return step > 0 ? plotted.first : plotted.last }
        return plotted[min(max(index + step, 0), plotted.count - 1)]
    }

    /// One paired window as VoiceOver reads it: when, both values, the signed difference,
    /// and any reason to doubt it. For example "3 Sep, 14:32, A 72, B 75, A minus B −3 bpm,
    /// outside limits".
    func spokenSummary(_ observation: PairwiseObservation) -> String {
        var parts = [
            observation.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
            "A \(kind.format(observation.sourceA.value))",
            "B \(kind.format(observation.sourceB.value))",
            "A minus B \(Self.signed(observation.signedDifference, kind: kind)) \(kind.unit)",
        ]
        if isOutsideLimits(observation) { parts.append("outside limits") }
        if !observation.timing.supportsConclusion { parts.append(observation.timing.title.lowercased()) }
        if observation.sourceA.isCompacted || observation.sourceB.isCompacted { parts.append("compacted") }
        return parts.joined(separator: ", ")
    }

    /// A signed difference as the screen writes it: always a sign, and a true minus.
    static func signed(_ value: Double, kind: MetricKind) -> String {
        let magnitude = kind.format(abs(value))
        return value >= 0 ? "+\(magnitude)" : "\u{2212}\(magnitude)"
    }

    /// Whether a window's difference falls outside the observed limits of agreement.
    func isOutsideLimits(_ observation: PairwiseObservation) -> Bool {
        guard let limits = analysis.statistics?.limitsOfAgreement else { return false }
        return !limits.contains(observation.signedDifference)
    }

    /// Says so when the chart is not showing every paired window. Silently drawing a subset
    /// would misrepresent how much evidence the analysis actually rests on.
    var thinningNote: String {
        guard plotted.count < analysis.observations.count else { return "" }
        return " Showing \(plotted.count) of \(analysis.observations.count) paired windows for legibility, including the widest differences; every window is used for the statistics and the export."
    }

    // MARK: - Helpers

    /// Index of the value nearest `target` in an ascending array; the earlier on a tie,
    /// matching `min(by:)` over the chronological list it replaces.
    static func nearestIndex(in sorted: [Double], to target: Double) -> Int? {
        ChartLookup.nearestIndex(in: sorted, to: target)
    }

    private static func paddedDomain(_ values: [Double], kind: MetricKind) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return kind.displayRange }
        let padding = max((high - low) * 0.15, max(kind.agreement.warn * 0.2, 0.1))
        return (low - padding)...(high + padding)
    }

    private static func differenceDomain(
        analysis: PairwiseAnalysis,
        plotted: [PairwiseObservation],
        kind: MetricKind
    ) -> ClosedRange<Double> {
        var values = plotted.map(\.signedDifference)
        values += [0, kind.agreement.warn, -kind.agreement.warn, kind.agreement.alert, -kind.agreement.alert]
        if let statistics = analysis.statistics {
            values += [statistics.meanBias, statistics.limitsOfAgreement.lowerBound, statistics.limitsOfAgreement.upperBound]
        }
        let low = values.min() ?? -kind.agreement.alert
        let high = values.max() ?? kind.agreement.alert
        let padding = max((high - low) * 0.12, 0.1)
        return (low - padding)...(high + padding)
    }
}
