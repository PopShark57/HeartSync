import Charts
import SwiftUI

/// Full history of one metric with every source overlaid, plus the pairwise agreement
/// statistics for that metric.
struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    var kind: MetricKind
    var initialRange: TimeRange = .day

    @State private var range: TimeRange = .day
    /// Presentation only. Estimated values are drawn as dashed lines when this is on; they
    /// are never fed into a comparison verdict either way \u{2014} see `MetricDetailSnapshot`.
    @State private var showEstimates = true

    var body: some View {
        // Resolved once per update and threaded through every section. The chart, the
        // band, the legend, the per-device table, and the pair list are five projections
        // of one windowing pass; computing them separately re-read the whole archive and
        // re-bucketed it for each projection, and `TimeRange.interval` is relative to
        // `.now`, so those passes did not even describe the same span.
        let snapshot = MetricDetailSnapshot(
            store: model.store,
            kind: kind,
            range: range,
            includeEstimates: showEstimates,
            hrvQuality: isHRV ? model.bluetooth.hrvQuality : [:]
        )

        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

                if snapshot.hasEstimatedReadings {
                    Toggle("Show estimated values", isOn: $showEstimates)
                        .font(.subheadline)
                }
            } footer: {
                if snapshot.hasEstimatedReadings {
                    Text("Estimated values are modelled, not measured, and are drawn as dashed lines. This switch changes the chart and the per-device table only: an estimate never contributes to a device agreement statistic, whichever way it is set.")
                }
            }

            Section {
                if snapshot.points.isEmpty {
                    Text("No \(kind.title.lowercased()) data in this range.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                } else {
                    chart(snapshot)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 12))
                    legend(snapshot)
                }
            } header: {
                Text(kind.title)
            } footer: {
                if !snapshot.bandPoints.isEmpty {
                    Text("The shaded band spans the highest and lowest device reading in each \(WindowLabel.length(snapshot.bucketSize)) window. A wide band means your devices disagree at that moment.")
                }
            }

            if !snapshot.perSourceStats.isEmpty {
                Section("Per device, \(range.title.lowercased())") {
                    ForEach(snapshot.perSourceStats) { entry in
                        PerSourceStatsRow(kind: kind, entry: entry)
                    }
                }
            }

            if !snapshot.pairwiseAnalyses.isEmpty {
                Section {
                    ForEach(snapshot.pairwiseAnalyses) { analysis in
                        NavigationLink {
                            PairwiseAnalysisView(
                                kind: kind,
                                sourceAID: analysis.sourceA,
                                sourceBID: analysis.sourceB,
                                initialRange: range
                            )
                        } label: {
                            PairwiseAnalysisRow(analysis: analysis)
                        }
                    }
                } header: {
                    Text("Device pairs")
                } footer: {
                    Text("Every eligible pair is listed, including pairs with no overlap or too few paired windows. Open a pair for its timeline, difference plot, evidence, and export.")
                }
            }

            if isHRV {
                Section {
                    Text("HRV is the metric where devices disagree most. Vendors use different window lengths, different artefact-rejection rules, and different sensors \u{2014} an ECG chest strap and an optical ring are not measuring the same signal. Treat each device's HRV as its own scale and watch its trend, rather than expecting two devices to match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(snapshot.hrvQuality) { entry in
                        HRVQualityRow(entry: entry)
                    }
                } header: {
                    if !snapshot.hrvQuality.isEmpty {
                        Text("How good is this HRV?")
                    }
                } footer: {
                    if !snapshot.hrvQuality.isEmpty {
                        Text("Beat quality is reported by HeartSync's own HRV calculation from the R\u{2013}R intervals a Bluetooth device sent, and describes that device's latest window only. It is a caveat on the numbers above, not a comparison between devices.")
                    }
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { range = initialRange }
    }

    private var isHRV: Bool { kind == .hrvRMSSD || kind == .hrvSDNN }

    // MARK: Chart

    private func chart(_ snapshot: MetricDetailSnapshot) -> some View {
        Chart {
            ForEach(snapshot.bandPoints) { band in
                AreaMark(
                    x: .value("Time", band.date),
                    yStart: .value("Low", band.low),
                    yEnd: .value("High", band.high)
                )
                .foregroundStyle(band.severity.tint.opacity(0.16))
                .interpolationMethod(.monotone)
            }

            ForEach(snapshot.points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value),
                    series: .value("Source", point.sourceName)
                )
                .foregroundStyle(by: .value("Source", point.sourceName))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: point.isEstimate ? [4, 3] : []))
                .interpolationMethod(.monotone)

                // Dots keep single-sample series visible; LineMark alone draws nothing for one point.
                PointMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value)
                )
                .foregroundStyle(by: .value("Source", point.sourceName))
                .symbolSize(36)
            }
        }
        .chartForegroundStyleScale(domain: snapshot.styleDomain, range: snapshot.styleRange)
        .chartLegend(.hidden)
        .chartYScale(domain: snapshot.yDomain)
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    private func legend(_ snapshot: MetricDetailSnapshot) -> some View {
        HStack(spacing: 14) {
            ForEach(snapshot.sourcesInRange, id: \.id) { source in
                HStack(spacing: 5) {
                    SourceDot(color: source.color, size: 8)
                    Text(source.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(source.displayName)
            }
            Spacer(minLength: 0)
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .hour, .sixHours: .dateTime.hour().minute()
        case .day:             .dateTime.hour()
        case .week, .month:    .dateTime.month(.abbreviated).day()
        }
    }
}
