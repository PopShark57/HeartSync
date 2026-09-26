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

    /// The difference plot's own linear scales, as the chart maps values to points.
    private func screenPosition(
        _ observation: PairwiseObservation,
        in resolved: PairwiseSnapshot,
        size: CGSize = CGSize(width: 320, height: 280)
    ) -> CGPoint {
        let x = resolved.differenceXDomain, y = resolved.differenceYDomain
        return CGPoint(
            x: (observation.pairedMean - x.lowerBound) / (x.upperBound - x.lowerBound) * size.width,
            y: (1 - (observation.signedDifference - y.lowerBound) / (y.upperBound - y.lowerBound)) * size.height
        )
    }

    @Test("A tap on the difference plot selects the point nearest on screen, as a linear scan would")
    func nearestPointMatchesLinearScan() {
        let resolved = snapshot(readings(minutes: 150))
        let positions = resolved.plotted.map { screenPosition($0, in: resolved) }
        for step in 0..<300 {
            let tap = CGPoint(x: Double(step % 20) * 16.3, y: Double(step / 20) * 18.7)
            let linear = positions.enumerated()
                .map { (index: $0.offset, distance: hypot($0.element.x - tap.x, $0.element.y - tap.y)) }
                .filter { $0.distance <= ChartLookup.selectionRadius }
                .min { $0.distance < $1.distance }
            let found = resolved.observation(nearestTo: tap, within: ChartLookup.selectionRadius) {
                screenPosition($0, in: resolved)
            }
            // Ties may resolve to a different window at an identical distance.
            if let linear, let found {
                let distance = hypot(screenPosition(found, in: resolved).x - tap.x, screenPosition(found, in: resolved).y - tap.y)
                #expect(abs(distance - linear.distance) < 1e-9)
            } else {
                #expect(linear == nil && found == nil)
            }
        }
    }

    @Test("An outlier stacked above the cluster at the same paired mean can be selected on its own")
    func stackedOutlierIsReachable() throws {
        // Twenty windows agree closely around 70 bpm; one at the same paired mean differs by 20.
        var input: [Reading] = []
        for minute in 0..<21 {
            let stamp = interval.start.addingTimeInterval(Double(minute) * 60 + 1)
            let gap: Double = minute == 10 ? 20 : (minute.isMultiple(of: 2) ? 1 : -1)
            input.append(Reading(sourceID: "a", kind: .heartRate, value: 70 + gap / 2, start: stamp))
            input.append(Reading(sourceID: "b", kind: .heartRate, value: 70 - gap / 2, start: stamp.addingTimeInterval(4)))
        }
        let resolved = snapshot(input)
        let outlier = try #require(resolved.plotted.first { $0.signedDifference == 20 })
        let cluster = resolved.plotted.filter { $0.signedDifference != 20 }
        // Every window shares the paired mean of 70, so a lookup on x alone cannot tell them apart.
        #expect(resolved.plotted.allSatisfy { $0.pairedMean == 70 })

        let tap = screenPosition(outlier, in: resolved)
        let picked = resolved.observation(nearestTo: tap, within: ChartLookup.selectionRadius) {
            screenPosition($0, in: resolved)
        }
        #expect(picked?.start == outlier.start)

        let clusterTap = try #require(cluster.first.map { screenPosition($0, in: resolved) })
        let pickedCluster = resolved.observation(nearestTo: clusterTap, within: ChartLookup.selectionRadius) {
            screenPosition($0, in: resolved)
        }
        #expect(pickedCluster?.signedDifference != 20)
    }

    @Test("A tap in empty plot area selects nothing, on either chart")
    func emptyAreaSelectsNothing() {
        let resolved = snapshot(readings(minutes: 120, gapAfter: 60, gapMinutes: 300))
        // Far from every drawn point on the difference plot.
        let corner = resolved.observation(nearestTo: CGPoint(x: -500, y: -500), within: ChartLookup.selectionRadius) {
            screenPosition($0, in: resolved)
        }
        #expect(corner == nil)

        // In the middle of the five-hour gap on the timeline, with a ten-minute catchment.
        let gapMiddle = interval.start.addingTimeInterval(60 * 60 + 150 * 60)
        #expect(resolved.observation(nearestStart: gapMiddle, within: 600) == nil)
        #expect(resolved.observation(nearestStart: gapMiddle) != nil)
        let before = resolved.plotted[30]
        #expect(resolved.observation(nearestStart: before.start.addingTimeInterval(10), within: 600)?.start == before.start)
    }

    @Test("Stepping walks the drawn windows in order and stops at either end")
    func steppingWalksTheWindows() throws {
        let resolved = snapshot(readings(minutes: 12))
        let points = resolved.plotted
        let first = try #require(points.first)
        let last = try #require(points.last)

        #expect(resolved.observation(steppingFrom: nil, by: 1)?.start == first.start)
        #expect(resolved.observation(steppingFrom: nil, by: -1)?.start == last.start)
        #expect(resolved.observation(steppingFrom: first.start, by: 1)?.start == points[1].start)
        #expect(resolved.observation(steppingFrom: points[1].start, by: -1)?.start == first.start)
        // No wrap-around: the ends hold.
        #expect(resolved.observation(steppingFrom: first.start, by: -1)?.start == first.start)
        #expect(resolved.observation(steppingFrom: last.start, by: 1)?.start == last.start)
        #expect(resolved.observation(steppingFrom: first.start, by: 0) == nil)
        #expect(snapshot([]).observation(steppingFrom: nil, by: 1) == nil)
    }

    @Test("Each window is spoken with both values, the signed difference, and its caveats")
    func spokenSummaryNamesEverything() throws {
        var input: [Reading] = []
        for minute in 0..<12 {
            let stamp = interval.start.addingTimeInterval(Double(minute) * 60 + 1)
            let b: Double = minute == 11 ? 90 : 71
            input.append(Reading(sourceID: "a", kind: .heartRate, value: 72, start: stamp))
            input.append(Reading(sourceID: "b", kind: .heartRate, value: b, start: stamp.addingTimeInterval(4)))
        }
        let resolved = snapshot(input)
        let typical = try #require(resolved.plotted.first)
        let spoken = resolved.spokenSummary(typical)
        #expect(spoken.contains("A 72"))
        #expect(spoken.contains("B 71"))
        #expect(spoken.contains("A minus B +1 bpm"))
        #expect(!spoken.contains("outside limits"))

        let outlier = try #require(resolved.plotted.last)
        #expect(resolved.isOutsideLimits(outlier))
        #expect(resolved.spokenSummary(outlier).contains("A minus B \u{2212}18 bpm"))
        #expect(resolved.spokenSummary(outlier).contains("outside limits"))
        #expect(PairwiseSnapshot.signed(0, kind: .heartRate) == "+0")
    }

    @Test("The timeline's x domain is the analysed span, so an unpaired stretch stays visible")
    func timelineDomainIsPinned() {
        let resolved = snapshot(readings(minutes: 30))
        #expect(resolved.timelineXDomain.upperBound == interval.end)
        #expect(resolved.timelineXDomain.lowerBound <= interval.start)
        #expect(interval.start.timeIntervalSince(resolved.timelineXDomain.lowerBound) < 60)
        #expect(resolved.plotted.allSatisfy { resolved.timelineXDomain.contains($0.start) })
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
        #expect(resolved.observation(nearestTo: .zero, within: 1_000) { _ in .zero } == nil)
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
