import Foundation

/// Versioned, bounded display data only. The iPhone remains the history/analysis authority.
/// This payload contains no credentials and is never ingested back into HealthStore.
struct WatchSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumBytes = 60_000
    static let contextKey = "heartsync.snapshot.v1"
    static let refreshKey = "heartsync.refresh.v1"
    static let maximumSourcesPerMetric = 4

    enum Availability: String, Codable, Sendable { case ready, unavailable }

    var version = currentVersion
    var generatedAt: Date
    var availability: Availability = .ready
    var metrics: [WatchMetric]

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw PayloadError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw PayloadError.tooLarge }
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    private func validate() throws {
        guard version == Self.currentVersion else { throw PayloadError.unsupportedVersion }
        guard generatedAt.timeIntervalSince1970.isFinite,
              metrics.count <= MetricKind.allCases.count,
              Set(metrics.map(\.kind)).count == metrics.count,
              availability == .ready || metrics.isEmpty
        else { throw PayloadError.invalid }
        for metric in metrics {
            guard !metric.readings.isEmpty,
                  metric.readings.count <= Self.maximumSourcesPerMetric,
                  Set(metric.readings.map(\.id)).count == metric.readings.count,
                  metric.omittedSourceCount >= 0,
                  metric.comparison.readyPairs >= 0,
                  metric.comparison.incompletePairs >= 0,
                  metric.comparison.outsideTolerancePairs >= 0,
                  metric.comparison.outsideTolerancePairs <= metric.comparison.readyPairs,
                  metric.comparison.lookback.isFinite, metric.comparison.lookback > 0
            else { throw PayloadError.invalid }
            for reading in metric.readings {
                guard !reading.id.isEmpty, reading.id.count <= 160,
                      !reading.sourceName.isEmpty, reading.sourceName.count <= 100,
                      reading.value.isFinite, metric.kind.plausibleRange.contains(reading.value),
                      reading.timestamp.timeIntervalSince1970.isFinite,
                      reading.timestamp <= generatedAt.addingTimeInterval(60)
                else { throw PayloadError.invalid }
            }
            let charts = metric.allCharts
            guard charts.count <= WatchChartRange.allCases.count,
                  Set(charts.compactMap(\.range)).count == charts.compactMap(\.range).count,
                  charts.allSatisfy({ $0.isValid(for: metric.kind, generatedAt: generatedAt) })
            else { throw PayloadError.invalid }
        }
    }

    enum PayloadError: Error { case tooLarge, unsupportedVersion, invalid }
}

/// Kept separate from the transport so late delivery and corrupt updates can be tested
/// without a paired watch. A valid empty snapshot explicitly clears previously shown data.
struct WatchSnapshotInbox: Sendable {
    private(set) var snapshot: WatchSnapshot?

    @discardableResult
    mutating func receive(_ data: Data) throws -> Bool {
        let incoming = try WatchSnapshot.decode(data)
        guard snapshot.map({ incoming.generatedAt >= $0.generatedAt }) ?? true else { return false }
        snapshot = incoming
        return true
    }
}

struct WatchMetric: Codable, Equatable, Identifiable, Sendable {
    var kind: MetricKind
    var readings: [WatchSourceReading]
    var omittedSourceCount: Int
    var comparison: WatchComparison
    /// Per-source trend and one pair's agreement for the wrist charts. Optional so both
    /// directions stay compatible: an older iPhone build sends none (the watch says so), and
    /// an older watch build ignores the key.
    var chart: WatchChart? = nil
    /// The other periods' charts (1H, 3H, 7D, 30D beside the 24H `chart`; 30D beside 7D for
    /// daily metrics). Nil from an iPhone build without period choice.
    var rangeCharts: [WatchChart]? = nil
    /// The periods the iPhone computed. A listed period without a chart had no readings.
    /// Nil from an iPhone build without period choice.
    var availableRanges: [WatchChartRange]? = nil
    var id: MetricKind { kind }

    var allCharts: [WatchChart] { (chart.map { [$0] } ?? []) + (rangeCharts ?? []) }

    func periodChart(_ range: WatchChartRange) -> WatchChart? {
        allCharts.first { $0.range == range }
    }

