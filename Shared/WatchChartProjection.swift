import Foundation

/// Drawable values for the wrist charts, kept out of the views so the iPhone test bundle can
/// check them. Nothing here recomputes a statistic; it only places what the iPhone sent.
enum WatchChartProjection {

    struct Point: Identifiable, Equatable, Sendable {
        var seriesID: String
        /// Changes at every gap, so a line never bridges a missing window.
        var segment: Int
        /// The middle of the median window.
        var date: Date
        var value: Double
        /// A point with no neighbour in its segment is drawn as a point only.
        var isIsolated: Bool

        var id: String { "\(seriesID)#\(Int(date.timeIntervalSince1970))" }
        var segmentKey: String { "\(seriesID)#\(segment)" }
    }

    static func points(for series: WatchChartSeries, in chart: WatchChart) -> [Point] {
        let pairs = zip(series.offsets, series.values).sorted { $0.0 < $1.0 }
        var points: [Point] = []
        var segment = 0
        var previous: Int?
        for (offset, value) in pairs {
            if let previous, Double(offset - previous) > chart.bucket { segment += 1 }
            previous = offset
            points.append(Point(
                seriesID: series.id,
                segment: segment,
                date: chart.start.addingTimeInterval(Double(offset) + chart.bucket / 2),
                value: value,
                isIsolated: false
            ))
        }
        let counts = Dictionary(grouping: points, by: \.segment).mapValues(\.count)
        for index in points.indices where counts[points[index].segment] == 1 {
            points[index].isIsolated = true
        }
        return points
    }

    struct DifferencePoint: Identifiable, Equatable, Sendable {
        var date: Date
        var difference: Double
        var id: Int { Int(date.timeIntervalSince1970) }
    }

    static func differencePoints(for pair: WatchPairAgreement, in chart: WatchChart, window: TimeInterval) -> [DifferencePoint] {
        zip(pair.differenceOffsets, pair.differences)
            .map { DifferencePoint(date: chart.start.addingTimeInterval(Double($0.0) + window / 2), difference: $0.1) }
            .sorted { $0.date < $1.date }
    }

    /// The metric's usual range, widened to include every drawn value, so a flat line does
    /// not fill the screen and an outlier is never clipped.
    static func valueDomain(kind: MetricKind, chart: WatchChart) -> ClosedRange<Double> {
        let values = chart.series.flatMap(\.values)
        let low = min(kind.displayRange.lowerBound, values.min() ?? kind.displayRange.lowerBound)
        let high = max(kind.displayRange.upperBound, values.max() ?? kind.displayRange.upperBound)
        return low...high
    }

    /// Zero, the bias, both limits, and every plotted difference, with a little headroom.
    static func differenceDomain(pair: WatchPairAgreement) -> ClosedRange<Double> {
        let values = pair.differences + [0, pair.meanBias, pair.lowerLimit, pair.upperLimit]
        let low = values.min() ?? -1
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.1, 0.5)
        return (low - padding)...(high + padding)
    }

    // MARK: Time axis

    /// Tick spacing per period: two or three labels fit a watch-width plot.
    static func tickSpacing(for range: WatchChartRange) -> TimeInterval {
        switch range {
        case .hour:  20 * 60
        case .day:   8 * 3_600
        case .week:  2 * 86_400
        case .month: 10 * 86_400
        }
    }

    /// Ticks on round local times (…:00/:20/:40, midnight/08:00/16:00, local midnights),
    /// kept away from both ends of the axis so no label is clipped at the edge.
    static func axisTicks(
        range: WatchChartRange,
        start: Date,
        end: Date,
        timeZone: TimeZone = .current
    ) -> [Date] {
        let spacing = tickSpacing(for: range)
        let margin = end.timeIntervalSince(start) * 0.08
        let lower = start.timeIntervalSince1970 + margin
        let upper = end.timeIntervalSince1970 - margin
        guard lower < upper else { return [] }
        let offset = TimeInterval(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: lower)))
        var tick = ((lower + offset) / spacing).rounded(.up) * spacing - offset
        var ticks: [Date] = []
        while tick <= upper, ticks.count < 6 {
            ticks.append(Date(timeIntervalSince1970: tick))
            tick += spacing
        }
        return ticks
    }

    /// Short labels only: a time within a day, a weekday for a week, a numeric date for a
    /// month. Never a month name and a time together, which cannot fit on the watch.
    static func axisFormat(for range: WatchChartRange) -> Date.FormatStyle {
        switch range {
        case .hour:  .dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
        case .day:   .dateTime.hour(.defaultDigits(amPM: .abbreviated))
        case .week:  .dateTime.weekday(.abbreviated)
        case .month: .dateTime.month(.defaultDigits).day()
        }
    }

    static func periodText(_ lookback: TimeInterval) -> String {
        if lookback >= 86_400 {
            let days = Int((lookback / 86_400).rounded())
            return days == 1
                ? String(localized: "watch.period.pastDay", defaultValue: "Past day", comment: "Watch comparison period: one day")
                : String(localized: "watch.period.pastDays", defaultValue: "Past \(days) days", comment: "Watch comparison period. The argument is the number of days, at least two.")
        }
        let hours = Int((lookback / 3_600).rounded())
        return hours <= 1
            ? String(localized: "watch.period.pastHour", defaultValue: "Past hour", comment: "Watch comparison period: one hour")
            : String(localized: "watch.period.pastHours", defaultValue: "Past \(hours) hours", comment: "Watch comparison period. The argument is the number of hours, at least two.")
    }

    /// A signed figure in the metric's precision plus one decimal, so small biases stay
    /// visible: "+3.0 bpm".
    static func signed(_ value: Double, kind: MetricKind) -> String {
        let digits = min(kind.fractionDigits + 1, 2)
        let number = value.formatted(.number.precision(.fractionLength(digits)).sign(strategy: .always(includingZero: false)))
        return "\(number) \(kind.unit)"
    }

    /// What VoiceOver reads for the trend chart, which is otherwise a picture.
    static func spokenSummary(kind: MetricKind, chart: WatchChart, lookback: TimeInterval) -> String {
        var parts = ["\(kind.title), \(periodText(lookback).lowercased())."]
        for series in chart.series {
            guard let latest = series.values.last,
                  let low = series.values.min(), let high = series.values.max()
            else { continue }
            let windows = String(
                localized: "watch.spoken.windows",
                defaultValue: "\(series.values.count) windows",
                comment: "Spoken description of a wrist chart series. The argument is how many comparison windows it holds."
            )
            let range = low == high ? kind.formatWithUnit(low) : "\(kind.format(low)) to \(kind.formatWithUnit(high))"
            let estimate = series.isEstimated ? ", estimate" : ""
            parts.append("\(series.sourceName)\(estimate): \(windows), \(range), latest \(kind.formatWithUnit(latest)).")
        }
        return parts.joined(separator: " ")
    }

    /// One sentence for the pair, never phrased as agreement between devices.
    static func pairSummary(kind: MetricKind, pair: WatchPairAgreement) -> String {
        "\(pair.sourceA) minus \(pair.sourceB): mean difference \(signed(pair.meanBias, kind: kind)); "
            + "95% of differences between \(signed(pair.lowerLimit, kind: kind)) and \(signed(pair.upperLimit, kind: kind)); "
            + "\(pair.pairedWindows) paired windows."
    }
}
