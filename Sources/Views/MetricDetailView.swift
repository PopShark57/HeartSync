import Charts
import SwiftUI

/// Full history of one metric with every source overlaid, plus the pairwise agreement
/// statistics for that metric.
struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    var kind: MetricKind
    var initialRange: TimeRange = .day

    @State private var range: TimeRange = .day
    @State private var showEstimates = true

    var body: some View {
        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            Section {
                if points.isEmpty {
                    Text("No \(kind.title.lowercased()) data in this range.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                } else {
                    chart
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 12))
                    legend
                }
            } header: {
                Text(kind.title)
            } footer: {
                if !bandPoints.isEmpty {
                    Text("The shaded band spans the highest and lowest device reading in each \(bucketDescription) window. A wide band means your devices disagree at that moment.")
                }
            }

            if !perSourceStats.isEmpty {
                Section("Per device, \(range.title.lowercased())") {
                    ForEach(perSourceStats, id: \.source.id) { entry in
                        PerSourceStatsRow(kind: kind, entry: entry)
                    }
                }
            }

            let pairs = pairwiseAnalyses
            if !pairs.isEmpty {
                Section {
                    ForEach(pairs) { analysis in
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

            if kind == .hrvRMSSD || kind == .hrvSDNN {
                Section {
                    Text("HRV is the metric where devices disagree most. Vendors use different window lengths, different artefact-rejection rules, and different sensors \u{2014} an ECG chest strap and an optical ring are not measuring the same signal. Treat each device's HRV as its own scale and watch its trend, rather than expecting two devices to match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { range = initialRange }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(bandPoints) { band in
                AreaMark(
                    x: .value("Time", band.date),
                    yStart: .value("Low", band.low),
                    yEnd: .value("High", band.high)
                )
                .foregroundStyle(band.severity.tint.opacity(0.16))
                .interpolationMethod(.monotone)
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(kind.title, point.value),
                    series: .value("Source", point.sourceName)
                )
                .foregroundStyle(by: .value("Source", point.sourceName))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: point.isEstimate ? [4, 3] : []))
                .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale(domain: styleDomain, range: styleRange)
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
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

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(sourcesInRange, id: \.id) { source in
                HStack(spacing: 5) {
                    SourceDot(color: source.color, size: 8)
                    Text(source.displayName)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Data shaping

    private struct ChartPoint: Identifiable {
        var id: String
        var date: Date
        var value: Double
        var sourceName: String
        var isEstimate: Bool
    }

    private struct BandPoint: Identifiable {
        var id: String
        var date: Date
        var low: Double
        var high: Double
        var severity: DiscrepancySeverity
    }

    /// Windows re-bucketed at the chart's zoom level rather than the metric's comparison
    /// window, so a month of data does not try to render 43,000 points.
    private var chartWindows: [ComparisonWindow] {
        ComparisonEngine.windows(
            from: model.store.readings(kind: kind, in: range.interval),
            kind: kind,
            windowSize: max(kind.comparisonWindow, range.chartBucket),
            range: range.interval,
            includeEstimated: showEstimates
        )
    }

    private var points: [ChartPoint] {
        chartWindows.flatMap { window in
            window.values.map { value in
                ChartPoint(
                    id: "\(value.sourceID)-\(window.start.timeIntervalSince1970)",
                    date: window.start,
                    value: value.value,
                    sourceName: model.store.displayName(forSource: value.sourceID),
                    isEstimate: value.provenance == .estimated
                )
            }
        }
    }

    private var bandPoints: [BandPoint] {
        chartWindows.compactMap { window in
            guard window.values.count >= 2,
                  let low = window.minimum, let high = window.maximum
            else { return nil }
            return BandPoint(
                id: window.id,
                date: window.start,
                low: low.value,
                high: high.value,
                severity: window.severity
            )
        }
    }

    private var sourcesInRange: [DataSource] {
        let ids = Set(chartWindows.flatMap { $0.values.map(\.sourceID) })
        return ids.compactMap { model.store.source(id: $0) }.sorted { $0.displayName < $1.displayName }
    }

    private var styleDomain: [String] { sourcesInRange.map(\.displayName) }
    private var styleRange: [Color] { sourcesInRange.map(\.color) }

    /// Pads the observed range slightly so lines are not flush against the plot edges,
    /// and never collapses to zero height when every reading is identical.
    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let low = values.min(), let high = values.max() else { return kind.displayRange }
        let padding = max((high - low) * 0.15, kind.agreement.warn)
        return (low - padding)...(high + padding)
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .hour, .sixHours: .dateTime.hour().minute()
        case .day:             .dateTime.hour()
        case .week, .month:    .dateTime.month(.abbreviated).day()
        }
    }

    private var bucketDescription: String {
        let seconds = max(kind.comparisonWindow, range.chartBucket)
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))-hour" }
        return "\(Int(seconds / 60))-minute"
    }

    // MARK: Per-source stats

    struct SourceStats {
        var source: DataSource
        var mean: Double
        var minimum: Double
        var maximum: Double
        var sampleCount: Int
        var lastSeen: Date?
    }

    private var perSourceStats: [SourceStats] {
        let readings = model.store.readings(kind: kind, in: range.interval)
        let grouped = Dictionary(grouping: readings, by: \.sourceID)
        return grouped.compactMap { sourceID, samples -> SourceStats? in
            guard let source = model.store.source(id: sourceID), !samples.isEmpty else { return nil }
            let values = samples.map(\.value)
            return SourceStats(
                source: source,
                mean: values.reduce(0, +) / Double(values.count),
                minimum: values.min() ?? 0,
                maximum: values.max() ?? 0,
                sampleCount: samples.count,
                lastSeen: samples.map(\.end).max()
            )
        }
        .sorted { $0.source.displayName < $1.source.displayName }
    }

    /// Alert preferences do not filter analytical detail: agreeing and
    /// insufficient-evidence pairs remain inspectable here.
    private var pairwiseAnalyses: [PairwiseAnalysis] {
        let interval = range.interval
        return ComparisonEngine.allPairwiseAnalyses(
            from: model.store.readings(kind: kind, in: interval),
            kind: kind,
            range: interval
        )
    }
}

