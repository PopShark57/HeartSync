import SwiftUI

/// Supporting types for `MetricDetailView` (snapshot, chart points, rows).
/// Kept alongside the view so the metric-detail chart fix stays a small surface area.

// MARK: - Snapshot

struct ChartPoint: Identifiable {
    var id: String
    var date: Date
    var value: Double
    var sourceName: String
    var isEstimate: Bool
}

struct BandPoint: Identifiable {
    var id: String
    var date: Date
    var low: Double
    var high: Double
    var severity: DiscrepancySeverity
}

struct SourceStats: Identifiable {
    var source: DataSource
    var mean: Double
    var minimum: Double
    var maximum: Double
    var sampleCount: Int
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
    let styleDomain: [String]
    let styleRange: [Color]
    let yDomain: ClosedRange<Double>
    let perSourceStats: [SourceStats]
    let pairwiseAnalyses: [PairwiseAnalysis]
    /// Whether the range holds any modelled value at all, so the estimate switch is only
    /// offered where it does something.
    let hasEstimatedReadings: Bool
    let hrvQuality: [HRVQualityEntry]

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
        let readings = store.readings(kind: kind, in: interval)
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
        self.styleDomain = sources.map(\.displayName)
        self.styleRange = sources.map(\.color)
        var names: [String: String] = [:]
        for source in sources { names[source.id] = source.displayName }

        self.points = windows.flatMap { window in
            window.values.map { value in
                ChartPoint(
                    id: "\(value.sourceID)-\(window.start.timeIntervalSince1970)",
                    date: window.start,
                    value: value.value,
                    sourceName: names[value.sourceID] ?? store.displayName(forSource: value.sourceID),
                    isEstimate: value.provenance == .estimated
                )
            }
        }

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

        // The estimate switch is presentation, so it filters this descriptive table too.
        let statsReadings = includeEstimates
            ? readings
            : readings.filter { $0.provenance != .estimated }
        self.perSourceStats = Dictionary(grouping: statsReadings, by: \.sourceID)
            .compactMap { sourceID, samples -> SourceStats? in
                guard let source = store.source(id: sourceID), !samples.isEmpty else { return nil }
                let values = samples.map(\.value)
                return SourceStats(
                    source: source,
                    mean: values.reduce(0, +) / Double(values.count),
                    minimum: values.min() ?? 0,
                    maximum: values.max() ?? 0,
                    sampleCount: samples.count,
                    lastSeen: samples.map(\.end).max()
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
