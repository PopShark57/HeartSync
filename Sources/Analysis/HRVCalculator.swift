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

/// The part of an HRV window that is *about the measurement* rather than about the heart.
///
/// `HRVMetrics` computes these and the store only ever receives RMSSD and SDNN, so without
/// this type the caveats are thrown away. They matter because they answer a question no
/// cross-device comparison can: `impliedHeartRate` is the rate the device's own R\u{2013}R
/// intervals imply, so comparing it against the heart rate that same device reports
/// directly detects a device that disagrees with *itself* \u{2014} a stronger signal than two
/// devices disagreeing with each other. `artefactFraction` is the honesty caveat that
/// belongs beside any HRV comparison: "this window rejected 22% of beats" changes how the
/// number should be read.
///
/// This is measurement quality, not a measurement. It is deliberately not a `Reading` and
/// never reaches `HealthStore`, HealthKit, or an export: it describes one live window from
/// one device and is replaced on every emission.
struct HRVQuality: Equatable, Sendable {
    /// Intervals that survived artefact rejection in the emitting window.
    var beatCount: Int
    /// Fraction of R\u{2013}R intervals rejected, 0...1.
    var artefactFraction: Double
    /// Heart rate in bpm implied by the R\u{2013}R intervals themselves.
    var impliedHeartRate: Double
    /// Percentage of successive intervals differing by more than 50 ms.
    var pnn50: Double
    /// When the window that produced this was emitted.
    var measuredAt: Date
}

extension HRVQuality {
    /// Lifts the quality fields out of a computed window. Declared in an extension so the
    /// memberwise initializer stays available to callers that build one directly.
    init(metrics: HRVMetrics, measuredAt: Date) {
        self.init(
            beatCount: metrics.beatCount,
            artefactFraction: metrics.artefactFraction,
            impliedHeartRate: metrics.meanHeartRate,
            pnn50: metrics.pnn50,
            measuredAt: measuredAt
        )
    }
}

enum HRVCalculator {

    /// Physiologically possible R\u{2013}R range: 300 ms is 200 bpm, 2000 ms is 30 bpm.
    /// Anything outside is a dropped or doubled beat, not a heartbeat.
    static let plausibleIntervalMS: ClosedRange<Double> = 300...2000

    /// Maximum deviation from the running reference rate accepted as physiological, as a
    /// fraction of the reference. This is *not* a successive-difference test: an interval
    /// is compared against the prevailing rhythm, not against its immediate predecessor,
    /// so a single ectopic beat is rejected on its own rather than also condemning the
    /// normal beat that follows it. Leaving ectopics in inflates RMSSD dramatically.
    static let maximumDeviationFromReference = 0.20

    /// How many of the most recent accepted intervals form the reference rate. A median
    /// over a short window follows genuine drift while ignoring a single outlier that
    /// slipped through, which an exponential average cannot do.
    static let referenceWindow = 5

    /// Consecutive rejections that count as "the rhythm moved" rather than "these beats
    /// are artefacts". Three is deliberately small: a run this long of mutually consistent
    /// intervals is a rate change, and holding the old reference against it would reject
    /// every beat from then on.
    static let rejectionRunLimit = 3

    /// Removes non-physiological intervals.
    ///
    /// Two passes. First an absolute range filter. Then a relative filter that compares
    /// each surviving interval against a *reference rate* \u{2014} the median of the last
    /// `referenceWindow` accepted intervals, seeded from the median of the whole batch so
    /// a corrupted first beat cannot poison the sequence. Intervals within
    /// `maximumDeviationFromReference` of that reference are kept.
    ///
    /// Because the reference only advances on accepted beats, a sustained rate change
    /// (rest ~1000 ms to exercise ~600 ms is a 40% step) would otherwise reject every
    /// interval forever and stall HRV emission until the old beats aged out of the
    /// accumulator's window. So a run of `rejectionRunLimit` consecutive rejections that
    /// are *mutually consistent* \u{2014} all within `maximumDeviationFromReference` of their own
    /// median \u{2014} is treated as a genuine rhythm change: the reference is re-seeded from
    /// that run and the run's intervals are accepted retroactively rather than being
    /// counted as artefacts. Scattered rejections are never consistent with each other, so
    /// real noise still fails the check, keeps being rejected, and drives
    /// `artefactFraction` past `HRVMetrics.maximumArtefactFraction` where it belongs.
    ///
    /// The returned `rejected` count is relative to the *supplied* intervals, so it
    /// includes both out-of-range values and beats the relative filter dropped.
    static func filterArtefacts(_ intervals: [Double]) -> (clean: [Double], rejected: Int) {
        let inRange = intervals.filter { plausibleIntervalMS.contains($0) }
        guard inRange.count >= 2 else {
            return (inRange, intervals.count - inRange.count)
        }

        var clean: [Double] = []
        clean.reserveCapacity(inRange.count)
        // Seed the reference with the median so a corrupted first beat cannot poison the
        // whole sequence.
        var recentAccepted: [Double] = []
        var reference = median(inRange)
        var rejectedRun: [Double] = []

        for interval in inRange {
            let deviation = abs(interval - reference) / reference
            if deviation <= maximumDeviationFromReference {
                clean.append(interval)
                recentAccepted.append(interval)
                if recentAccepted.count > referenceWindow { recentAccepted.removeFirst() }
                reference = median(recentAccepted)
                rejectedRun.removeAll(keepingCapacity: true)
                continue
            }

            rejectedRun.append(interval)
            guard rejectedRun.count >= rejectionRunLimit else { continue }

            // Only the trailing run is considered, so noise immediately followed by a real
            // rate change still re-seeds on the change rather than being held back by the
            // scattered intervals in front of it.
            let candidate = Array(rejectedRun.suffix(rejectionRunLimit))
            let candidateReference = median(candidate)
            let isConsistent = candidate.allSatisfy {
                abs($0 - candidateReference) / candidateReference <= maximumDeviationFromReference
            }
            guard isConsistent else { continue }

            clean.append(contentsOf: candidate)
            recentAccepted = candidate
            reference = candidateReference
            rejectedRun.removeAll(keepingCapacity: true)
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
