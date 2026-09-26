import Foundation
import Testing
@testable import HeartSyncChecker

/// The pairwise screen's resolved snapshot (improvement 28).
///
/// Selection used to re-query and re-analyse the whole range on every drag frame. These pin
/// that the snapshot's precomputed lookups answer exactly what the old linear scans did, and
/// that moving the work out of `body` changed where it runs, not what it computes.
@Suite("Pairwise snapshot")
@MainActor
struct PairwiseSnapshotTests {

    private let interval = DateInterval(
        start: Date(timeIntervalSince1970: 1_700_000_000),
        duration: 24 * 3_600
    )

    /// Paired one-minute windows with a deterministic pseudo-random spread and a gap.
    private func readings(minutes: Int, gapAfter: Int? = nil, gapMinutes: Int = 0) -> [Reading] {
        var result: [Reading] = []
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        for minute in 0..<minutes {
            let offset = minute + ((gapAfter.map { minute >= $0 } ?? false) ? gapMinutes : 0)
            let stamp = interval.start.addingTimeInterval(Double(offset) * 60 + 1)
            result.append(Reading(sourceID: "a", kind: .heartRate, value: 60 + next() * 40, start: stamp))
            result.append(Reading(sourceID: "b", kind: .heartRate, value: 60 + next() * 40, start: stamp.addingTimeInterval(4)))
        }
        return result
    }

    private func snapshot(_ readings: [Reading]) -> PairwiseSnapshot {
        PairwiseSnapshot(
            kind: .heartRate,
            sourceA: "a",
            sourceB: "b",
            period: .fixed(interval),
            interval: interval,
            readings: readings
        )
    }

    @Test("The analysis is the engine's, over the snapshot's own resolved span")
    func analysisIsUnchanged() {
        let input = readings(minutes: 90)
        let resolved = snapshot(input)
        let direct = ComparisonEngine.pairwiseAnalysis(
            from: input,
            kind: .heartRate,
            sourceA: "a",
            sourceB: "b",
            range: interval
        )
        #expect(resolved.analysis == direct)
        #expect(resolved.plotted == direct.plotSample(
            limit: PairwiseSnapshot.maximumPlottedObservations,
            extremes: PairwiseSnapshot.maximumPlottedExtremes
        ))
    }

    @Test("Nearest-window lookup matches a linear scan everywhere, including both edges")
    func nearestStartMatchesLinearScan() {
        let resolved = snapshot(readings(minutes: 120, gapAfter: 60, gapMinutes: 45))
        let points = resolved.plotted
        let first = interval.start.addingTimeInterval(-600)
        for step in 0..<400 {
            let probe = first.addingTimeInterval(Double(step) * 31.7)
            let linear = points.min {
                abs($0.start.timeIntervalSince(probe)) < abs($1.start.timeIntervalSince(probe))
            }
            #expect(resolved.observation(nearestStart: probe)?.start == linear?.start)
        }
    }

    @Test("Nearest-paired-mean lookup matches a linear scan")
    func nearestMeanMatchesLinearScan() {
        let resolved = snapshot(readings(minutes: 150))
        let points = resolved.plotted
        for step in 0..<300 {
            let probe = 55 + Double(step) * 0.17
            let linear = points.min { abs($0.pairedMean - probe) < abs($1.pairedMean - probe) }
            let found = resolved.observation(nearestPairedMean: probe)
            // Ties may resolve to a different window with an identical distance.
            #expect(abs((found?.pairedMean ?? .nan) - probe) == abs((linear?.pairedMean ?? .nan) - probe))
        }
    }

    @Test("Exact-start lookup finds plotted windows and nothing else")
    func exactStartLookup() {
        let resolved = snapshot(readings(minutes: 30))
        for point in resolved.plotted {
            #expect(resolved.observation(startingAt: point.start)?.start == point.start)
        }
        #expect(resolved.observation(startingAt: nil) == nil)
        #expect(resolved.observation(startingAt: interval.start.addingTimeInterval(17)) == nil)
    }

    @Test("A thinned plot still keeps every window for statistics and says so")
    func thinningIsDisclosed() {
        let resolved = snapshot(readings(minutes: 700))
        #expect(resolved.analysis.observations.count == 700)
        #expect(resolved.plotted.count < 700)
        #expect(resolved.thinningNote.contains("of 700 paired windows"))
        #expect(snapshot(readings(minutes: 40)).thinningNote.isEmpty)
    }

    @Test("An empty pair has no lookups and falls back to the metric's display range")
    func emptyPair() {
        let resolved = snapshot([])
        #expect(resolved.plotted.isEmpty)
        #expect(resolved.observation(nearestStart: interval.start) == nil)
        #expect(resolved.observation(nearestPairedMean: 70) == nil)
        #expect(resolved.timelineYDomain == MetricKind.heartRate.displayRange)
    }

    @Test("A failed read is carried as a failure, not as a pair with no overlap")
    func queryFailureIsCarried() {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "a", displayName: "A", transport: .bluetooth))
        store.injectQueryFailureForTesting()
        let resolved = PairwiseSnapshot(store: store, kind: .heartRate, sourceA: "a", sourceB: "b", period: .rolling(.day))
        #expect(resolved.queryFailure != nil)
        #expect(resolved.analysis.observations.isEmpty)
    }

    @Test("Binary search picks the earlier of two equally near values, like min(by:)")
    func nearestIndexTieBreak() {
        #expect(PairwiseSnapshot.nearestIndex(in: [0, 10], to: 5) == 0)
        #expect(PairwiseSnapshot.nearestIndex(in: [0, 10, 20], to: 11) == 1)
        #expect(PairwiseSnapshot.nearestIndex(in: [0, 10, 20], to: 99) == 2)
        #expect(PairwiseSnapshot.nearestIndex(in: [0, 10, 20], to: -99) == 0)
        #expect(PairwiseSnapshot.nearestIndex(in: [], to: 1) == nil)
    }
}
