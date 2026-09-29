import Charts
import SwiftUI

/// Supporting types for `MetricDetailView` (snapshot, chart points, rows).
/// Kept alongside the view so the metric-detail chart fix stays a small surface area.

// MARK: - Snapshot

struct ChartPoint: Identifiable {
    var id: String
    var date: Date
    var value: Double
    /// Stable identity of the device that produced this point. This is the chart's series,
    /// colour and symbol key. Two devices sharing a display name are still two series, and
    /// renaming a device does not move its history into another series.
    var sourceID: String
    /// Display text only. Never used as a grouping key.
    var sourceName: String
    var isEstimate: Bool
    /// Line-segment key: the source ID plus a run index that increments across a gap in
    /// this source's data. Swift Charts connects consecutive marks that share a series
    /// key, so drawing one series per source would run a smooth curve straight through a
    /// six-hour hole and imply measurement that never happened. Colour and symbol still
    /// key on `sourceID`, so a broken line stays visibly one device.
    var seriesKey: String = ""
    /// A fixed compacted median, so VoiceOver can say so for the point it lands on.
    var isCompacted: Bool = false
}

/// Distinguishable mark shapes, assigned per source alongside colour.
///
/// Colour alone fails for the two readers this app cannot ignore: someone with a colour
/// vision deficiency, and someone comparing two devices whose palette entries are adjacent.
/// Dash patterns are deliberately *not* used here \u{2014} the chart already spends dashes on
/// "this value is modelled, not measured", and one visual channel cannot carry two meanings.
///
/// One shape per palette slot, chosen from the source's persisted `colorIndex`. Shape
/// used to be positional within a chart, so a device's symbol changed whenever another
/// device entered or left the range; now a device keeps its shape exactly as it keeps its
/// colour, on every chart that draws it.
enum SourceSymbol: Int, CaseIterable, Hashable, Sendable {
    case circle, square, triangle, diamond, pentagon, cross

    /// The shape paired with a palette slot. Negative indices wrap rather than trap.
    static func forColorIndex(_ index: Int) -> SourceSymbol {
        let count = allCases.count
        return allCases[((index % count) + count) % count]
    }

    var chartSymbol: BasicChartSymbolShape {
        switch self {
        case .circle:   .circle
        case .square:   .square
        case .triangle: .triangle
        case .diamond:  .diamond
        case .pentagon: .pentagon
        case .cross:    .cross
        }
    }

    /// Spoken in the legend so the shape is available without seeing it.
    var accessibilityName: String {
        switch self {
        case .circle:   "circle"
        case .square:   "square"
        case .triangle: "triangle"
        case .diamond:  "diamond"
        case .pentagon: "pentagon"
        case .cross:    "cross"
        }
    }
}

extension DataSource {
    /// The mark shape paired with this source's colour slot, stable for the life of the
    /// source in the same way its colour is.
    var symbol: SourceSymbol { .forColorIndex(colorIndex) }
}

/// One chart series: a stable source identity plus everything needed to draw and name it.
struct SourceSeries: Identifiable, Hashable {
    var sourceID: String
    /// Display name, suffixed only when another visible source shares the same name.
    var label: String
    var color: Color
    var symbol: SourceSymbol

    var id: String { sourceID }
}

struct BandPoint: Identifiable {
    var id: String
    var date: Date
    var low: Double
    var high: Double
    var severity: DiscrepancySeverity
    /// Area series key. It advances wherever the band breaks: at a gap in comparison, and
    /// where the severity changes, because an area series takes one style for all of it.
    var seriesKey: String = ""
    /// A compared window with no compared neighbour. An area needs two points, so the view
    /// draws this one as a short bar rather than losing it.
    var isIsolated: Bool = false
}

