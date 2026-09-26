import Foundation
import Testing
@testable import HeartSyncChecker

/// Zoom, pan, and period selection on the history chart (improvement 33).
///
/// Pins the viewport arithmetic the buttons drive, the semantic-zoom rule that re-reads a
/// visible span at a finer bucket, and the promise that a period dragged out on the chart
/// has exactly the statistics — and, once saved, exactly the bounds — of the same span
/// opened as a saved session.
@Suite("History chart zoom and period selection")
@MainActor
struct ChartZoomTests {

    /// On the one-hour grid, so every preset bucket divides evenly into it.
    private let origin = Date(timeIntervalSince1970: 1_699_999_200)
    private var week: DateInterval { DateInterval(start: origin, duration: 604_800) }

    // MARK: - Zoom levels and buckets

    @Test("Zoom steps down through the presets, never below what the metric can show")
    func zoomSpans() {
        #expect(ChartViewport.zoomSpans(forPeriod: 604_800, kind: .heartRate) == [86_400, 21_600, 3_600])
        #expect(ChartViewport.zoomSpans(forPeriod: 86_400, kind: .hrvRMSSD) == [21_600, 3_600])
        // A daily resting heart rate cannot usefully be drawn over less than a few days.
        #expect(ChartViewport.zoomSpans(forPeriod: 2_592_000, kind: .restingHeartRate) == [604_800])
        #expect(ChartViewport.zoomSpans(forPeriod: 604_800, kind: .restingHeartRate).isEmpty)
        // A 45-minute saved session is already drawn at the finest bucket.
        #expect(ChartViewport.zoomSpans(forPeriod: 2_700, kind: .heartRate).isEmpty)
    }