    /// The comparison counts for a period: the chart's own, else the snapshot's default
    /// counts when that period is the default, else an explicit "no evidence".
    func periodComparison(_ range: WatchChartRange) -> WatchComparison {
        if let own = periodChart(range)?.comparison { return own }
        if comparison.lookback == range.duration { return comparison }
        return WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: range.duration)
    }
}

/// The periods the watch can compare over: iPhone's 1H, 24H, 7D, and 30D presets plus a
/// three-hour span for comparing devices over an afternoon.
enum WatchChartRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case hour = "1H"
    case threeHours = "3H"
    case day = "24H"
    case week = "7D"
    case month = "30D"

    /// Shown first, and the period of `WatchMetric.chart` for fast metrics.
    static let standard = WatchChartRange.day

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .hour:  3_600
        case .threeHours: 10_800
        case .day:   86_400
        case .week:  604_800
        case .month: 2_592_000
        }
    }

    var spokenTitle: String {
        switch self {
        case .hour:
            String(localized: "watch.spoken.pastHour", defaultValue: "Past hour", comment: "Spoken name of the 1H wrist chart period")
        case .threeHours:
            String(localized: "watch.spoken.pastThreeHours", defaultValue: "Past 3 hours", comment: "Spoken name of the 3H wrist chart period")
        case .day:
            String(localized: "watch.spoken.pastDay", defaultValue: "Past 24 hours", comment: "Spoken name of the 24H wrist chart period")
        case .week:
            String(localized: "watch.spoken.pastWeek", defaultValue: "Past 7 days", comment: "Spoken name of the 7D wrist chart period")
        case .month:
            String(localized: "watch.spoken.pastMonth", defaultValue: "Past 30 days", comment: "Spoken name of the 30D wrist chart period")
        }
    }

    /// A period must hold at least two of the metric's comparison windows; a daily metric
    /// therefore offers only 7D and 30D.
    func isAvailable(for kind: MetricKind) -> Bool {
        duration >= 2 * kind.comparisonWindow
    }

    static func available(for kind: MetricKind) -> [WatchChartRange] {
        allCases.filter { $0.isAvailable(for: kind) }
    }

    /// `selection` when offered, else the next longer offered period, else the longest.
    static func resolved(_ selection: WatchChartRange, among available: [WatchChartRange]) -> WatchChartRange? {
        if available.contains(selection) { return selection }
        return available.first { $0.duration >= selection.duration } ?? available.last
    }
}

struct WatchSourceReading: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sourceName: String
    var value: Double
    var timestamp: Date
    var provenance: Provenance
    var isCompacted: Bool

    func freshnessDeadline(kind: MetricKind) -> Date {
        timestamp.addingTimeInterval(max(15 * 60, kind.comparisonWindow))
    }

    func isStale(kind: MetricKind, now: Date) -> Bool {
        now > freshnessDeadline(kind: kind)
    }
}

/// What the wrist charts draw: each displayed source's window medians over the comparison
/// period, and the agreement of one ready pair. Times are whole-second offsets from `start`
/// and values are rounded to a tenth, which keeps ten metrics inside the 60 KB payload.
///
/// This is a display projection. Statistics are computed on iPhone from every reading, never
/// from these thinned points.
struct WatchChart: Codable, Equatable, Sendable {
    /// Upper bound accepted from the wire; the iPhone aims for about 48.
    static let maximumPoints = 64
    static let maximumDifferencePoints = 48

    var start: Date
    var end: Date
    /// Width of one median window, in seconds.
    var bucket: TimeInterval
    var series: [WatchChartSeries]
    /// Nil until some pair has at least five paired windows. Never implies agreement.
    var pair: WatchPairAgreement?
    /// Nil from an iPhone build without period choice.
    var range: WatchChartRange? = nil
    /// Evidence for exactly this period. `end` is when it was computed, which can trail the
    /// snapshot for the longer periods.
    var comparison: WatchComparison? = nil

    var span: TimeInterval { end.timeIntervalSince(start) }