/// One device's descriptive summary over the selected range.
///
/// Every figure here describes **comparison windows**, not original samples. That
/// distinction is the whole point of this type: after compaction a window is one stored
/// median and the raw distribution behind it is gone, so a row count is not a measurement
/// count, and the smallest stored value is not the smallest thing the device ever read.
/// Presenting either as if it were the raw fact would overstate what the archive still
/// holds. Where the original depth is known it is reported separately; where it is not, it
/// stays unknown rather than being back-filled from the rows that survived.
struct SourceStats: Identifiable {
    var source: DataSource
    /// Median of this source's per-window medians. Deliberately not a mean of the stored
    /// values: averaging medians does not reconstruct the mean of the original samples,
    /// and presenting it as one would invent precision the archive cannot support.
    var typicalWindowValue: Double
    /// Lowest and highest **window medians**. A spike the window median absorbed is not
    /// recoverable, so these are not raw minima and maxima.
    var lowestWindowValue: Double
    var highestWindowValue: Double
    /// Number of comparison windows this source occupied in the range.
    var windowCount: Int
    /// Original raw samples behind those windows, when every contributing window knows its
    /// own depth. Nil means at least one window is a legacy compacted median whose original
    /// count was never recorded — unknown, not zero.
    var originalSampleCount: Int?
    /// True when at least one contributing window is a fixed compacted median.
    var includesCompactedWindows: Bool
    var lastSeen: Date?

    var id: String { source.id }
}

/// One Bluetooth device's own verdict on the beats behind its latest HRV window.
struct HRVQualityEntry: Identifiable {
    var source: DataSource
    var quality: HRVQuality
    /// Heart rate the same device reported closest to the HRV window, when it reported one
    /// near enough to be a fair cross-check. Nil means no cross-check is possible, which is
    /// not the same as the device agreeing with itself.
    var reportedHeartRate: Double?

    var id: String { source.id }
}

/// One resolved pass over the store for one metric and range.
///
/// Every projection this screen draws comes from the same read and the same windowing, so
/// the chart, the band, the legend, the per-device table and the pair list cannot describe
/// slightly different spans of time, and drawing the screen costs one pass rather than ten.
///
/// Built from a `HealthHistory` rather than the store, so the screen builds it off the main
/// actor and only publishes the result there. The `store:` initialisers are conveniences
/// for tests and previews that build it in place.
struct MetricDetailSnapshot {
    /// The period requested: a rolling preset, or a saved session's fixed span.
    let period: ComparisonPeriod
    /// The exact seconds analysed, resolved once. A rolling period is relative to `.now`,
    /// so re-resolving it per projection would describe a slightly different span each time;
    /// everything drawn from this snapshot, and every pair opened from it, uses this value.
    let interval: DateInterval
    /// Store generation this snapshot read, and when. Live reloads are coalesced, so the
    /// screen compares this with the current generation to say when it is behind.
    let generation: Int
    let resolvedAt: Date
    /// The whole period's chart: points, band, domains, and the per-window summaries the
    /// selection callout reads. A zoomed chart is a separate projection of the same kind.
    let chart: MetricChartProjection
    /// Chart bucket actually used, which is the metric's comparison window widened to the
    /// zoom level so a month does not try to render 43,000 points.
    var bucketSize: TimeInterval { chart.bucketSize }
    var points: [ChartPoint] { chart.points }
    var bandPoints: [BandPoint] { chart.bandPoints }
    let sourcesInRange: [DataSource]
    /// Chart series in canonical order. `styleDomain` is the source-ID domain every scale
    /// on the chart shares, so colour and symbol assignment cannot drift apart.
    let series: [SourceSeries]
    var styleDomain: [String] { series.map(\.sourceID) }
    var styleRange: [Color] { series.map(\.color) }
    var symbolRange: [BasicChartSymbolShape] { series.map(\.symbol.chartSymbol) }
    var yDomain: ClosedRange<Double> { chart.yDomain }
    let perSourceStats: [SourceStats]
    let pairwiseAnalyses: [PairwiseAnalysis]
    /// Whether the range holds any modelled value at all, so the estimate switch is only
    /// offered where it does something.
    let hasEstimatedReadings: Bool
    let hrvQuality: [HRVQualityEntry]
    /// Set when the history query failed. Everything else in this snapshot is then empty
    /// for want of data, not because the range holds none — the screen must say so rather
    /// than drawing a blank chart that reads as "you have no measurements".
    let queryFailure: HealthStoreQueryError?

