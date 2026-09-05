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
    var id: MetricKind { kind }
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