private struct PerSourceStatsRow: View {
    var kind: MetricKind
    var entry: MetricDetailView.SourceStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SourceDot(color: entry.source.color)
                Text(entry.source.displayName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(kind.formatWithUnit(entry.mean))
                    .font(.subheadline.monospacedDigit())
            }
            HStack(spacing: 14) {
                statistic("Low", kind.format(entry.minimum))
                statistic("High", kind.format(entry.maximum))
                statistic("Samples", "\(entry.sampleCount)")
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }

    private func statistic(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }
}

/// One navigable pair, with an evidence state that cannot be mistaken for agreement.
private struct PairwiseAnalysisRow: View {
    @Environment(AppModel.self) private var model
    var analysis: PairwiseAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SourceDot(color: model.store.source(id: analysis.sourceA)?.color ?? .gray, size: 8)
                Text("A  \(model.store.displayName(forSource: analysis.sourceA))")
                    .font(.caption.weight(.medium))
                Text("vs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                SourceDot(color: model.store.source(id: analysis.sourceB)?.color ?? .gray, size: 8)
                Text("B  \(model.store.displayName(forSource: analysis.sourceB))")
                    .font(.caption.weight(.medium))
                Spacer()
            }

            stateDetail
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch analysis.state {
        case .noOverlap:
            Label("No overlapping windows · no conclusion", systemImage: "rectangle.on.rectangle.slash")
                .foregroundStyle(.secondary)
                .font(.caption)

        case let .collecting(pairedWindowCount, requiredWindowCount):
            Label(
                "\(pairedWindowCount) of \(requiredWindowCount) paired windows · collecting evidence",
                systemImage: "hourglass"
            )
            .foregroundStyle(.orange)
            .font(.caption)

        case let .ready(statistics):
            VStack(alignment: .leading, spacing: 5) {
                Label("Ready · \(statistics.severity.title)", systemImage: statistics.severity.systemImage)
                    .foregroundStyle(statistics.severity.tint)
                    .font(.caption.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { readyMetrics(statistics) }
                    VStack(alignment: .leading, spacing: 5) { readyMetrics(statistics) }
                }
            }
        }
    }

    @ViewBuilder
    private func readyMetrics(_ statistics: PairwiseSummaryStatistics) -> some View {
        metric("Mean bias A − B", signed(statistics.meanBias))
        metric("Mean absolute gap", analysis.kind.format(statistics.meanAbsoluteDifference))
        metric(
            "95% limits",
            "\(signed(statistics.limitsOfAgreement.lowerBound)) to \(signed(statistics.limitsOfAgreement.upperBound))"
        )
    }

    private func signed(_ value: Double) -> String {
        let formatted = analysis.kind.format(abs(value))
        return value >= 0 ? "+\(formatted)" : "\u{2212}\(formatted)"
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
        }
    }
}