    /// How far from an HRV window a heart-rate reading may sit and still be treated as the
    /// same moment: half of the 300-second HRV comparison window.
    private static let crossCheckTolerance: TimeInterval = 150

    @MainActor
    init(
        store: HealthStore,
        kind: MetricKind,
        range: TimeRange,
        includeEstimates: Bool,
        hrvQuality: [UUID: HRVQuality]
    ) {
        self.init(
            history: store.history,
            kind: kind,
            period: .rolling(range),
            includeEstimates: includeEstimates,
            hrvQuality: hrvQuality
        )
    }

    @MainActor
    init(
        store: HealthStore,
        kind: MetricKind,
        period: ComparisonPeriod,
        includeEstimates: Bool,
        hrvQuality: [UUID: HRVQuality]
    ) {
        self.init(
            history: store.history,
            kind: kind,
            period: period,
            includeEstimates: includeEstimates,
            hrvQuality: hrvQuality
        )
    }

    init(
        history store: HealthHistory,
        kind: MetricKind,
        period: ComparisonPeriod,
        includeEstimates: Bool,
        hrvQuality: [UUID: HRVQuality]
    ) {
        // Resolved once: a fixed period returns the same seconds on every read, and a
        // rolling one is pinned here so every projection below agrees on "now".
        let interval = period.interval
        self.period = period
        self.interval = interval
        self.generation = store.changeToken
        self.resolvedAt = .now
        let outcome = store.readingsOutcome(kind: kind, in: interval)
        self.queryFailure = outcome.error
        let readings = outcome.valueOrEmpty
        self.hasEstimatedReadings = readings.contains { $0.provenance == .estimated }

        let bucketSize = max(kind.comparisonWindow, period.chartBucket)
        let windows = ComparisonEngine.windows(
            from: readings,
            kind: kind,
            windowSize: bucketSize,
            range: interval,
            includeEstimated: includeEstimates
        )

        // Averages over a night or a day are drawn as spans and never windowed.
        let intervalAverages = readings.filter { reading in
            reading.isIntervalAverage
                && interval.contains(reading.midpoint)
                && (includeEstimates || reading.provenance != .estimated)
        }
        let sources = Set(windows.flatMap { $0.values.map(\.sourceID) } + intervalAverages.map(\.sourceID))
            .compactMap { store.source(id: $0) }
            .sorted { $0.displayName < $1.displayName }
        self.sourcesInRange = sources
        self.series = Self.makeSeries(for: sources)
        // A reading whose device record is gone still draws, under the store's fallback
        // name; every other label is the legend's own.
        var fallbackLabels: [String: String] = [:]
        for window in windows {
            for value in window.values where store.source(id: value.sourceID) == nil {
                fallbackLabels[value.sourceID] = store.displayName(forSource: value.sourceID)
            }
        }
        for reading in intervalAverages where store.source(id: reading.sourceID) == nil {
            fallbackLabels[reading.sourceID] = store.displayName(forSource: reading.sourceID)
        }
        self.chart = MetricChartProjection(
            windows: windows,
            kind: kind,
            interval: interval,
            bucketSize: bucketSize,
            series: self.series,
            labels: fallbackLabels,
            intervalAverages: intervalAverages
        )

        // Built from the same `windows` pass the chart draws, so the table and the chart
        // describe identical buckets. The estimate switch is presentation, and `windows`
        // already honours it, so it filters this descriptive table too.
        let statsReadings = includeEstimates
            ? readings
            : readings.filter { $0.provenance != .estimated }
        var lastSeenBySource: [String: Date] = [:]
        for reading in statsReadings {
            lastSeenBySource[reading.sourceID] = max(
                lastSeenBySource[reading.sourceID] ?? .distantPast,
                reading.end
            )
        }

        var valuesBySource: [String: [SourceValue]] = [:]
        for window in windows {
            for value in window.values { valuesBySource[value.sourceID, default: []].append(value) }
        }
        self.perSourceStats = valuesBySource
            .compactMap { sourceID, values -> SourceStats? in
                guard let source = store.source(id: sourceID), !values.isEmpty else { return nil }
                let medians = values.map(\.value)
                // A single nil depth makes the total unknown. Summing only the known ones
                // would report a total that is quietly missing an unknown number of samples.
                let depths = values.map(\.sampleCount)
                let originalSampleCount = depths.contains(where: { $0 == nil })
                    ? nil
                    : depths.compactMap { $0 }.reduce(0, +)
                return SourceStats(
                    source: source,
                    typicalWindowValue: ComparisonEngine.median(medians),
                    lowestWindowValue: medians.min() ?? 0,
                    highestWindowValue: medians.max() ?? 0,
                    windowCount: values.count,
                    originalSampleCount: originalSampleCount,
                    includesCompactedWindows: values.contains(where: \.isCompacted),
                    lastSeen: lastSeenBySource[sourceID]
                )
            }
            .sorted { $0.source.displayName < $1.source.displayName }

        // Alert preferences do not filter analytical detail: agreeing and
        // insufficient-evidence pairs remain inspectable here. Estimates are excluded by
        // the engine's own default, so `includeEstimates` cannot reach a verdict.
        self.pairwiseAnalyses = ComparisonEngine.allPairwiseAnalyses(
            from: readings,
            kind: kind,
            range: interval
        )

        self.hrvQuality = Self.qualityEntries(
            store: store,
            sources: sources,
            quality: hrvQuality,
            range: interval
        )
    }

