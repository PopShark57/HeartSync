import Foundation
import Testing
@testable import HeartSyncChecker

@Suite("Watch comparison charts")
@MainActor
struct WatchChartTests {
    /// Yesterday's UTC midnight: always in the past (the store rejects future readings) and a
    /// whole number of every chart window and axis tick spacing since the epoch.
    private let now = Date(timeIntervalSince1970: ((Date.now.timeIntervalSince1970 / 86_400).rounded(.down) - 1) * 86_400)

    private func populate(
        _ store: HealthStore,
        sourceID: String,
        kind: MetricKind = .heartRate,
        value: Double,
        minutes: Int = 30,
        provenance: Provenance = .measured
    ) {
        if store.source(id: sourceID) == nil {
            store.upsert(DataSource(id: sourceID, displayName: "Source \(sourceID)", transport: .bluetooth))
        }
        for index in 1...minutes {
            store.append(Reading(
                sourceID: sourceID,
                kind: kind,
                value: value,
                start: now.addingTimeInterval(-Double(index) * 60),
                provenance: provenance
            ))
        }
    }

    private func chartFixture() -> WatchSnapshot {
        let start = now.addingTimeInterval(-6 * 3_600)
        let chart = WatchChart(
            start: start,
            end: now,
            bucket: 480,
            series: [WatchChartSeries(
                id: "strap", sourceName: "Chest strap",
                color: WatchColor(red: 0.42, green: 0.65, blue: 1), symbol: 0, isEstimated: false,
                offsets: [0, 480, 1_440], values: [70, 71.5, 72]
            )],
            pair: WatchPairAgreement(
                sourceA: "Chest strap", sourceB: "Ring", pairedWindows: 6,
                meanBias: 1.5, lowerLimit: -1, upperLimit: 4, withinTolerance: true,
                differenceOffsets: [60, 120], differences: [1, 2]
            )
        )
        return WatchSnapshot(generatedAt: now, metrics: [
            WatchMetric(
                kind: .heartRate,
                readings: [WatchSourceReading(id: "strap", sourceName: "Chest strap", value: 72, timestamp: now.addingTimeInterval(-5), provenance: .measured, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 1, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 6 * 3_600),
                chart: chart
            ),
        ])
    }

    // MARK: Payload

    @Test("Charts round-trip, and payloads from either older app still decode")
    func compatibility() throws {
        let snapshot = chartFixture()
        #expect(try WatchSnapshot.decode(snapshot.encoded()) == snapshot)

        // An older iPhone sends no chart key.
        var withoutChart = snapshot
        withoutChart.metrics[0].chart = nil
        let old = try withoutChart.encoded()
        #expect(String(decoding: old, as: UTF8.self).contains("\"chart\"") == false)
        #expect(try WatchSnapshot.decode(old).metrics[0].chart == nil)

        // An older watch ignores keys it does not know; so does this one.
        var object = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object["futureField"] = ["anything": 1]
        let future = try JSONSerialization.data(withJSONObject: object)
        #expect(try WatchSnapshot.decode(future).metrics.count == 1)
    }

    @Test("Chart points outside the period, broken series, and thin pairs are rejected")
    func invalidCharts() {
        func rejected(_ change: (inout WatchChart) -> Void) -> Bool {
            var snapshot = chartFixture()
            var chart = snapshot.metrics[0].chart!
            change(&chart)
            snapshot.metrics[0].chart = chart
            return (try? snapshot.encoded()) == nil
        }
        #expect(rejected { $0.series[0].offsets[2] = 30_000 })
        #expect(rejected { $0.series[0].offsets.removeLast() })
        #expect(rejected { $0.series[0].values[0] = 900 })
        #expect(rejected { $0.series[0].symbol = 7 })
        #expect(rejected { $0.series[0].color.red = 2 })
        #expect(rejected { $0.series.append($0.series[0]) })
        #expect(rejected { $0.pair?.pairedWindows = 4 })
        #expect(rejected { $0.pair?.lowerLimit = 10 })
        #expect(rejected { $0.bucket = 0 })
        #expect(rejected { $0.end = $0.start })
    }

    @Test("The wire threshold for a pair equals the comparison engine's")
    func thresholdsMatch() {
        #expect(WatchPairAgreement.minimumPairedWindows == ComparisonEngine.minimumPairedWindows)
        #expect(WatchSourceShape.allCases.count == SourceSymbol.allCases.count)
    }

    // MARK: Builder

    @Test("Periods are 1H/3H/24H/7D/30D; daily metrics offer only 7D and 30D")
    func periods() {
        #expect(WatchChartRange.allCases.map(\.rawValue) == ["1H", "3H", "24H", "7D", "30D"])
        #expect(WatchChartRange.allCases.map(\.duration) == [3_600, 10_800, 86_400, 604_800, 2_592_000])
        #expect(WatchChartRange.available(for: .heartRate) == WatchChartRange.allCases)
        #expect(WatchChartRange.available(for: .restingHeartRate) == [.week, .month])
        #expect(WatchSnapshotBuilder.standardRange(for: .heartRate) == .day)
        #expect(WatchSnapshotBuilder.standardRange(for: .restingHeartRate) == .week)
        #expect(WatchChartRange.resolved(.hour, among: [.week, .month]) == .week)
        #expect(WatchChartRange.resolved(.threeHours, among: [.hour, .day]) == .day)
        #expect(WatchChartRange.resolved(.month, among: [.hour]) == .hour)
        #expect(WatchChartRange.resolved(.day, among: []) == nil)

        #expect(WatchSnapshotBuilder.chartBucket(for: .heartRate, range: .hour) == 120)
        #expect(WatchSnapshotBuilder.chartBucket(for: .heartRate, range: .threeHours) == 360)
        #expect(WatchSnapshotBuilder.chartBucket(for: .heartRate, range: .day) == 2_880)
        #expect(WatchSnapshotBuilder.chartBucket(for: .bloodPressureSystolic, range: .hour) == 600)
        #expect(WatchSnapshotBuilder.chartBucket(for: .restingHeartRate, range: .month) == 86_400)
        for kind in MetricKind.allCases {
            for range in WatchChartRange.available(for: kind) {
                let bucket = WatchSnapshotBuilder.chartBucket(for: kind, range: range)
                #expect(bucket.truncatingRemainder(dividingBy: kind.comparisonWindow) == 0)
                #expect(range.duration / bucket <= Double(WatchChart.maximumPoints - 1))
            }
        }
    }

    @Test("Every offered period is sent with its own evidence; the 24-hour one fills the legacy slot")
    func builderRanges() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70)
        populate(store, sourceID: "b", value: 74)
        let snapshot = WatchSnapshotBuilder.make(store: store, now: now)
        let metric = try #require(snapshot.metrics.first { $0.kind == .heartRate })
        #expect(metric.availableRanges == WatchChartRange.allCases)
        #expect(metric.chart?.range == .day)
        #expect(metric.rangeCharts?.map(\.range) == [.hour, .threeHours, .week, .month])
        #expect(metric.comparison.lookback == 86_400)
        for range in WatchChartRange.allCases {
            let chart = try #require(metric.periodChart(range))
            #expect(chart.comparison?.lookback == range.duration)
            #expect(chart.comparison?.readyPairs == 1)
            #expect(chart.span <= range.duration + chart.bucket)
        }
        #expect(try WatchSnapshot.decode(snapshot.encoded()) == snapshot)
    }

    @Test("A period without readings is offered but empty, never a green verdict")
    func emptyPeriod() throws {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "a", displayName: "Source a", transport: .bluetooth))
        store.upsert(DataSource(id: "b", displayName: "Source b", transport: .bluetooth))
        for index in 0..<10 {
            let at = now.addingTimeInterval(-3 * 3_600 - Double(index) * 60)
            store.append(Reading(sourceID: "a", kind: .heartRate, value: 70, start: at))
            store.append(Reading(sourceID: "b", kind: .heartRate, value: 70, start: at))
        }
        let metric = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first)
        #expect(metric.availableRanges?.contains(.hour) == true)
        #expect(metric.periodChart(.hour) == nil)
        #expect(metric.periodComparison(.hour).readyPairs == 0)
        #expect(!metric.periodComparison(.hour).allPairsAgree)
        #expect(metric.periodComparison(.day).allPairsAgree)
    }

    @Test("Long periods come from the cache until data is removed; the hour is always fresh")
    func cache() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70)
        populate(store, sourceID: "b", value: 74)
        let cache = WatchChartCache()
        let first = try #require(WatchSnapshotBuilder.make(store: store, now: now, cache: cache).metrics.first)

        let late = Reading(sourceID: "a", kind: .heartRate, value: 90, start: now.addingTimeInterval(10))
        store.append(late)
        let second = try #require(WatchSnapshotBuilder.make(store: store, now: now.addingTimeInterval(30), cache: cache).metrics.first)
        #expect(second.periodChart(.month) == first.periodChart(.month))
        #expect(second.periodChart(.hour)?.series.first { $0.sourceName == "Source a" }?.values.last == 90)

        #expect(store.remove(readingIDs: [late.id]) == 1)
        let third = try #require(WatchSnapshotBuilder.make(store: store, now: now.addingTimeInterval(60), cache: cache).metrics.first)
        #expect(third.periodChart(.month)?.end == now.addingTimeInterval(60))

        // A rename is visible at once, even in a cached period.
        store.rename(sourceID: "a", to: "Renamed")
        let fourth = try #require(WatchSnapshotBuilder.make(store: store, now: now.addingTimeInterval(90), cache: cache).metrics.first)
        #expect(fourth.periodChart(.month)?.series.contains { $0.sourceName == "Renamed" } == true)
        #expect(WatchChartCache.refreshInterval(for: .hour) == 0)
        #expect(WatchChartCache.refreshInterval(for: .threeHours) == 0)
        #expect(WatchChartCache.refreshInterval(for: .month) == 3_600)
    }

    @Test("A removal drops only the cached periods that would still show the removed rows")
    func cacheRemovalReach() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70)
        populate(store, sourceID: "b", value: 74)
        let tenDaysAgo = Reading(sourceID: "a", kind: .heartRate, value: 80, start: now.addingTimeInterval(-10 * 86_400))
        #expect(store.append(tenDaysAgo))
        let cache = WatchChartCache()
        let first = try #require(WatchSnapshotBuilder.make(store: store, now: now, cache: cache).metrics.first)

        #expect(store.remove(readingIDs: [tenDaysAgo.id]) == 1)
        #expect(store.recentRemovals.last?.latestEnd == tenDaysAgo.end)
        let second = try #require(WatchSnapshotBuilder.make(store: store, now: now.addingTimeInterval(60), cache: cache).metrics.first)
        // Inside 30D only: that period is rebuilt; 7D and 24H stay as they were.
        #expect(second.periodChart(.month)?.end == now.addingTimeInterval(60))
        #expect(second.periodChart(.month)?.series.first { $0.sourceName == "Source a" }?.values.contains(80) == false)
        #expect(second.periodChart(.week) == first.periodChart(.week))
        #expect(second.periodChart(.day) == first.periodChart(.day))
    }

    @Test("Routine pruning keeps the cache; a shortened retention drops the periods it reaches")
    func cacheSurvivesRoutinePruning() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70)
        populate(store, sourceID: "b", value: 74)
        // Inside the 30-day period built now, and aged out by the prune below.
        #expect(store.append(Reading(sourceID: "b", kind: .heartRate, value: 74, start: now.addingTimeInterval(-30 * 86_400 + 30))))
        #expect(store.append(Reading(sourceID: "a", kind: .heartRate, value: 80, start: now.addingTimeInterval(-10 * 86_400))))
        let cache = WatchChartCache()
        let first = try #require(WatchSnapshotBuilder.make(store: store, now: now, cache: cache).metrics.first)

        let generation = store.removalGeneration
        #expect(store.prune(now: now.addingTimeInterval(60)))
        #expect(store.removalGeneration == generation + 1)
        let second = try #require(WatchSnapshotBuilder.make(store: store, now: now.addingTimeInterval(90), cache: cache).metrics.first)
        #expect(second.periodChart(.month) == first.periodChart(.month))
        #expect(second.periodChart(.week) == first.periodChart(.week))

        store.retention = 7 * 86_400
        #expect(store.prune(now: now.addingTimeInterval(120)))
        let third = try #require(WatchSnapshotBuilder.make(store: store, now: now.addingTimeInterval(150), cache: cache).metrics.first)
        #expect(third.periodChart(.month)?.end == now.addingTimeInterval(150))
        #expect(third.periodChart(.week) == first.periodChart(.week))
    }

    @Test("A cache older than the removal record is treated as reached")
    func removalRecordBounds() {
        let ends: [Date] = [30, 10, 20].map { Date(timeIntervalSince1970: $0) }
        let history = HealthHistory(
            sources: [],
            changeToken: 0,
            removalGeneration: 5,
            recentRemovals: zip(3...5, ends).map { HealthStore.RemovalRecord(generation: $0, latestEnd: $1) },
            loadState: .loaded,
            readers: nil,
            pending: [],
            unavailableDetail: nil
        )
        #expect(history.latestRemovedEnd(since: 5) == nil)
        #expect(history.latestRemovedEnd(since: 3) == ends[2])
        #expect(history.latestRemovedEnd(since: 2) == ends[0])
        #expect(history.latestRemovedEnd(since: 1) == .distantFuture)
        #expect(history.latestRemovedEnd(since: 6) == .distantFuture)

        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "a", displayName: "Source a", transport: .bluetooth))
        for index in 0...HealthStore.removalRecordLimit {
            let reading = Reading(sourceID: "a", kind: .heartRate, value: 70, start: now.addingTimeInterval(-Double(index) * 60))
            #expect(store.append(reading))
            #expect(store.remove(readingIDs: [reading.id]) == 1)
        }
        #expect(store.recentRemovals.count == HealthStore.removalRecordLimit)
        #expect(store.history.latestRemovedEnd(since: 0) == .distantFuture)
    }

    @Test("Periods built from one read equal periods read one at a time")
    func oneReadMatchesSeparateReads() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, minutes: 90)
        populate(store, sourceID: "b", value: 74, minutes: 90)
        for day in [2.0, 6.5, 12, 29] {
            #expect(store.append(Reading(sourceID: "a", kind: .heartRate, value: 71, start: now.addingTimeInterval(-day * 86_400))))
            #expect(store.append(Reading(sourceID: "b", kind: .heartRate, value: 75, start: now.addingTimeInterval(-day * 86_400))))
        }
        // Exactly on the 1H and 24H starts, which both reads include.
        for offset in [3_600.0, 86_400] {
            #expect(store.append(Reading(sourceID: "a", kind: .heartRate, value: 72, start: now.addingTimeInterval(-offset))))
        }
        let metric = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first { $0.kind == .heartRate })
        let shown = [store.source(id: "a"), store.source(id: "b")].compactMap { $0 }
        for range in WatchChartRange.allCases {
            let separate = WatchSnapshotBuilder.period(kind: .heartRate, range: range, now: now, shown: shown, store: store.history)
            #expect(metric.periodChart(range) == separate.chart)
            #expect(metric.periodComparison(range) == separate.comparison)
        }
    }

    @Test("Two sources sharing a colour slot are told apart by shape, as on iPhone")
    func sharedSlotShapes() throws {
        let store = HealthStore(persistenceEnabled: false)
        // One more device than there are slots: exactly one pair shares a slot, and which
        // pair is random, so find it.
        for index in 0...DataSource.paletteSlots.count {
            store.upsert(DataSource(id: "s\(index)", displayName: "Source \(index)", transport: .bluetooth))
        }
        let shared = Dictionary(grouping: store.sources, by: \.colorIndex).values.first { $0.count == 2 }
        let pair = try #require(shared)
        populate(store, sourceID: pair[0].id, value: 70)
        populate(store, sourceID: pair[1].id, value: 72)
        let chart = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first?.chart)
        #expect(chart.series.count == 2)
        #expect(Set(chart.series.map(\.symbol)).count == 2)
        #expect(chart.series[0].color == chart.series[1].color)
    }

    @Test("Axis ticks sit on round local times, away from both edges, two to four per period")
    func axisTicks() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        for range in WatchChartRange.allCases {
            let start = now.addingTimeInterval(-range.duration)
            let ticks = WatchChartProjection.axisTicks(range: range, start: start, end: now, timeZone: utc)
            #expect((2...4).contains(ticks.count), "\(range): \(ticks.count) ticks")
            let margin = range.duration * 0.08
            for tick in ticks {
                #expect(tick >= start.addingTimeInterval(margin) && tick <= now.addingTimeInterval(-margin))
                #expect(tick.timeIntervalSince1970.truncatingRemainder(dividingBy: WatchChartProjection.tickSpacing(for: range)) == 0)
            }
        }
    }

    @Test("Dropping for size removes 30D first and keeps the 24-hour chart")
    func dropOrder() throws {
        var snapshot = chartFixture()
        var day = try #require(snapshot.metrics[0].chart)
        day.range = .day
        var month = day
        month.range = .month
        month.series[0].offsets[0] = -1
        snapshot.metrics[0].chart = day
        snapshot.metrics[0].rangeCharts = [month]
        snapshot.metrics[0].availableRanges = [.day, .month]
        let fitted = WatchSnapshotBuilder.fitted(snapshot)
        #expect(fitted.metrics[0].chart == day)
        #expect(fitted.metrics[0].rangeCharts?.isEmpty == true)
        #expect(fitted.metrics[0].availableRanges == [.day])
        #expect((try? fitted.encoded()) != nil)
    }

    @Test("Each shown source gets its palette colour, shape, and window medians; the pair is A minus B")
    func builderSeries() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70)
        populate(store, sourceID: "b", value: 74)
        let snapshot = WatchSnapshotBuilder.make(store: store, now: now)
        let metric = try #require(snapshot.metrics.first { $0.kind == .heartRate })
        let chart = try #require(metric.chart)
        #expect(metric.comparison.lookback == 86_400)
        #expect(chart.end == now)
        #expect(chart.series.count == 2)
        #expect(Set(chart.series.map(\.id)) == Set(metric.readings.map(\.id)))

        let sourceA = try #require(store.source(id: "a"))
        let seriesA = try #require(chart.series.first { $0.sourceName == "Source a" })
        let slot = DataSource.paletteSlots[sourceA.colorIndex % DataSource.paletteSlots.count]
        #expect(seriesA.color == WatchColor(red: slot.dark.red, green: slot.dark.green, blue: slot.dark.blue))
        #expect(seriesA.symbol == SourceSymbol.forColorIndex(sourceA.colorIndex).rawValue)
        #expect(seriesA.values.allSatisfy { $0 == 70 })
        #expect(seriesA.offsets.allSatisfy { $0 >= 0 && $0 % 2_880 == 0 })
        #expect(!seriesA.isEstimated)

        let pair = try #require(chart.pair)
        #expect(pair.sourceA == "Source a")
        #expect(pair.meanBias == -4)
        #expect(pair.pairedWindows == 30)
        #expect(pair.withinTolerance)
        #expect(pair.differences.allSatisfy { $0 == -4 })
        #expect(pair.differenceOffsets.allSatisfy { $0 >= 0 })
        #expect(try WatchSnapshot.decode(snapshot.encoded()) == snapshot)
    }

    @Test("Estimates are charted and marked, but never form the pair")
    func estimatesMarked() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "ring", kind: .bloodPressureSystolic, value: 114, provenance: .estimated)
        populate(store, sourceID: "cuff", kind: .bloodPressureSystolic, value: 118)
        let metric = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first { $0.kind == .bloodPressureSystolic })
        let chart = try #require(metric.chart)
        #expect(chart.series.first { $0.sourceName == "Source ring" }?.isEstimated == true)
        #expect(chart.series.first { $0.sourceName == "Source cuff" }?.isEstimated == false)
        #expect(chart.pair == nil)
        #expect(metric.comparison.readyPairs == 0)
    }

    @Test("Fewer than five paired windows send no pair figures")
    func thinPairOmitted() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, minutes: 4)
        populate(store, sourceID: "b", value: 72, minutes: 4)
        let chart = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first?.chart)
        #expect(chart.pair == nil)
    }

    @Test("A pair outside tolerance is chosen over a larger pair inside it")
    func outsideTolerancePreferred() throws {
        let store = HealthStore(persistenceEnabled: false)
        populate(store, sourceID: "a", value: 70, minutes: 60)
        populate(store, sourceID: "b", value: 71, minutes: 60)
        populate(store, sourceID: "c", value: 90, minutes: 10)
        let pair = try #require(WatchSnapshotBuilder.make(store: store, now: now).metrics.first?.chart?.pair)
        #expect(!pair.withinTolerance)
        #expect(pair.sourceB == "Source c")
    }

    @Test("An oversized snapshot drops the same charts as a whole re-encode per drop, and is encoded once")
    func fittedPayloadMatchesExactSearch() throws {
        let kinds = MetricKind.allCases.filter { WatchChartRange.available(for: $0).count == WatchChartRange.allCases.count }
        func chart(_ kind: MetricKind, _ range: WatchChartRange) -> WatchChart {
            let bucket = range.duration / Double(WatchChart.maximumPoints)
            let base = ((kind.plausibleRange.lowerBound + kind.plausibleRange.upperBound) / 2).rounded()
            return WatchChart(
                start: now.addingTimeInterval(-range.duration),
                end: now,
                bucket: bucket,
                series: (0..<WatchSnapshot.maximumSourcesPerMetric).map { source in
                    WatchChartSeries(
                        id: "source-\(source)", sourceName: "Source \(source)",
                        color: WatchColor(red: 0.4, green: 0.6, blue: 0.9), symbol: source, isEstimated: false,
                        offsets: (0..<WatchChart.maximumPoints).map { Int(Double($0) * bucket) },
                        values: (0..<WatchChart.maximumPoints).map { base + Double(($0 * 7 + source) % 10) / 10 }
                    )
                },
                range: range
            )
        }
        let metrics = kinds.map { kind in
            WatchMetric(
                kind: kind,
                readings: [WatchSourceReading(id: "source-0", sourceName: "Source 0", value: kind.plausibleRange.lowerBound, timestamp: now, provenance: .measured, isCompacted: false)],
                omittedSourceCount: 0,
                comparison: WatchComparison(readyPairs: 0, incompletePairs: 0, outsideTolerancePairs: 0, lookback: 86_400),
                chart: chart(kind, .day),
                rangeCharts: [.hour, .threeHours, .week, .month].map { chart(kind, $0) },
                availableRanges: WatchChartRange.allCases
            )
        }
        let snapshot = WatchSnapshot(generatedAt: now, metrics: metrics)
        #expect(throws: WatchSnapshot.PayloadError.tooLarge) { try snapshot.encoded() }

        // The previous algorithm: encode the whole snapshot after every drop.
        var exact = snapshot
        search: for range in WatchSnapshotBuilder.dropOrder {
            for index in exact.metrics.indices.reversed() where exact.metrics[index].periodChart(range) != nil {
                WatchSnapshotBuilder.remove(range, from: &exact.metrics[index])
                if (try? exact.encoded()) != nil { break search }
            }
        }
        let payload = WatchSnapshotBuilder.fittedPayload(snapshot)
        #expect(payload.snapshot == exact)
        #expect(payload.snapshot.metrics.contains { $0.periodChart(.month) == nil })
        #expect(payload.snapshot.metrics.allSatisfy { $0.chart != nil })
        let data = try #require(payload.data)
        // Key order in `JSONEncoder` output can vary between runs; the length cannot.
        #expect(data.count == (try payload.snapshot.encoded()).count)
        #expect(try WatchSnapshot.decode(data) == payload.snapshot)
    }

    @Test("A chart that cannot be sent is dropped; the readings and verdict still travel")
    func fittedDropsCharts() throws {
        var snapshot = chartFixture()
        snapshot.metrics[0].chart?.series[0].offsets[0] = -1
        let fitted = WatchSnapshotBuilder.fitted(snapshot)
        #expect(fitted.metrics[0].chart == nil)
        #expect(fitted.metrics[0].readings == snapshot.metrics[0].readings)
        #expect((try? fitted.encoded()) != nil)
    }

    // MARK: Projection

    @Test("Lines break at missing windows and lone windows are points")
    func segmentation() throws {
        let chart = try #require(chartFixture().metrics[0].chart)
        let points = WatchChartProjection.points(for: chart.series[0], in: chart)
        #expect(points.map(\.segment) == [0, 0, 1])
        #expect(points.map(\.isIsolated) == [false, false, true])
        #expect(points[0].date == chart.start.addingTimeInterval(240))
        #expect(Set(points.map(\.segmentKey)).count == 2)
    }

    @Test("Axes include the usual range, every value, zero, and both limits")
    func domains() throws {
        let chart = try #require(chartFixture().metrics[0].chart)
        let values = WatchChartProjection.valueDomain(kind: .heartRate, chart: chart)
        #expect(values.lowerBound <= 40 && values.upperBound >= 160)
        let pair = try #require(chart.pair)
        let differences = WatchChartProjection.differenceDomain(pair: pair)
        #expect(differences.contains(0) && differences.contains(pair.lowerLimit) && differences.contains(pair.upperLimit))
    }

    @Test("Spoken summaries name each source and the pair without claiming agreement")
    func spoken() throws {
        let chart = try #require(chartFixture().metrics[0].chart)
        let summary = WatchChartProjection.spokenSummary(kind: .heartRate, chart: chart, lookback: 6 * 3_600)
        #expect(summary.contains("Chest strap"))
        #expect(summary.contains("3 windows"))
        let pair = WatchChartProjection.pairSummary(kind: .heartRate, pair: try #require(chart.pair))
        #expect(pair.contains("Chest strap minus Ring"))
        #expect(pair.contains("6 paired windows"))
        #expect(!pair.lowercased().contains("agree"))
        #expect(WatchChartProjection.periodText(6 * 3_600) == "Past 6 hours")
        #expect(WatchChartProjection.periodText(7 * 86_400) == "Past 7 days")
        #expect(WatchChartProjection.periodText(3_600) == "Past hour")
    }
}
