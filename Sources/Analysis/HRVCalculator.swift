import Foundation

/// Time-domain heart-rate-variability statistics computed from R\u{2013}R intervals.
///
/// These are the standard Task Force (1996) time-domain measures. HeartSync computes them
/// itself rather than trusting a vendor number, so that when two devices disagree on HRV
/// the app can say whether the *maths* differs or the *beats* differ.
struct HRVMetrics: Equatable, Sendable {
    /// Root mean square of successive differences, in ms. The standard short-window
    /// parasympathetic measure and the one most consumer devices report.
    var rmssd: Double
    /// Standard deviation of the NN intervals, in ms. Needs a longer window to be stable.
    var sdnn: Double
    /// Percentage of successive intervals differing by more than 50 ms.
    var pnn50: Double
    /// Mean heart rate implied by the intervals themselves, which is a useful cross-check
    /// against the HR the same device reports directly.
    var meanHeartRate: Double
    /// Intervals that survived artefact rejection.
    var beatCount: Int
    /// Fraction of supplied intervals discarded as artefact, 0...1. High values mean the
    /// HRV figure is not trustworthy no matter what it says.
    var artefactFraction: Double

    /// HRV needs a minimum number of clean beats to mean anything. Below this the app
    /// shows nothing rather than a confident-looking number built from six beats.
    static let minimumBeats = 20
    /// Above this fraction of rejected beats the window is discarded outright.
    static let maximumArtefactFraction = 0.25

    var isReliable: Bool {
        beatCount >= Self.minimumBeats && artefactFraction <= Self.maximumArtefactFraction
    }
}

enum HRVCalculator {

    /// Physiologically possible R\u{2013}R range: 300 ms is 200 bpm, 2000 ms is 30 bpm.
    /// Anything outside is a dropped or doubled beat, not a heartbeat.
    static let plausibleIntervalMS: ClosedRange<Double> = 300...2000

    /// Maximum beat-to-beat change accepted as physiological. A genuine sinus rhythm does
    /// not jump more than ~20% from one beat to the next; larger jumps are ectopic beats
    /// or missed detections, and leaving them in inflates RMSSD dramatically.
    static let maximumSuccessiveChange = 0.20

    /// Removes non-physiological intervals.
    ///
    /// Two passes: an absolute range filter, then a relative filter against a running
    /// median so a stretch of genuinely fast or slow beats is not thrown away wholesale.
    static func filterArtefacts(_ intervals: [Double]) -> (clean: [Double], rejected: Int) {
        let inRange = intervals.filter { plausibleIntervalMS.contains($0) }
        guard inRange.count >= 2 else {
            return (inRange, intervals.count - inRange.count)
        }

        var clean: [Double] = []
        clean.reserveCapacity(inRange.count)
        // Seed the reference with the median so a corrupted first beat cannot poison the
        // whole sequence.
        var reference = median(inRange)

        for interval in inRange {
            let deviation = abs(interval - reference) / reference
            if deviation <= maximumSuccessiveChange {
                clean.append(interval)
                // Track slowly so the reference follows real drift but not single spikes.
                reference = reference * 0.8 + interval * 0.2
            }
        }

        return (clean, intervals.count - clean.count)
    }

    /// Computes time-domain HRV from raw R\u{2013}R intervals in milliseconds.
    /// Returns `nil` when too few intervals survive filtering to say anything.
    static func metrics(from intervals: [Double]) -> HRVMetrics? {
        guard !intervals.isEmpty else { return nil }
        let (clean, rejected) = filterArtefacts(intervals)
        guard clean.count >= 2 else { return nil }

        let n = Double(clean.count)
        let mean = clean.reduce(0, +) / n

        // SDNN: population standard deviation of the intervals.
        let variance = clean.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let sdnn = variance.squareRoot()

        // RMSSD and pNN50 both operate on successive differences.
        var sumSquaredDiffs = 0.0
        var over50 = 0
        for i in 1..<clean.count {
            let diff = clean[i] - clean[i - 1]
            sumSquaredDiffs += diff * diff
            if abs(diff) > 50 { over50 += 1 }
        }
        let pairCount = Double(clean.count - 1)
        let rmssd = (sumSquaredDiffs / pairCount).squareRoot()
        let pnn50 = Double(over50) / pairCount * 100

        return HRVMetrics(
            rmssd: rmssd,
            sdnn: sdnn,
            pnn50: pnn50,
            meanHeartRate: 60_000.0 / mean,
            beatCount: clean.count,
            artefactFraction: Double(rejected) / Double(intervals.count)
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}

/// Accumulates R\u{2013}R intervals from a single device over a sliding time window and emits
/// HRV metrics once the window holds enough clean beats.
///
/// One instance per Bluetooth source. Not thread-safe by design \u{2014} it is owned by the
/// main-actor `BluetoothManager`.
struct HRVAccumulator {
    /// Sliding window length. Five minutes is the shortest interval for which SDNN is
    /// conventionally considered meaningful; RMSSD stabilises sooner.
    var window: TimeInterval = 300

    private var samples: [(time: Date, interval: Double)] = []
    private var lastEmit: Date?

    /// Emit no more often than this, so the store is not flooded with near-identical
    /// HRV values every time a beat arrives.
    var emitInterval: TimeInterval = 60

    mutating func add(intervals: [Double], at time: Date = .now) {
        for interval in intervals {
            samples.append((time, interval))
        }
        prune(before: time.addingTimeInterval(-window))
    }

    private mutating func prune(before cutoff: Date) {
        guard let firstKept = samples.firstIndex(where: { $0.time >= cutoff }) else {
            samples.removeAll(keepingCapacity: true)
            return
        }
        if firstKept > 0 { samples.removeFirst(firstKept) }
    }

    /// Returns HRV metrics if the window is full enough and enough time has passed since
    /// the last emission.
    mutating func emitIfReady(at time: Date = .now) -> HRVMetrics? {
        if let lastEmit, time.timeIntervalSince(lastEmit) < emitInterval { return nil }
        guard let metrics = HRVCalculator.metrics(from: samples.map(\.interval)),
              metrics.isReliable
        else { return nil }
        lastEmit = time
        return metrics
    }

    /// Seconds of data currently buffered, for showing progress towards a first reading.
    var bufferedDuration: TimeInterval {
        guard let first = samples.first?.time, let last = samples.last?.time else { return 0 }
        return last.timeIntervalSince(first)
    }

    var bufferedBeats: Int { samples.count }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastEmit = nil
    }
}
