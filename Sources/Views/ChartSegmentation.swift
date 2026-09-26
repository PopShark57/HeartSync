import Foundation

/// Breaks a chart series wherever consecutive samples are further apart than a threshold.
///
/// Swift Charts joins consecutive marks that share a series value, so one series per device
/// runs a line — or fills an area — straight through a six-hour hole and asserts a
/// measurement that never happened. Every line, band and area that spans time is keyed by
/// `series + segment` instead, where the segment advances at each gap. Colour and symbol
/// keep keying on the device, so a broken line still reads as one device.
///
/// An isolated sample gets a segment of its own; a line needs two points, so callers keep
/// such samples visible with a point or rule mark.
enum ChartSegmentation {

    /// Segment number for each date, in input order. Dates must be ascending.
    ///
    /// A gap strictly greater than `threshold` starts a new segment; a non-positive
    /// threshold never breaks.
    static func segments(for dates: [Date], threshold: TimeInterval) -> [Int] {
        guard threshold > 0 else { return Array(repeating: 0, count: dates.count) }
        var result: [Int] = []
        result.reserveCapacity(dates.count)
        var segment = 0
        var previous: Date?
        for date in dates {
            if let previous, date.timeIntervalSince(previous) > threshold { segment += 1 }
            result.append(segment)
            previous = date
        }
        return result
    }

    /// Series key for one segment of one series. The unit separator cannot occur in a
    /// source identifier, so two devices can never share a key.
    static func key(series: String, segment: Int) -> String {
        "\(series)\u{001F}\(segment)"
    }

    /// Positions whose segment holds a single sample, which a line cannot draw.
    static func isolatedPositions(_ segments: [Int]) -> Set<Int> {
        var counts: [Int: Int] = [:]
        for segment in segments { counts[segment, default: 0] += 1 }
        return Set(segments.indices.filter { counts[segments[$0]] == 1 })
    }

    /// Gap threshold for evenly spaced windows: one and a half windows, so a series that
    /// reports every window stays joined and a single missed window breaks it.
    ///
    /// When a drawn set was thinned to every `stride`th window, adjacent drawn points are
    /// `stride` windows apart by construction; the threshold scales with the stride so that
    /// only a genuine gap in the data, not the thinning itself, breaks the line.
    static func windowThreshold(windowSize: TimeInterval, stride: Double = 1) -> TimeInterval {
        windowSize * 1.5 * max(1, stride.rounded(.up))
    }

    /// Gap threshold for irregularly timed samples: a multiple of their median spacing.
    ///
    /// 2.5× tolerates one dropped sample and ordinary timestamp jitter, and breaks the line
    /// once two or more consecutive samples are missing. Nil when fewer than two samples
    /// leave no spacing to measure.
    static func medianSpacingThreshold(for dates: [Date], multiple: Double = 2.5) -> TimeInterval? {
        guard dates.count >= 2 else { return nil }
        let spacings = zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) }.filter { $0 > 0 }
        guard !spacings.isEmpty else { return nil }
        return ComparisonEngine.median(spacings) * multiple
    }
}
