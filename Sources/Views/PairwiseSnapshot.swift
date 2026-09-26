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
    /// Indices into `plotted`, ordered by paired mean and then chronologically.
    private let meanOrder: [Int]
    private let sortedMeans: [Double]

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
        let order = plotted.indices.sorted { lhs, rhs in
            let left = plotted[lhs].pairedMean, right = plotted[rhs].pairedMean
            return left == right ? lhs < rhs : left < right
        }
        self.meanOrder = order
        self.sortedMeans = order.map { plotted[$0].pairedMean }

        self.timelineYDomain = Self.paddedDomain(
            plotted.flatMap { [$0.sourceA.value, $0.sourceB.value] },
            kind: kind
        )
        self.differenceXDomain = Self.paddedDomain(plotted.map(\.pairedMean), kind: kind)
        self.differenceYDomain = Self.differenceDomain(analysis: analysis, plotted: plotted, kind: kind)
    }

    // MARK: - Selection lookups

    /// The plotted window whose start is nearest `date`, found by binary search.
    func observation(nearestStart date: Date) -> PairwiseObservation? {
        Self.nearestIndex(in: plottedStarts, to: date.timeIntervalSinceReferenceDate).map { plotted[$0] }
    }

    /// The plotted window that starts exactly at `date`, found by binary search.
    func observation(startingAt date: Date?) -> PairwiseObservation? {
        guard let date, let index = Self.nearestIndex(
            in: plottedStarts,
            to: date.timeIntervalSinceReferenceDate
        ), plotted[index].start == date else { return nil }
        return plotted[index]
    }

    /// The plotted window whose paired mean is nearest `mean`. One-dimensional on purpose:
    /// it keeps the difference plot's existing behaviour, only without an O(n) scan.
    func observation(nearestPairedMean mean: Double) -> PairwiseObservation? {
        Self.nearestIndex(in: sortedMeans, to: mean).map { plotted[meanOrder[$0]] }
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
        guard !sorted.isEmpty else { return nil }
        var low = 0
        var high = sorted.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < target { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(sorted[low - 1] - target) <= abs(sorted[low] - target) {
            return low - 1
        }
        return low
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
