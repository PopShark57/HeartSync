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
    /// Bumped by the retry button so the load key changes and the query runs again.
    @State private var retryToken = 0
    @State private var snapshot: MetricDetailSnapshot?

    /// Everything the snapshot depends on. An unrelated view update leaves this unchanged
    /// and reuses the resolved snapshot instead of re-reading and re-windowing the range.
    private struct LoadKey: Hashable {
        var generation: Int
        var kind: MetricKind
        var range: TimeRange
        var showEstimates: Bool
        var hrvQualityCount: Int
        var retryToken: Int
    }

    private var loadKey: LoadKey {
        LoadKey(
            generation: model.store.changeToken,
            kind: kind,
            range: range,
            showEstimates: showEstimates,
            hrvQualityCount: isHRV ? model.bluetooth.hrvQuality.count : 0,
            retryToken: retryToken
        )
    }

    var body: some View {
        // Resolved off the render path, once per load key. The chart, the band, the
        // legend, the per-device table, and the pair list are five projections of one
        // windowing pass; computing them separately re-read the whole archive and
        // re-bucketed it for each projection, and `TimeRange.interval` is relative to
        // `.now`, so those passes did not even describe the same span. Building it inside
        // `body` also meant every unrelated update paid for the whole pass again.
        Group {
            if let snapshot {
                content(snapshot)
            } else {
                List {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading \(kind.title.lowercased())\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("metric.loading")
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { range = initialRange }
        // Cancels a superseded load and rejects a late one, so a slow month-range result
        // cannot replace a newer hour-range selection.
        .task(id: loadKey) {
            let key = loadKey
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            let resolved = MetricDetailSnapshot(
                store: model.store,
                kind: kind,
                range: range,
                includeEstimates: showEstimates,
                hrvQuality: isHRV ? model.bluetooth.hrvQuality : [:]
            )
            guard !Task.isCancelled, key == loadKey else { return }
            snapshot = resolved
        }
    }

    @ViewBuilder
    private func content(_ snapshot: MetricDetailSnapshot) -> some View {
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
                if let failure = snapshot.queryFailure {
                    // A failed read is not an empty range. Saying "no data" here would be a
                    // claim about the user's history that this screen cannot support.
                    HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                        .accessibilityIdentifier("metric.unavailable")
                } else if snapshot.points.isEmpty {
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
                Section {
                    ForEach(snapshot.perSourceStats) { entry in
                        PerSourceStatsRow(kind: kind, entry: entry)
                    }
                } header: {
                    Text("Per device, \(range.title.lowercased())")
                } footer: {
                    Text("These summarise one median per device per \(WindowLabel.length(snapshot.bucketSize)) window \u{2014} the same windows the chart draws. They are not raw sample statistics: readings older than the compaction age are stored as one median per window, so the original minimum, maximum and mean no longer exist. Where the original sample count was recorded it is shown separately; where it was not, it is shown as unknown.")
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

            // Every mark keys on `sourceID`, never on the display name. Two devices called
            // "Polar H10" are two series; renaming one is a label change, not a data move.
            ForEach(snapshot.points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value),
                    // Segment key, not source key: the line breaks across a gap in this
                    // source's data rather than implying continuous measurement.
                    series: .value("Source", point.seriesKey)
                )
                .foregroundStyle(by: .value("Source", point.sourceID))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: point.isEstimate ? [4, 3] : []))
                .interpolationMethod(.monotone)

                // Dots keep single-sample series visible; LineMark alone draws nothing for one point.
                PointMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value)
                )
                .foregroundStyle(by: .value("Source", point.sourceID))
                .symbol(by: .value("Source", point.sourceID))
                .symbolSize(36)
            }
        }
        .chartForegroundStyleScale(domain: snapshot.styleDomain, range: snapshot.styleRange)
        .chartSymbolScale(domain: snapshot.styleDomain, range: snapshot.symbolRange)
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

    /// Legend entries come from the same `series` the chart scales use, so a label here can
    /// never name a different device than the line it points at. The symbol is spoken as
    /// well as drawn: a legend that only differs by colour is unusable to a reader who
    /// cannot distinguish the two colours.
    private func legend(_ snapshot: MetricDetailSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendEntries(snapshot) }
            VStack(alignment: .leading, spacing: 5) { legendEntries(snapshot) }
        }
    }

    @ViewBuilder
    private func legendEntries(_ snapshot: MetricDetailSnapshot) -> some View {
        ForEach(snapshot.series) { entry in
            HStack(spacing: 5) {
                SourceDot(color: entry.color, size: 8)
                Text(entry.label)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(entry.label), \(entry.symbol.accessibilityName) marks")
        }
        Spacer(minLength: 0)
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .hour, .sixHours: .dateTime.hour().minute()
        case .day:             .dateTime.hour()
        case .week, .month:    .dateTime.month(.abbreviated).day()
        }
    }
}