    /// Line-segment keys that break at gaps; see `MetricChartProjection.segmented`.
    static func segmented(_ points: [ChartPoint], bucketSize: TimeInterval) -> [ChartPoint] {
        MetricChartProjection.segmented(points, bucketSize: bucketSize)
    }

    /// Band areas that break at gaps and severity changes; see
    /// `MetricChartProjection.bandRuns`.
    static func bandRuns(_ band: [BandPoint], bucketSize: TimeInterval) -> [BandPoint] {
        MetricChartProjection.bandRuns(band, bucketSize: bucketSize)
    }

    /// Builds the chart series for the sources visible in this range.
    ///
    /// Colour and symbol both come from `DataSource.colorIndex`, which the store assigns
    /// once per device and never reuses while that device exists, so a device keeps its
    /// colour and its shape across ranges, charts, and relaunches.
    ///
    /// Only past six devices can two visible sources share a slot. Then the later one takes
    /// the first shape no other visible series uses, so the two stay apart by shape even
    /// though their colours match.
    ///
    /// Labels are disambiguated only where they collide. A user with one "Polar H10" sees
    /// "Polar H10"; a user whose ring is visible over both Bluetooth and Apple Health sees
    /// the transport, and if that still collides, a short stable-ID suffix.
    static func makeSeries(for sources: [DataSource]) -> [SourceSeries] {
        var nameCounts: [String: Int] = [:]
        for source in sources { nameCounts[source.displayName, default: 0] += 1 }

        // Second pass over the colliding names only, to see whether transport separates them.
        var transportCounts: [String: Int] = [:]
        for source in sources where (nameCounts[source.displayName] ?? 0) > 1 {
            transportCounts["\(source.displayName)\u{001F}\(source.transport.title)", default: 0] += 1
        }

        let symbols = Self.symbols(for: sources)
        return sources.enumerated().map { index, source in
            let label: String
            if (nameCounts[source.displayName] ?? 0) <= 1 {
                label = source.displayName
            } else if (transportCounts["\(source.displayName)\u{001F}\(source.transport.title)"] ?? 0) <= 1 {
                label = "\(source.displayName) (\(source.transport.title))"
            } else if let model = source.model, !model.isEmpty {
                label = "\(source.displayName) (\(source.transport.title), \(model))"
            } else {
                label = "\(source.displayName) (\(source.transport.title), \(Self.shortIdentifier(source.id)))"
            }
            return SourceSeries(
                sourceID: source.id,
                label: label,
                color: source.color,
                symbol: symbols[index]
            )
        }
    }