    func isValid(for kind: MetricKind, generatedAt: Date) -> Bool {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              start < end, end <= generatedAt.addingTimeInterval(60),
              bucket.isFinite, bucket > 0, bucket <= span,
              series.count <= WatchSnapshot.maximumSourcesPerMetric,
              Set(series.map(\.id)).count == series.count
        else { return false }
        if let range {
            guard span <= range.duration + bucket + 1 else { return false }
        }
        if let comparison {
            guard comparison.readyPairs >= 0, comparison.incompletePairs >= 0,
                  comparison.outsideTolerancePairs >= 0,
                  comparison.outsideTolerancePairs <= comparison.readyPairs,
                  comparison.lookback.isFinite, comparison.lookback > 0
            else { return false }
        }
        let maximumOffset = Int(span.rounded(.up))
        for item in series {
            guard !item.id.isEmpty, item.id.count <= 160,
                  !item.sourceName.isEmpty, item.sourceName.count <= 100,
                  (0..<WatchSourceShape.allCases.count).contains(item.symbol),
                  item.color.isValid,
                  item.offsets.count == item.values.count,
                  item.offsets.count <= Self.maximumPoints,
                  item.offsets.allSatisfy({ (0...maximumOffset).contains($0) }),
                  item.values.allSatisfy({ $0.isFinite && kind.plausibleRange.contains($0) })
            else { return false }
        }
        if let pair {
            guard pair.isValid(maximumOffset: maximumOffset) else { return false }
        }
        return true
    }
}

struct WatchChartSeries: Codable, Equatable, Identifiable, Sendable {
    /// Matches `WatchSourceReading.id` for the same source.
    var id: String
    var sourceName: String
    /// The source's iPhone palette colour, as drawn on a dark background.
    var color: WatchColor
    /// The source's iPhone chart shape (`WatchSourceShape` raw value), so a colour is never
    /// the only thing telling two sources apart.
    var symbol: Int
    /// Estimates are drawn dashed and stay out of the agreement figures.
    var isEstimated: Bool
    /// Window starts, in seconds from `WatchChart.start`, ascending.
    var offsets: [Int]
    var values: [Double]

    var shape: WatchSourceShape { WatchSourceShape(rawValue: symbol) ?? .circle }
}

/// The iPhone's seven source shapes, in `SourceSymbol` order.
enum WatchSourceShape: Int, CaseIterable, Sendable {
    case circle, square, triangle, diamond, pentagon, cross, asterisk
}

struct WatchColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

/// Bland\u{2013}Altman figures for one pair, A minus B in canonical order, as computed on
/// iPhone from every paired window in the period.
struct WatchPairAgreement: Codable, Equatable, Sendable {
    /// The comparison engine's evidence threshold; a pair below it is never sent.
    static let minimumPairedWindows = 5

    var sourceA: String
    var sourceB: String
    var pairedWindows: Int
    var meanBias: Double
    var lowerLimit: Double
    var upperLimit: Double
    /// The mean absolute difference is inside the metric's tolerance.
    var withinTolerance: Bool
    /// A thinned set of per-window differences for the plot, widest ones always kept.
    var differenceOffsets: [Int]
    var differences: [Double]

    func isValid(maximumOffset: Int) -> Bool {
        guard !sourceA.isEmpty, sourceA.count <= 100,
              !sourceB.isEmpty, sourceB.count <= 100,
              pairedWindows >= Self.minimumPairedWindows
        else { return false }
        guard meanBias.isFinite, lowerLimit.isFinite, upperLimit.isFinite,
              lowerLimit <= upperLimit
        else { return false }
        guard differenceOffsets.count == differences.count,
              differences.count <= WatchChart.maximumDifferencePoints,
              differenceOffsets.allSatisfy({ (0...maximumOffset).contains($0) }),
              differences.allSatisfy({ $0.isFinite })
        else { return false }
        return true
    }
}

struct WatchComparison: Codable, Equatable, Sendable {
    var readyPairs: Int
    var incompletePairs: Int
    var outsideTolerancePairs: Int
    var lookback: TimeInterval

    /// An incomplete pair must never acquire a green conclusion on the smaller screen.
    var allPairsAgree: Bool {
        readyPairs > 0 && incompletePairs == 0 && outsideTolerancePairs == 0
    }
}
