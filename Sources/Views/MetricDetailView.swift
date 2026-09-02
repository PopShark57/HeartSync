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

// MARK: - Snapshot

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

private struct SourceStats: Identifiable {
    var source: DataSource
    var mean: Double
    var minimum: Double
    var maximum: Double
    var sampleCount: Int
    var lastSeen: Date?

    var id: String { source.id }
}

/// One Bluetooth device's own verdict on the beats behind its latest HRV window.
private struct HRVQualityEntry: Identifiable {
    var source: DataSource
    var quality: HRVQuality
    /// Heart rate the same device reported closest to the HRV window, when it reported one
    /// near enough to be a fair cross-check. Nil means no cross-check is possible, which is
    /// not the same as the device agreeing with itself.
    var reportedHeartRate: Double?

    var id: String { source.id }
}

/// One resolved pass over the store for one metric and range.
///
/// Every projection this screen draws comes from the same read and the same windowing, so
/// the chart, the band, the legend, the per-device table and the pair list cannot describe
/// slightly different spans of time, and drawing the screen costs one pass rather than ten.
@MainActor
private struct MetricDetailSnapshot {
    /// Chart bucket actually used, which is the metric's comparison window widened to the
    /// zoom level so a month does not try to render 43,000 points.
    let bucketSize: TimeInterval
    let points: [ChartPoint]
    let bandPoints: [BandPoint]
    let sourcesInRange: [DataSource]
    let styleDomain: [String]
    let styleRange: [Color]
    let yDomain: ClosedRange<Double>
    let perSourceStats: [SourceStats]
    let pairwiseAnalyses: [PairwiseAnalysis]
    /// Whether the range holds any modelled value at all, so the estimate switch is only
    /// offered where it does something.
    let hasEstimatedReadings: Bool
    let hrvQuality: [HRVQualityEntry]

    /// How far from an HRV window a heart-rate reading may sit and still be treated as the
    /// same moment: half of the 300-second HRV comparison window.
    private static let crossCheckTolerance: TimeInterval = 150

