import Accessibility
import SwiftUI

/// The Audio Graph for the metric-detail chart: one series per device, named with the
/// device's display label.
///
/// Swift Charts builds an Audio Graph automatically, but it names series by the value that
/// keys them, which here is the stable source ID, not a name a listener recognises. This
/// descriptor replaces it with the same points the chart draws (window medians per device),
/// so the graph plays each device as its own series and says which one it is. Estimated and
/// compacted windows carry that caveat as the point's label.
struct MetricAudioGraph: AXChartDescriptorRepresentable {
    let kind: MetricKind
    let chart: MetricChartProjection
    let series: [SourceSeries]

    func makeChartDescriptor() -> AXChartDescriptor {
        let start = chart.xDomain.lowerBound.timeIntervalSinceReferenceDate
        let end = max(chart.xDomain.upperBound.timeIntervalSinceReferenceDate, start + 1)
        let span = end - start
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: start...end,
            gridlinePositions: []
        ) { value in
            HeartSyncTheme.Chart.axisDescription(
                Date(timeIntervalSinceReferenceDate: value),
                span: span
            )
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: "\(kind.title) (\(kind.unit))",
            range: chart.yDomain,
            gridlinePositions: []
        ) { value in
            kind.formatWithUnit(value)
        }

        let byDevice = Dictionary(grouping: chart.points, by: \.sourceID)
        let dataSeries = series.compactMap { device -> AXDataSeriesDescriptor? in
            guard let points = byDevice[device.sourceID], !points.isEmpty else { return nil }
            return AXDataSeriesDescriptor(
                name: device.label,
                isContinuous: true,
                dataPoints: points.sorted { $0.date < $1.date }.map { point in
                    var caveats: [String] = []
                    if point.isEstimate { caveats.append("estimate") }
                    if point.isCompacted { caveats.append("compacted") }
                    return AXDataPoint(
                        x: point.date.timeIntervalSinceReferenceDate,
                        y: point.value,
                        additionalValues: [],
                        label: caveats.isEmpty ? nil : caveats.joined(separator: ", ")
                    )
                }
            )
        }

        return AXChartDescriptor(
            title: "\(kind.title) by device",
            summary: "Window medians per device. Gaps are periods with no data.",
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: dataSeries
        )
    }
}

/// The Audio Graph for Oura's heart rate: one series, the cached samples as drawn.
struct OuraHeartRateAudioGraph: AXChartDescriptorRepresentable {
    let points: [(date: Date, bpm: Double)]

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = points.map { $0.date.timeIntervalSinceReferenceDate }
        let start = dates.min() ?? 0
        let end = max(dates.max() ?? 1, start + 1)
        let values = points.map(\.bpm)
        let low = values.min() ?? 0
        let high = max(values.max() ?? 1, low + 1)
        return AXChartDescriptor(
            title: "Oura heart rate",
            summary: "Heart rate from the Oura Cloud cache. Gaps are periods the ring did not upload.",
            xAxis: AXNumericDataAxisDescriptor(title: "Time", range: start...end, gridlinePositions: []) { value in
                Date(timeIntervalSinceReferenceDate: value).formatted(date: .omitted, time: .shortened)
            },
            yAxis: AXNumericDataAxisDescriptor(title: "Heart rate (bpm)", range: low...high, gridlinePositions: []) { value in
                "\(Int(value.rounded())) bpm"
            },
            additionalAxes: [],
            series: [
                AXDataSeriesDescriptor(
                    name: "Oura",
                    isContinuous: true,
                    dataPoints: points.map { AXDataPoint(x: $0.date.timeIntervalSinceReferenceDate, y: $0.bpm) }
                ),
            ]
        )
    }
}