    @Test("A week zooms to one hour drawn from one-minute medians, and the bucket is named")
    func weekZoomsToOneMinuteMedians() throws {
        let day = try #require(ChartViewport.zoomedIn(from: nil, period: week, kind: .heartRate))
        #expect(day.visible.duration == 86_400)
        #expect(day.bucket(for: .heartRate) == 900)

        let sixHours = try #require(ChartViewport.zoomedIn(from: day, period: week, kind: .heartRate))
        #expect(sixHours.visible.duration == 21_600)
        #expect(sixHours.bucket(for: .heartRate) == 300)

        let hour = try #require(ChartViewport.zoomedIn(from: sixHours, period: week, kind: .heartRate))
        #expect(hour.visible.duration == 3_600)
        #expect(hour.bucket(for: .heartRate) == 60)
        #expect(ChartViewport.bucketDescription(hour.bucket(for: .heartRate)) == "1-minute medians")

        #expect(!ChartViewport.canZoomIn(from: hour, period: week, kind: .heartRate))
        #expect(ChartViewport.zoomedIn(from: hour, period: week, kind: .heartRate) == nil)
        // Unzoomed, the chart uses the same rule the whole-period snapshot does.
        #expect(ChartViewport.bucket(forSpan: week.duration, kind: .heartRate)
            == max(MetricKind.heartRate.comparisonWindow, ComparisonPeriod.rolling(.week).chartBucket))
    }

    @Test("Zooming in centres on the selected window and never leaves the period")
    func zoomCentresOnTheAnchorInsideThePeriod() throws {
        let middle = origin.addingTimeInterval(3 * 86_400 + 7_200)
        let centred = try #require(ChartViewport.zoomedIn(from: nil, period: week, kind: .heartRate, toward: middle))
        #expect(centred.visible.contains(middle))
        #expect(abs(centred.visible.start.addingTimeInterval(43_200).timeIntervalSince(middle)) < 900)

        let nearStart = try #require(ChartViewport.zoomedIn(from: nil, period: week, kind: .heartRate, toward: origin.addingTimeInterval(60)))
        #expect(nearStart.visible.start == origin)

        let nearEnd = try #require(ChartViewport.zoomedIn(from: nil, period: week, kind: .heartRate, toward: week.end))
        #expect(nearEnd.visible.end == week.end)
    }

    @Test("Zooming out steps back up, and the last step out is the whole period")
    func zoomOutReturnsToThePeriod() throws {
        let hour = ChartViewport.placed(centre: origin.addingTimeInterval(86_400), span: 3_600, period: week, kind: .heartRate)
        let sixHours = try #require(hour.zoomedOut(period: week, kind: .heartRate))
        #expect(sixHours.visible.duration == 21_600)
        let day = try #require(sixHours.zoomedOut(period: week, kind: .heartRate))
        #expect(day.visible.duration == 86_400)
        #expect(day.zoomedOut(period: week, kind: .heartRate) == nil)
    }

    // MARK: - Pan

    @Test("Panning moves half a span and stops at either edge of the period")
    func panningStopsAtTheEdges() {
        let first = ChartViewport.placed(centre: origin, span: 3_600, period: week, kind: .heartRate)
        #expect(first.visible.start == origin)
        #expect(!first.canPan(.earlier, period: week, kind: .heartRate))
        #expect(first.canPan(.later, period: week, kind: .heartRate))

        let later = first.panned(.later, period: week, kind: .heartRate)
        #expect(later.visible.start == origin.addingTimeInterval(1_800))
        #expect(later.visible.duration == 3_600)

        let last = ChartViewport.placed(centre: week.end, span: 3_600, period: week, kind: .heartRate)
        #expect(last.visible.end == week.end)
        #expect(!last.canPan(.later, period: week, kind: .heartRate))
        #expect(last.panned(.earlier, period: week, kind: .heartRate).visible.end == week.end.addingTimeInterval(-1_800))
    }

    @Test("A rolling range's live edge stays reachable though now is off the bucket grid")
    func latestViewportEndsAtNow() {
        let rolling = DateInterval(start: origin.addingTimeInterval(17.25), duration: 604_800)
        let latest = ChartViewport.placed(centre: rolling.end, span: 3_600, period: rolling, kind: .heartRate)
        #expect(latest.visible.end == rolling.end)
        #expect(latest.visible.duration == 3_600)
    }

    @Test("A live reload leaves a fitting viewport exactly where the user put it")
    func clampedKeepsTheUsersView() throws {
        let view = ChartViewport.placed(centre: origin.addingTimeInterval(3 * 86_400), span: 3_600, period: week, kind: .heartRate)
        // The rolling week slid forward by ten minutes; the view still fits.
        let slid = DateInterval(start: week.start.addingTimeInterval(600), duration: week.duration)
        #expect(view.clamped(to: slid, kind: .heartRate) == view)

        // The period moved past the view's start: it moves only as far as it must.
        let early = ChartViewport.placed(centre: origin, span: 3_600, period: week, kind: .heartRate)
        let moved = try #require(early.clamped(to: slid, kind: .heartRate))
        #expect(moved.visible.start == slid.start)
        #expect(moved.visible.duration == 3_600)

        // A span that no longer fits returns the chart to the whole period.
        let short = DateInterval(start: origin, duration: 1_800)
        #expect(view.clamped(to: short, kind: .heartRate) == nil)
    }

    // MARK: - Semantic zoom

    @Test("A zoomed chart re-reads just the visible span at the finer bucket")
    func zoomedChartIsReReadAtTheFinerBucket() throws {
        let store = HealthStore(persistenceEnabled: false)
        let strap = DataSource(id: "a-strap", displayName: "Strap", transport: .bluetooth)
        let ring = DataSource(id: "b-ring", displayName: "Ring", transport: .oura, colorIndex: 1)
        store.upsert(strap)
        store.upsert(ring)
        let end = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-600), size: 3_600)
        for minute in 0..<120 {
            let stamp = end.addingTimeInterval(Double(minute - 120) * 60 + 2)
            _ = store.append(Reading(sourceID: strap.id, kind: .heartRate, value: 60 + Double(minute % 7), start: stamp))
            _ = store.append(Reading(sourceID: ring.id, kind: .heartRate, value: 62, start: stamp.addingTimeInterval(5)))
        }
        _ = store.append(Reading(sourceID: strap.id, kind: .heartRate, value: 58, start: end.addingTimeInterval(-3 * 86_400)))

        let weekSnapshot = MetricDetailSnapshot(store: store, kind: .heartRate, range: .week, includeEstimates: false, hrvQuality: [:])
        #expect(weekSnapshot.bucketSize == 3_600)

        let viewport = ChartViewport(visible: DateInterval(start: end.addingTimeInterval(-3_600), duration: 3_600))
        let zoomed = MetricZoomSnapshot(
            store: store,
            kind: .heartRate,
            viewport: viewport,
            includeEstimates: false,
            series: weekSnapshot.series
        )
        #expect(zoomed.queryFailure == nil)
        #expect(zoomed.chart.bucketSize == 60)
        #expect(zoomed.chart.windows.count == 60)
        #expect(zoomed.chart.windows.allSatisfy { viewport.visible.contains($0.start) })
        #expect(zoomed.chart.xDomain == viewport.visible.start...viewport.visible.end)
        // Sixty one-minute medians where the week's chart has one hourly median: real detail,
        // not a magnified coarse point.
        #expect(weekSnapshot.chart.windows.filter { viewport.visible.contains($0.start) }.count <= 2)
        // Every zoomed value is the engine's own one-minute median for that window.
        let direct = ComparisonEngine.windows(
            from: store.readings(kind: .heartRate, in: viewport.visible),
            kind: .heartRate,
            windowSize: 60,
            range: viewport.visible
        )
        #expect(zoomed.chart.windows.map(\.start) == direct.map(\.start))
        #expect(zoomed.chart.windows.map { $0.values.map(\.value) } == direct.map { window in
            weekSnapshot.series.compactMap { entry in window.value(for: entry.sourceID)?.value }
        })
    }

    @Test("A failed zoom read is reported, not drawn as an empty hour")
    func zoomReadFailureIsCarried() {
        let store = HealthStore(persistenceEnabled: false)
        store.injectQueryFailureForTesting()
        let viewport = ChartViewport(visible: DateInterval(start: origin, duration: 3_600))
        let zoomed = MetricZoomSnapshot(store: store, kind: .heartRate, viewport: viewport, includeEstimates: false, series: [])
        #expect(zoomed.queryFailure != nil)
        #expect(zoomed.chart.windows.isEmpty)
    }

    // MARK: - Period selection

    @Test("A dragged period snaps outward to the drawn buckets, in either direction")
    func draggedPeriodSnapsOutward() throws {
        let bounds = origin...origin.addingTimeInterval(86_400)
        let forward = try #require(ChartViewport.snappedPeriod(
            from: origin.addingTimeInterval(125),
            to: origin.addingTimeInterval(1_790),
            bucket: 300,
            within: bounds
        ))
        #expect(forward.start == origin)
        #expect(forward.end == origin.addingTimeInterval(1_800))

        let backward = ChartViewport.snappedPeriod(
            from: origin.addingTimeInterval(1_790),
            to: origin.addingTimeInterval(125),
            bucket: 300,
            within: bounds
        )
        #expect(backward == forward)

        // An end already on a boundary stays there rather than growing a bucket.
        let exact = ChartViewport.snappedPeriod(from: origin, to: origin.addingTimeInterval(600), bucket: 300, within: bounds)
        #expect(exact?.duration == 600)

        // A tap in period mode is not a chosen period.
        #expect(ChartViewport.snappedPeriod(from: origin, to: origin, bucket: 300, within: bounds) == nil)
    }

    @Test("A dragged period stays inside the chart and ends on a whole second")
    func draggedPeriodIsClampedToWholeSeconds() throws {
        // A rolling range ends at a fractional "now"; the archive stores whole seconds.
        let bounds = origin...origin.addingTimeInterval(3_600.75)
        let clamped = try #require(ChartViewport.snappedPeriod(
            from: origin.addingTimeInterval(-500),
            to: origin.addingTimeInterval(9_999),
            bucket: 60,
            within: bounds
        ))
        #expect(clamped.start == origin)
        #expect(clamped.end == origin.addingTimeInterval(3_600))
        #expect(clamped.end.timeIntervalSince1970 == clamped.end.timeIntervalSince1970.rounded())
    }

    /// Two devices, thirty paired minutes ending twenty minutes ago.
    private func pairedStore() -> (HealthStore, Date) {
        let store = HealthStore(persistenceEnabled: false)
        store.upsert(DataSource(id: "a-strap", displayName: "Strap", transport: .bluetooth))
        store.upsert(DataSource(id: "b-ring", displayName: "Ring", transport: .oura, colorIndex: 1))
        let anchor = ComparisonEngine.floorToWindow(Date.now.addingTimeInterval(-50 * 60), size: 300)
        for minute in 0..<30 {
            let stamp = anchor.addingTimeInterval(Double(minute) * 60 + 4)
            _ = store.append(Reading(sourceID: "a-strap", kind: .heartRate, value: 70 + Double(minute % 4), start: stamp))
            _ = store.append(Reading(sourceID: "b-ring", kind: .heartRate, value: 73 - Double(minute % 3), start: stamp.addingTimeInterval(6)))
        }
        return (store, anchor)
    }

    @Test("A brushed period has exactly the statistics of the same span opened as a saved session")
    func brushedStatisticsMatchTheSavedSession() throws {
        let (store, anchor) = pairedStore()
        let bounds = anchor...anchor.addingTimeInterval(3_600)
        let brushed = try #require(ChartViewport.snappedPeriod(
            from: anchor.addingTimeInterval(310),
            to: anchor.addingTimeInterval(1_190),
            bucket: 300,
            within: bounds
        ))
        #expect(brushed.duration == 900)

        let evidence = MetricPeriodEvidence(store: store, kind: .heartRate, interval: brushed)
        let session = ComparisonSession(interval: brushed, sourceIDs: ["a-strap", "b-ring"], metric: .heartRate)
        let reopened = MetricDetailSnapshot(store: store, kind: .heartRate, period: session.period, includeEstimates: false, hrvQuality: [:])

        #expect(evidence.queryFailure == nil)
        #expect(evidence.analyses == reopened.pairwiseAnalyses)
        let pair = try #require(evidence.analyses.first)
        #expect(pair.range == brushed)
        #expect(pair.pairedWindowCount == 15)
        #expect(pair.statistics != nil)
    }

    @Test("A brushed period saved as a session reopens with identical bounds")
    func brushedPeriodSurvivesSaveAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heartsync-brush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = ReadingArchive(directory: directory)

        // Brushed up to a rolling range's fractional "now".
        let now = origin.addingTimeInterval(86_400.618)
        let brushed = try #require(ChartViewport.snappedPeriod(
            from: now.addingTimeInterval(-2_000),
            to: now,
            bucket: 60,
            within: origin...now
        ))

        let sessions = ComparisonSessionStore(archive: archive, archiveName: "brush-test.json")
        await sessions.loadIfNeeded()
        let saved = ComparisonSession(title: "Brushed", interval: brushed, sourceIDs: ["a", "b"], metric: .heartRate)
        #expect(await sessions.save(saved))

        let reloaded = ComparisonSessionStore(archive: archive, archiveName: "brush-test.json")
        await reloaded.loadIfNeeded()
        let restored = try #require(reloaded.sessions.first)
        #expect(restored.interval == brushed)
        #expect(restored.metric == .heartRate)
        #expect(restored.period == .fixed(brushed))
    }
}