    init(
        store: HealthStore,
        kind: MetricKind,
        range: TimeRange,
        includeEstimates: Bool,
        hrvQuality: [UUID: HRVQuality]
    ) {
        let interval = range.interval
        let readings = store.readings(kind: kind, in: interval)
        self.hasEstimatedReadings = readings.contains { $0.provenance == .estimated }

        let bucketSize = max(kind.comparisonWindow, range.chartBucket)
        self.bucketSize = bucketSize
        let windows = ComparisonEngine.windows(
            from: readings,
            kind: kind,
            windowSize: bucketSize,
            range: interval,
            includeEstimated: includeEstimates
        )

        let sources = Set(windows.flatMap { $0.values.map(\.sourceID) })
            .compactMap { store.source(id: $0) }
            .sorted { $0.displayName < $1.displayName }
        self.sourcesInRange = sources
        self.styleDomain = sources.map(\.displayName)
        self.styleRange = sources.map(\.color)
        var names: [String: String] = [:]
        for source in sources { names[source.id] = source.displayName }

        self.points = windows.flatMap { window in
            window.values.map { value in
                ChartPoint(
                    id: "\(value.sourceID)-\(window.start.timeIntervalSince1970)",
                    date: window.start,
                    value: value.value,
                    sourceName: names[value.sourceID] ?? store.displayName(forSource: value.sourceID),
                    isEstimate: value.provenance == .estimated
                )
            }
        }

        // The band is a disagreement verdict drawn on a chart, so it is built from measured
        // and derived values only. Showing estimates must never widen it or change its
        // colour: the switch above is presentation, and an estimate is not a device.
        self.bandPoints = windows.compactMap { window in
            let comparable = window.values.filter { $0.provenance != .estimated }
            guard comparable.count >= 2,
                  let low = comparable.min(by: { $0.value < $1.value }),
                  let high = comparable.max(by: { $0.value < $1.value })
            else { return nil }
            return BandPoint(
                id: window.id,
                date: window.start,
                low: low.value,
                high: high.value,
                severity: kind.agreement.severity(forDelta: high.value - low.value)
            )
        }

        // Pads the observed range slightly so lines are not flush against the plot edges,
        // and never collapses to zero height when every reading is identical.
        let plotted = self.points.map(\.value)
        if let low = plotted.min(), let high = plotted.max() {
            let padding = max((high - low) * 0.15, kind.agreement.warn)
            self.yDomain = (low - padding)...(high + padding)
        } else {
            self.yDomain = kind.displayRange
        }

        // The estimate switch is presentation, so it filters this descriptive table too.
        let statsReadings = includeEstimates
            ? readings
            : readings.filter { $0.provenance != .estimated }
        self.perSourceStats = Dictionary(grouping: statsReadings, by: \.sourceID)
            .compactMap { sourceID, samples -> SourceStats? in
                guard let source = store.source(id: sourceID), !samples.isEmpty else { return nil }
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

        // Alert preferences do not filter analytical detail: agreeing and
        // insufficient-evidence pairs remain inspectable here. Estimates are excluded by
        // the engine's own default, so `includeEstimates` cannot reach a verdict.
        self.pairwiseAnalyses = ComparisonEngine.allPairwiseAnalyses(
            from: readings,
            kind: kind,
            range: interval
        )

        self.hrvQuality = Self.qualityEntries(
            store: store,
            sources: sources,
            quality: hrvQuality,
            range: interval
        )
    }

    /// Pairs each Bluetooth source with its latest HRV window quality and the heart rate it
    /// reported at the same moment.
    ///
    /// Only sources whose window falls inside the selected range are returned, so the
    /// caveat always describes data the user can see. The heart rates come from one bounded
    /// read spanning the candidate windows rather than a query per device.
    private static func qualityEntries(
        store: HealthStore,
        sources: [DataSource],
        quality: [UUID: HRVQuality],
        range: DateInterval
    ) -> [HRVQualityEntry] {
        guard !quality.isEmpty else { return [] }
        let candidates: [(source: DataSource, quality: HRVQuality)] = sources.compactMap { source in
            guard source.transport == .bluetooth,
                  let uuid = UUID(uuidString: source.id),
                  let measured = quality[uuid],
                  range.contains(measured.measuredAt)
            else { return nil }
            return (source, measured)
        }
        guard let earliest = candidates.map({ $0.quality.measuredAt }).min(),
              let latest = candidates.map({ $0.quality.measuredAt }).max()
        else { return [] }

        let heartRates = store.readings(
            kind: .heartRate,
            in: DateInterval(
                start: earliest.addingTimeInterval(-crossCheckTolerance),
                end: latest.addingTimeInterval(crossCheckTolerance)
            )
        )
        let bySource = Dictionary(grouping: heartRates, by: \.sourceID)

        return candidates.map { candidate in
            let nearest = bySource[candidate.source.id]?
                .min { lhs, rhs in
                    abs(lhs.end.timeIntervalSince(candidate.quality.measuredAt))
                        < abs(rhs.end.timeIntervalSince(candidate.quality.measuredAt))
                }
            let reported = nearest.flatMap { reading -> Double? in
                abs(reading.end.timeIntervalSince(candidate.quality.measuredAt)) <= crossCheckTolerance
                    ? reading.value
                    : nil
            }
            return HRVQualityEntry(
                source: candidate.source,
                quality: candidate.quality,
                reportedHeartRate: reported
            )
        }
        .sorted { $0.source.displayName < $1.source.displayName }
    }
}

// MARK: - Rows

private struct PerSourceStatsRow: View {
    var kind: MetricKind
    var entry: SourceStats

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.source.displayName), mean \(kind.formatWithUnit(entry.mean)), low \(kind.format(entry.minimum)), high \(kind.format(entry.maximum)), \(entry.sampleCount) samples")
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

/// Beat-level caveat for one device's latest HRV window.
///
/// Two things a comparison cannot say on its own: how much of the window was thrown away as
/// artefact, and whether the device agrees with *itself* \u{2014} the heart rate implied by the
/// R\u{2013}R intervals it sent versus the heart rate it reported over the same seconds. Neither
/// is a claim about which device is correct.
///
/// A published window has already passed `HRVMetrics.isReliable`, so the artefact figure
/// says how close to that limit this window ran rather than announcing a rejected one. The
/// over-limit wording is kept for the case where a window reaches this row without having
/// gone through `HRVAccumulator.emitIfReady`.
private struct HRVQualityRow: View {
    var entry: HRVQualityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SourceDot(color: entry.source.color, size: 8)
                Text(entry.source.displayName)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(entry.quality.measuredAt, format: .relative(presentation: .numeric))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(beatQualityText)
                .font(.caption)
                .foregroundStyle(isNoisy ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(crossCheckText)
                .font(.caption)
                .foregroundStyle(crossCheckTint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Above the calculator's own rejection ceiling the HRV figure is not trustworthy
    /// whatever it says, which is exactly the caveat an HRV comparison needs.
    private var isNoisy: Bool {
        entry.quality.artefactFraction > HRVMetrics.maximumArtefactFraction
    }

    /// `artefactFraction` is a 0...1 fraction; `pnn50` is already a percentage, as
    /// `HRVMetrics` documents. They are converted at the call site rather than guessed at.
    private var beatQualityText: String {
        let rejected = percentText(entry.quality.artefactFraction * 100)
        let pnn50 = percentText(entry.quality.pnn50)
        let base = "This HRV window rejected \(rejected) of beats and kept \(entry.quality.beatCount). pNN50 \(pnn50)."
        guard isNoisy else { return base }
        return base + " That is above HeartSync's \(percentText(HRVMetrics.maximumArtefactFraction * 100)) artefact limit, so read this window's HRV with caution."
    }

    private var crossCheckText: String {
        let implied = MetricKind.heartRate.formatWithUnit(entry.quality.impliedHeartRate)
        guard let reported = entry.reportedHeartRate else {
            return "Its R\u{2013}R intervals imply \(implied). This device reported no heart rate close enough to the window to cross-check that."
        }
        let difference = entry.quality.impliedHeartRate - reported
        let base = "Its R\u{2013}R intervals imply \(implied) while the same device reported \(MetricKind.heartRate.formatWithUnit(reported))."
        guard crossCheckSeverity != .agreeing else { return base }
        return base + " A device that disagrees with itself by \(MetricKind.heartRate.formatWithUnit(abs(difference))) is describing its own beat detection, not another device."
    }

    private var crossCheckSeverity: DiscrepancySeverity {
        guard let reported = entry.reportedHeartRate else { return .agreeing }
        return MetricKind.heartRate.agreement
            .severity(forDelta: entry.quality.impliedHeartRate - reported)
    }

    private var crossCheckTint: Color {
        crossCheckSeverity == .agreeing ? .secondary : crossCheckSeverity.tint
    }

    private func percentText(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(0))) + "%"
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