    /// Each source's own slot shape, except where two visible sources share a slot: the
    /// later one then takes the first shape nobody visible is using.
    static func symbols(for sources: [DataSource]) -> [SourceSymbol] {
        // First pass: every source claims its own shape, so an unshared slot never moves.
        var owner: [SourceSymbol: Int] = [:]
        for (index, source) in sources.enumerated() where owner[source.symbol] == nil {
            owner[source.symbol] = index
        }
        var used = Set(owner.keys)
        return sources.enumerated().map { index, source in
            if owner[source.symbol] == index { return source.symbol }
            guard let spare = SourceSymbol.allCases.first(where: { !used.contains($0) }) else {
                return source.symbol
            }
            used.insert(spare)
            return spare
        }
    }

    /// Last six identifier characters, uppercased. Enough to tell two otherwise identical
    /// devices apart without printing a UUID at a user.
    private static func shortIdentifier(_ id: String) -> String {
        let trimmed = id.filter(\.isHexDigit)
        let tail = trimmed.isEmpty ? id : trimmed
        return String(tail.suffix(6)).uppercased()
    }

    /// Pairs each Bluetooth source with its latest HRV window quality and the heart rate it
    /// reported at the same moment.
    ///
    /// Only sources whose window falls inside the selected range are returned, so the
    /// caveat always describes data the user can see. The heart rates come from one bounded
    /// read spanning the candidate windows rather than a query per device.
    private static func qualityEntries(
        store: HealthHistory,
        sources: [DataSource],
        quality: [UUID: HRVQuality],
        range: DateInterval
    ) -> [HRVQualityEntry] {
        guard !quality.isEmpty else { return [] }
        let candidates: [(source: DataSource, quality: HRVQuality)] = sources.compactMap { source in
            guard source.transport == .bluetooth,
                  let uuid = UUID(uuidString: source.id),
                  let measured = quality[uuid],
                  range.contains(measured.measuredAt)
            else { return nil }
            return (source, measured)
        }
        guard let earliest = candidates.map({ $0.quality.measuredAt }).min(),
              let latest = candidates.map({ $0.quality.measuredAt }).max()
        else { return [] }

        let heartRates = store.readings(
            kind: .heartRate,
            in: DateInterval(
                start: earliest.addingTimeInterval(-crossCheckTolerance),
                end: latest.addingTimeInterval(crossCheckTolerance)
            )
        )
        let bySource = Dictionary(grouping: heartRates, by: \.sourceID)

        return candidates.map { candidate in
            let nearest = bySource[candidate.source.id]?
                .min { lhs, rhs in
                    abs(lhs.end.timeIntervalSince(candidate.quality.measuredAt))
                        < abs(rhs.end.timeIntervalSince(candidate.quality.measuredAt))
                }
            let reported = nearest.flatMap { reading -> Double? in
                abs(reading.end.timeIntervalSince(candidate.quality.measuredAt)) <= crossCheckTolerance
                    ? reading.value
                    : nil
            }
            return HRVQualityEntry(
                source: candidate.source,
                quality: candidate.quality,
                reportedHeartRate: reported
            )
        }
        .sorted { $0.source.displayName < $1.source.displayName }
    }
}
