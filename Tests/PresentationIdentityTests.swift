import Foundation
import Testing
@testable import HeartSyncChecker

/// Chart series identity (improvement 18) and the Compare empty-state distinction
/// (improvement 24).
///
/// Both are deliberately expressed as pure functions over already-resolved facts so they
/// can be exercised here. A SwiftUI rendering assertion is not available in this bundle,
/// so these cover the projection and the decision, not the drawn pixels.
@Suite("Chart series identity and Compare empty states")
struct PresentationIdentityTests {

    private func source(
        id: String,
        name: String,
        transport: SourceTransport = .bluetooth,
        model: String? = nil,
        colorIndex: Int = 0
    ) -> DataSource {
        var source = DataSource(id: id, displayName: name, transport: transport, model: model)
        source.colorIndex = colorIndex
        return source
    }

    // MARK: - Improvement 18

    @MainActor
    @Test("Two sources sharing a display name remain two independently keyed series")
    func duplicateNamesStaySeparateSeries() {
        let sources = [
            source(id: "aaaaaaaa-0000-0000-0000-0000000000ab", name: "Polar H10", colorIndex: 0),
            source(id: "bbbbbbbb-0000-0000-0000-0000000000cd", name: "Polar H10", transport: .healthKit, colorIndex: 1),
        ]
        let series = MetricDetailSnapshot.makeSeries(for: sources)

        #expect(series.count == 2)
        // The grouping key is the stable ID, never the name.
        #expect(Set(series.map(\.sourceID)).count == 2)
        // And the legend must not print the same words twice.
        #expect(Set(series.map(\.label)).count == 2)
        #expect(series[0].label == "Polar H10 (Bluetooth)")
        #expect(series[1].label == "Polar H10 (Apple Health)")
        // Colour is not the only channel separating them.
        #expect(series[0].symbol != series[1].symbol)
    }

    @MainActor
    @Test("A single unambiguous source keeps its plain display name")
    func uniqueNameIsNotDecorated() {
        let series = MetricDetailSnapshot.makeSeries(for: [
            source(id: "aaaaaaaa-0000-0000-0000-0000000000ab", name: "Polar H10"),
        ])
        #expect(series.map(\.label) == ["Polar H10"])
    }

    @MainActor
    @Test("Same name and same transport fall back to model, then to a short identifier")
    func collidingTransportsDisambiguateFurther() {
        let withModels = MetricDetailSnapshot.makeSeries(for: [
            source(id: "aaaaaaaa-0000-0000-0000-0000000000ab", name: "Ring", model: "Gen 3"),
            source(id: "bbbbbbbb-0000-0000-0000-0000000000cd", name: "Ring", model: "Gen 4"),
        ])
        #expect(withModels.map(\.label) == ["Ring (Bluetooth, Gen 3)", "Ring (Bluetooth, Gen 4)"])

        let withoutModels = MetricDetailSnapshot.makeSeries(for: [
            source(id: "aaaaaaaa-0000-0000-0000-0000000000ab", name: "Ring"),
            source(id: "bbbbbbbb-0000-0000-0000-0000000000cd", name: "Ring"),
        ])
        #expect(Set(withoutModels.map(\.label)).count == 2)
        #expect(withoutModels[0].label.hasSuffix("0000AB)"))
        #expect(withoutModels[1].label.hasSuffix("0000CD)"))
    }

    @MainActor
    @Test("Renaming a source changes its label but not its series key or colour")
    func renamePreservesSeriesIdentity() {
        let before = MetricDetailSnapshot.makeSeries(for: [
            source(id: "aaaaaaaa-0000-0000-0000-0000000000ab", name: "Old name", colorIndex: 3),
        ])
        let after = MetricDetailSnapshot.makeSeries(for: [
            source(id: "aaaaaaaa-0000-0000-0000-0000000000ab", name: "New name", colorIndex: 3),
        ])

        #expect(before[0].sourceID == after[0].sourceID)
        #expect(before[0].color == after[0].color)
        #expect(before[0].label != after[0].label)
    }

