import Foundation

/// Presentation only: never imports samples or recomputes comparison evidence.
struct WatchComplicationValue: Sendable {
    let kind: MetricKind
    let reading: WatchSourceReading?
    let availability: WatchSnapshot.Availability?

    init(kind: MetricKind, snapshot: WatchSnapshot?) {
        self.kind = kind
        availability = snapshot?.availability
        reading = snapshot?.availability == .ready
            ? snapshot?.metrics.first(where: { $0.kind == kind }).flatMap(Self.displayedReading)
            : nil
    }

    /// The reading a complication draws for a metric. Estimates need their full explanation
    /// in the app, so they are never shown. Selected deterministically from the same bounded
    /// set of enabled sources shown on the watch dashboard: newest first, ties by source id.
    static func displayedReading(in metric: WatchMetric) -> WatchSourceReading? {
        metric.readings
            .filter { $0.provenance != .estimated }
            .sorted {
                $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp
            }.first
    }

    func isStale(at date: Date) -> Bool {
        reading?.isStale(kind: kind, now: date) ?? false
    }

    /// A future entry ages the display even if no new phone snapshot arrives.
    func staleTransition(after date: Date) -> Date? {
        guard let reading else { return nil }
        let transition = reading.freshnessDeadline(kind: kind).addingTimeInterval(1)
        return transition > date ? transition : nil
    }

    var emptyMessage: String {
        switch availability {
        case nil: String(localized: "Open HeartSync")
        case .unavailable: String(localized: "Open iPhone app")
        case .ready: String(localized: "No readings")
        }
    }
}

extension WatchSnapshot {

    /// The part of a snapshot a complication can draw: per metric, the one reading
    /// `WatchComplicationValue` would show, and nothing else.
    ///
    /// A complication needs no charts, no comparison counts, and no other source. Storing this
    /// instead of the full payload (up to 60 KB) keeps the extension's decode small, and it
    /// gives the app something to compare: `generatedAt` changes with every iPhone
    /// publication, and a chart or a comparison count changes far more often than any value a
    /// complication shows, so comparing whole snapshots spent WidgetKit's reload budget on
    /// deliveries that changed nothing on the wrist face.
    var complicationProjection: WatchSnapshot {
        guard availability == .ready else {
            return WatchSnapshot(generatedAt: generatedAt, availability: availability, metrics: [])
        }
        let neutral = WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 3_600)
        let projected = metrics.compactMap { metric -> WatchMetric? in
            guard let reading = WatchComplicationValue.displayedReading(in: metric) else { return nil }
            return WatchMetric(
                kind: metric.kind,
                readings: [reading],
                omittedSourceCount: 0,
                comparison: neutral
            )
        }
        return WatchSnapshot(generatedAt: generatedAt, availability: availability, metrics: projected)
    }

    /// True when two projections draw the same thing on a complication. Delivery time is not
    /// part of it; the measurement time inside each reading is.
    func drawsSameComplications(as other: WatchSnapshot) -> Bool {
        availability == other.availability && metrics == other.metrics
    }
}

enum WatchComplicationLink: Equatable {
    case metric(MetricKind)

    var url: URL {
        var components = URLComponents()
        components.scheme = "heartsync-watch"
        switch self {
        case .metric(let kind):
            components.host = "metric"
            components.path = "/\(kind.rawValue)"
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme == "heartsync-watch", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        if url.host == "metric",
                  let kind = MetricKind(rawValue: String(url.path.dropFirst())),
                  url.path == "/\(kind.rawValue)" {
            self = .metric(kind)
        } else {
            return nil
        }
    }
}
