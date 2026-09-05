import Foundation

/// Presentation only: never imports samples or recomputes comparison evidence.
struct WatchComplicationValue: Sendable {
    let kind: MetricKind
    let reading: WatchSourceReading?
    let availability: WatchSnapshot.Availability?

    init(kind: MetricKind, snapshot: WatchSnapshot?) {
        self.kind = kind
        availability = snapshot?.availability
        // Estimates need their full explanation in the app. Select deterministically from
        // the same bounded set of enabled sources shown on the watch dashboard.
        reading = snapshot?.availability == .ready
            ? snapshot?.metrics.first(where: { $0.kind == kind })?.readings
                .filter { $0.provenance != .estimated }
                .sorted {
                    $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp
                }.first
            : nil
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

enum WatchComplicationLink: Equatable {
    case metric(MetricKind)
    case workout

    var url: URL {
        var components = URLComponents()
        components.scheme = "heartsync-watch"
        switch self {
        case .metric(let kind):
            components.host = "metric"
            components.path = "/\(kind.rawValue)"
        case .workout:
            components.host = "workout"
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme == "heartsync-watch", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        if url.host == "workout", url.path.isEmpty || url.path == "/" {
            self = .workout
        } else if url.host == "metric",
                  let kind = MetricKind(rawValue: String(url.path.dropFirst())),
                  url.path == "/\(kind.rawValue)" {
            self = .metric(kind)
        } else {
            return nil
        }
    }
}
