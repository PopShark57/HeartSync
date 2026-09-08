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
}

/// Distinguishable mark shapes, assigned per source alongside colour.
///
/// Colour alone fails for the two readers this app cannot ignore: someone with a colour
/// vision deficiency, and someone comparing two devices whose palette entries are adjacent.
/// Dash patterns are deliberately *not* used here \u{2014} the chart already spends dashes on
/// "this value is modelled, not measured", and one visual channel cannot carry two meanings.
enum SourceSymbol: Int, CaseIterable, Hashable, Sendable {
    case circle, square, triangle, diamond, pentagon

    static func forIndex(_ index: Int) -> SourceSymbol {
        allCases[index % allCases.count]
    }

    var chartSymbol: BasicChartSymbolShape {
        switch self {
        case .circle:   .circle
        case .square:   .square
        case .triangle: .triangle
        case .diamond:  .diamond
        case .pentagon: .pentagon
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
        }
    }
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
@MainActor
struct MetricDetailSnapshot {
    /// Chart bucket actually used, which is the metric's comparison window widened to the
    /// zoom level so a month does not try to render 43,000 points.
    let bucketSize: TimeInterval
    let points: [ChartPoint]
    let bandPoints: [BandPoint]
    let sourcesInRange: [DataSource]
    /// Chart series in canonical order. `styleDomain` is the source-ID domain every scale
    /// on the chart shares, so colour and symbol assignment cannot drift apart.
    let series: [SourceSeries]
    var styleDomain: [String] { series.map(\.sourceID) }
    var styleRange: [Color] { series.map(\.color) }
    var symbolRange: [BasicChartSymbolShape] { series.map(\.symbol.chartSymbol) }
    let yDomain: ClosedRange<Double>
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

    init(
        store: HealthStore,
        kind: MetricKind,
        range: TimeRange,
        includeEstimates: Bool,
        hrvQuality: [UUID: HRVQuality]
    ) {
        let interval = range.interval
        let outcome = store.readingsOutcome(kind: kind, in: interval)
        self.queryFailure = outcome.error
        let readings = outcome.valueOrEmpty
        self.hasEstimatedReadings = readings.contains { $0.provenance == .estimated }

        let bucketSize = max(kind.comparisonWindow, range.chartBucket)
        self.bucketSize = bucketSize
        let windows = ComparisonEngine.windows(
            from: readings,
            kind: kind,
            windowSize: bucketSize,
            range: interval,
            includeEstimated: includeEstimates
        )

        let sources = Set(windows.flatMap { $0.values.map(\.sourceID) })
            .compactMap { store.source(id: $0) }
            .sorted { $0.displayName < $1.displayName }
        self.sourcesInRange = sources
        self.series = Self.makeSeries(for: sources)
        var names: [String: String] = [:]
        for entry in self.series { names[entry.sourceID] = entry.label }

        let chartPoints = windows.flatMap { window in
            window.values.map { value in
                ChartPoint(
                    id: "\(value.sourceID)-\(window.start.timeIntervalSince1970)",
                    date: window.start,
                    value: value.value,
                    sourceID: value.sourceID,
                    sourceName: names[value.sourceID] ?? store.displayName(forSource: value.sourceID),
                    isEstimate: value.provenance == .estimated
                )
            }
        }
        self.points = Self.segmented(chartPoints, bucketSize: bucketSize)

        // The band is a disagreement verdict drawn on a chart, so it is built from measured
        // and derived values only. Showing estimates must never widen it or change its
        // colour: the switch above is presentation, and an estimate is not a device.
        self.bandPoints = windows.compactMap { window in
            let comparable = window.values.filter { $0.provenance != .estimated }
            guard comparable.count >= 2,
                  let low = comparable.min(by: { $0.value < $1.value }),
                  let high = comparable.max(by: { $0.value < $1.value })
            else { return nil }
            return BandPoint(
                id: window.id,
                date: window.start,
                low: low.value,
                high: high.value,
                severity: kind.agreement.severity(forDelta: high.value - low.value)
            )
        }

        // Pads the observed range slightly so lines are not flush against the plot edges,
        // and never collapses to zero height when every reading is identical.
        let plotted = self.points.map(\.value)
        if let low = plotted.min(), let high = plotted.max() {
            let padding = max((high - low) * 0.15, kind.agreement.warn)
            self.yDomain = (low - padding)...(high + padding)
        } else {
            self.yDomain = kind.displayRange
        }

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

    /// Assigns each point a line-segment key, starting a new segment wherever a source
    /// skipped more than one bucket.
    ///
    /// A curve drawn across a gap asserts that the device was measuring throughout it. It
    /// was not, and the chart must not say so. An isolated observation gets its own
    /// segment and remains visible as a point, because `PointMark` is drawn regardless.
    ///
    /// The threshold is 1.5 buckets: one bucket of spacing is normal for a source
    /// reporting every window, so only a genuinely missed window breaks the line.
    static func segmented(_ points: [ChartPoint], bucketSize: TimeInterval) -> [ChartPoint] {
        guard bucketSize > 0 else { return points }
        let threshold = bucketSize * 1.5
        var result: [ChartPoint] = []
        result.reserveCapacity(points.count)

        for (sourceID, group) in Dictionary(grouping: points, by: \.sourceID) {
            let ordered = group.sorted { $0.date < $1.date }
            var segment = 0
            var previous: Date?
            for var point in ordered {
                if let previous, point.date.timeIntervalSince(previous) > threshold { segment += 1 }
                point.seriesKey = "\(sourceID)\u{001F}\(segment)"
                previous = point.date
                result.append(point)
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Builds the chart series for the sources visible in this range.
    ///
    /// Colour comes from `DataSource.colorIndex`, which the store assigns once per device
    /// and never reuses while that device exists, so a device keeps its colour across
    /// ranges and relaunches. The symbol is positional within this chart, which is enough
    /// to separate two adjacent palette entries on screen.
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
                symbol: SourceSymbol.forIndex(index)
            )
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
        store: HealthStore,
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