    @MainActor
    @Test("Chart points carry the source ID that keys their series")
    func chartPointsCarrySourceID() {
        let store = HealthStore(persistenceEnabled: false)
        let first = source(id: "aaaaaaaa-0000-0000-0000-0000000000ab", name: "Shared name")
        let second = source(id: "bbbbbbbb-0000-0000-0000-0000000000cd", name: "Shared name", transport: .oura)
        store.upsert(first)
        store.upsert(second)

        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-600), size: 60)
        for index in 0..<4 {
            let stamp = anchor.addingTimeInterval(Double(index) * 60)
            _ = store.append(Reading(sourceID: first.id, kind: .heartRate, value: 70, start: stamp))
            _ = store.append(Reading(sourceID: second.id, kind: .heartRate, value: 75, start: stamp))
        }

        let snapshot = MetricDetailSnapshot(
            store: store,
            kind: .heartRate,
            range: .day,
            includeEstimates: false,
            hrvQuality: [:]
        )

        #expect(Set(snapshot.points.map(\.sourceID)) == [first.id, second.id])
        // The scale domain the chart binds to is the ID domain, not the name domain.
        #expect(Set(snapshot.styleDomain) == [first.id, second.id])
        #expect(snapshot.styleRange.count == snapshot.styleDomain.count)
        #expect(snapshot.symbolRange.count == snapshot.styleDomain.count)
    }

    // MARK: - Improvement 24

    @Test("An empty install is distinguished from an empty range")
    func emptyInstallIsNotAnEmptyRange() {
        #expect(
            ComparisonEmptyReason.resolve(comparableMetricCount: 0, sourcesInRange: 0, hasStoredReadings: false)
                == .noStoredData
        )
        #expect(
            ComparisonEmptyReason.resolve(comparableMetricCount: 0, sourcesInRange: 0, hasStoredReadings: true)
                == .noDataInRange
        )
    }

    @Test("One reporting source is reported as such, not as missing data")
    func singleSourceHasItsOwnReason() {
        #expect(
            ComparisonEmptyReason.resolve(comparableMetricCount: 0, sourcesInRange: 1, hasStoredReadings: true)
                == .singleSourceInRange
        )
    }

    @Test("Two sources with no metric in common is a shared-metric problem")
    func twoSourcesWithoutSharedMetric() {
        #expect(
            ComparisonEmptyReason.resolve(comparableMetricCount: 0, sourcesInRange: 2, hasStoredReadings: true)
                == .noSharedMetric
        )
    }

    @Test("Only a truly empty install withholds the widen-range action")
    func wideningIsOfferedWhereItCouldHelp() {
        #expect(ComparisonEmptyReason.noStoredData.suggestsWidening == false)
        #expect(ComparisonEmptyReason.noDataInRange.suggestsWidening)
        #expect(ComparisonEmptyReason.singleSourceInRange.suggestsWidening)
        #expect(ComparisonEmptyReason.noSharedMetric.suggestsWidening)
    }

    @Test("Every range but the widest offers a wider one")
    func widerRangeChainTerminates() {
        #expect(TimeRange.hour.wider == .sixHours)
        #expect(TimeRange.sixHours.wider == .day)
        #expect(TimeRange.day.wider == .week)
        #expect(TimeRange.week.wider == .month)
        #expect(TimeRange.month.wider == nil)
    }
}

/// Chart line segmentation across data gaps (improvement 20).
@Suite("Chart gap segmentation")
@MainActor
struct ChartSegmentationTests {

    private func point(_ sourceID: String, _ offset: TimeInterval) -> ChartPoint {
        ChartPoint(
            id: "\(sourceID)-\(offset)",
            date: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            value: 70,
            sourceID: sourceID,
            sourceName: sourceID,
            isEstimate: false
        )
    }

    @Test("Consecutive buckets stay one connected line")
    func consecutiveBucketsShareASegment() {
        let segmented = MetricDetailSnapshot.segmented(
            [point("a", 0), point("a", 60), point("a", 120)],
            bucketSize: 60
        )
        #expect(Set(segmented.map(\.seriesKey)).count == 1)
    }

    @Test("A missed window breaks the line rather than drawing through the gap")
    func gapStartsANewSegment() {
        // 0, 60, then nothing until 600: the curve must not span the hole.
        let segmented = MetricDetailSnapshot.segmented(
            [point("a", 0), point("a", 60), point("a", 600), point("a", 660)],
            bucketSize: 60
        )
        let keys = segmented.sorted { $0.date < $1.date }.map(\.seriesKey)

        #expect(keys[0] == keys[1])
        #expect(keys[2] == keys[3])
        #expect(keys[1] != keys[2])
        // Still one device, so the colour/symbol key is untouched.
        #expect(Set(segmented.map(\.sourceID)) == ["a"])
    }

    @Test("Each source is segmented independently")
    func sourcesSegmentIndependently() {
        let segmented = MetricDetailSnapshot.segmented(
            [point("a", 0), point("a", 600), point("b", 0), point("b", 60)],
            bucketSize: 60
        )
        let a = segmented.filter { $0.sourceID == "a" }
        let b = segmented.filter { $0.sourceID == "b" }

        #expect(Set(a.map(\.seriesKey)).count == 2)
        #expect(Set(b.map(\.seriesKey)).count == 1)
        // No segment key is ever shared between two devices.
        #expect(Set(a.map(\.seriesKey)).isDisjoint(with: Set(b.map(\.seriesKey))))
    }

    @Test("An isolated observation gets its own segment and stays plotted")
    func isolatedObservationSurvives() {
        let segmented = MetricDetailSnapshot.segmented([point("a", 0)], bucketSize: 60)
        #expect(segmented.count == 1)
        #expect(segmented[0].seriesKey.isEmpty == false)
    }
}
