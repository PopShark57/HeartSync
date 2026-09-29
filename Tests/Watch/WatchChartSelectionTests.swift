import Foundation
import Testing
@testable import HeartSyncChecker

/// Tapping or touching and holding a wrist chart: which window is picked, what the popup
/// and VoiceOver say, and that a touch in empty plot area picks nothing.
@Suite("Watch chart selection")
struct WatchChartSelectionTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: 86_400))
    private let utc = TimeZone(identifier: "UTC")!

    private func chart() -> WatchChart {
        WatchChart(
            start: start,
            end: start.addingTimeInterval(3_600),
            bucket: 300,
            series: [
                WatchChartSeries(
                    id: "strap", sourceName: "Chest strap",
                    color: WatchColor(red: 0.4, green: 0.6, blue: 1), symbol: 0, isEstimated: false,
                    offsets: [0, 300, 1_200], values: [70, 71, 74]
                ),
                WatchChartSeries(
                    id: "ring", sourceName: "Ring",
                    color: WatchColor(red: 1, green: 0.6, blue: 0.2), symbol: 1, isEstimated: true,
                    offsets: [300, 900], values: [69, 72]
                ),
            ],
            range: .hour
        )
    }

    @Test("Every drawn window is listed once, ascending, with each source's value at its middle")
    func windowsGroupSeries() {
        let windows = WatchChartProjection.windows(in: chart())

        #expect(windows.map { $0.start.timeIntervalSince(start) } == [0, 300, 900, 1_200])
        #expect(windows.map { $0.date.timeIntervalSince($0.start) } == [150, 150, 150, 150])
        #expect(windows.allSatisfy { $0.end.timeIntervalSince($0.start) == 300 })
        let shared = windows[1]
        #expect(shared.entries.map(\.seriesID) == ["strap", "ring"])
        #expect(shared.entries.map(\.value) == [71, 69])
        #expect(shared.entries[1].isEstimated)
        #expect(shared.entries[1].shape == .square)
        // Drawn where the chart draws the points.
        let points = WatchChartProjection.points(for: chart().series[0], in: chart())
        #expect(points.map(\.date) == [windows[0].date, windows[1].date, windows[3].date])
    }

    @Test("A touch snaps to the nearest window inside the radius and picks nothing outside it")
    func nearestWithinRadius() {
        let dates = WatchChartProjection.windows(in: chart()).map(\.date)

        let near = WatchChartProjection.nearestDate(to: dates[2].addingTimeInterval(40), in: dates, within: 60)
        #expect(near == dates[2])
        // Midway between 1 050 s and 1 350 s is 150 s from both: farther than the radius.
        let empty = WatchChartProjection.nearestDate(to: start.addingTimeInterval(1_950), in: dates, within: 60)
        #expect(empty == nil)
        // Before the chart is measured there is no radius, so the nearest window is taken.
        #expect(WatchChartProjection.nearestDate(to: start.addingTimeInterval(3_500), in: dates, within: nil) == dates[3])
        #expect(WatchChartProjection.nearestDate(to: start, in: [], within: nil) == nil)
    }

    @Test("The selection radius is 22 points of the measured plot width")
    func radiusFromPlotWidth() {
        let tolerance = ChartLookup.timeTolerance(
            points: ChartLookup.selectionRadius,
            plotWidth: 176,
            domain: start...start.addingTimeInterval(3_600)
        )
        #expect(tolerance == 450)
    }

    @Test("VoiceOver steps from the newest window and stops at either end")
    func stepping() {
        let dates = WatchChartProjection.windows(in: chart()).map(\.date)

        #expect(WatchChartProjection.steppedDate(from: nil, in: dates, forward: false) == dates[3])
        #expect(WatchChartProjection.steppedDate(from: dates[3], in: dates, forward: false) == dates[2])
        #expect(WatchChartProjection.steppedDate(from: dates[3], in: dates, forward: true) == dates[3])
        #expect(WatchChartProjection.steppedDate(from: dates[0], in: dates, forward: false) == dates[0])
        #expect(WatchChartProjection.steppedDate(from: nil, in: [], forward: true) == nil)
    }

    @Test("The popup's time is the window's local span, with weekdays once a period spans days")
    func windowText() {
        let window = WatchChartProjection.windows(in: chart())[1]

        let short = WatchChartProjection.windowText(start: window.start, end: window.end, range: .hour, timeZone: utc)
        #expect(short.contains("05"))
        #expect(short.contains("10"))
        let long = WatchChartProjection.windowText(start: window.start, end: window.end, range: .week, timeZone: utc)
        #expect(long != short)
        #expect(long.count > short.count)
    }

    @Test("VoiceOver reads each source's median in the window and marks estimates")
    func spokenSelection() {
        let window = WatchChartProjection.windows(in: chart())[1]
        let spoken = WatchChartProjection.selectionSummary(kind: .heartRate, window: window, range: .hour)

        #expect(spoken.contains("median"))
        #expect(spoken.contains("Chest strap \(MetricKind.heartRate.formatWithUnit(71))"))
        #expect(spoken.contains("Ring, estimate \(MetricKind.heartRate.formatWithUnit(69))"))
    }

    @Test("A selected difference reads as A minus B for its window")
    func spokenDifference() {
        let pair = WatchPairAgreement(
            sourceA: "Chest strap", sourceB: "Ring", pairedWindows: 6,
            meanBias: 1.5, lowerLimit: -1, upperLimit: 4, withinTolerance: true,
            differenceOffsets: [0, 300], differences: [2, -1]
        )
        let points = WatchChartProjection.differencePoints(for: pair, in: chart(), window: 300)
        let spoken = WatchChartProjection.differenceSummary(kind: .heartRate, pair: pair, point: points[1], window: 300, range: .hour)

        #expect(spoken.contains("Chest strap minus Ring"))
        #expect(spoken.contains(WatchChartProjection.signed(-1, kind: .heartRate)))
    }
}
