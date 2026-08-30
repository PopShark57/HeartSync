import Charts
import Foundation
import SwiftUI
import UIKit

/// Focused evidence for one metric and one canonically ordered source pair.
///
/// `sourceA` and `sourceB` come from `PairwiseAnalysis`, so every signed value on this
/// screen has one stable meaning: A minus B.
struct PairwiseAnalysisView: View {
    @Environment(AppModel.self) private var model

    let kind: MetricKind
    let sourceAID: String
    let sourceBID: String

    @State private var range: TimeRange
    @State private var selectedObservationStart: Date?
    @State private var sharePayload: PairwiseSharePayload?
    @State private var shareDirectory: URL?
    @State private var exportError: String?

    init(
        kind: MetricKind,
        sourceAID: String,
        sourceBID: String,
        initialRange: TimeRange = .day
    ) {
        self.kind = kind
        self.sourceAID = min(sourceAID, sourceBID)
        self.sourceBID = max(sourceAID, sourceBID)
        _range = State(initialValue: initialRange)
    }

    var body: some View {
        let currentAnalysis = analysis
        let points = plotted(currentAnalysis)

        List {
            Section {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            Section {
                sourceOrder
                evidenceCard(currentAnalysis)
            } header: {
                Text("Evidence")
            } footer: {
                Text("A signed difference is always Device A minus Device B. Estimates are excluded, and raw samples are reduced to one median per aligned window.")
            }

            if currentAnalysis.observations.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "rectangle.on.rectangle.slash",
                        title: "No overlapping windows",
                        message: "These devices never reported inside the same aligned \(windowDescription(currentAnalysis.windowSize)) window in this range. Widen the range, or wear both devices at the same time."
                    )
                }
            } else {
                Section {
                    pairedTimeline(currentAnalysis, points: points)
                        .frame(height: 250)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 12))
                    deviceLegend
                } header: {
                    Text("Paired values")
                } footer: {
                    Text("Each line connects the per-window medians for one device. Drag across the chart to inspect the nearest paired window.\(thinningNote(currentAnalysis, points: points))")
                }

                Section {
                    blandAltmanChart(currentAnalysis, points: points)
                        .frame(height: 280)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 12))
                    differenceLegend
                } header: {
                    Text("Difference versus paired mean")
                } footer: {
                    Text("The horizontal position is the mean of the two device values. The vertical position is A minus B. Limits of agreement describe these observations; they are not inferential confidence intervals.")
                }

                if let selected = selectedObservation(in: points) {
                    Section("Selected paired window") {
                        selectedObservationCard(selected, analysis: currentAnalysis)
                    }
                }
            }

            Section("Interpretation") {
                Label {
                    Text(interpretation(for: currentAnalysis))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: statePresentation(currentAnalysis).systemImage)
                        .foregroundStyle(statePresentation(currentAnalysis).tint)
                }
            }

            if !currentAnalysis.observations.isEmpty {
                Section {
                    Button(action: { prepareExport(currentAnalysis) }) {
                        Label("Export observations and summary", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityHint("Creates a CSV and plain-text methodology summary, then opens the share sheet")
                } footer: {
                    Text("The export contains only this metric, source pair, and selected range. When evidence is insufficient, the summary explicitly withholds an agreement conclusion.")
                }
            }

            Section {
                Text("HeartSync compares consumer-device measurements and does not establish medical accuracy. Neither device is treated as a reference standard, and this analysis does not determine which device is correct.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: range) {
            selectedObservationStart = nil
        }
        .sheet(item: $sharePayload, onDismiss: discardShareFiles) { payload in
            PairwiseActivityView(items: payload.urls)
                .ignoresSafeArea()
        }
        .alert(
            "Export unavailable",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The export could not be prepared.")
        }
    }

    private var analysis: PairwiseAnalysis {
        let interval = range.interval
        return ComparisonEngine.pairwiseAnalysis(
            from: model.store.readings(kind: kind, in: interval),
            kind: kind,
            sourceA: sourceAID,
            sourceB: sourceBID,
            range: interval
        )
    }

    private var sourceA: DataSource? { model.store.source(id: sourceAID) }
    private var sourceB: DataSource? { model.store.source(id: sourceBID) }
    private var sourceAName: String { model.store.displayName(forSource: sourceAID) }
    private var sourceBName: String { model.store.displayName(forSource: sourceBID) }
    private var sourceAColor: Color { sourceA?.color ?? .blue }
    private var sourceBColor: Color { sourceB?.color ?? .orange }

    // MARK: - Evidence

    private var sourceOrder: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceIdentity(label: "Device A", source: sourceA, fallbackName: sourceAName, color: sourceAColor)

            HStack(spacing: 6) {
                Image(systemName: "minus")
                Text("signed difference")
                Image(systemName: "minus")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)

            sourceIdentity(label: "Device B", source: sourceB, fallbackName: sourceBName, color: sourceBColor)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Device A \(sourceAName), minus Device B \(sourceBName)")
    }

    private func sourceIdentity(
        label: String,
        source: DataSource?,
        fallbackName: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            SourceDot(color: color, size: 11)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(fallbackName)
                    .font(.subheadline.weight(.semibold))
                if let modelName = source?.model, !modelName.isEmpty {
                    Text(modelName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func evidenceCard(_ analysis: PairwiseAnalysis) -> some View {
        let presentation = statePresentation(analysis)

        return VStack(alignment: .leading, spacing: 12) {
            Label(presentation.title, systemImage: presentation.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(presentation.tint)

            LabeledContent("Overlap") {
                Text(analysis.overlapPercentage, format: .number.precision(.fractionLength(0)))
                    + Text("%")
            }
            LabeledContent("Aligned windows") {
                Text("\(analysis.pairedWindowCount) paired of \(analysis.candidateWindowCount) candidates")
            }
            LabeledContent("Raw samples") {
                Text("A \(analysis.rawSampleCountA)  ·  B \(analysis.rawSampleCountB)")
            }
            LabeledContent("Window size") {
                Text(windowDescription(analysis.windowSize))
            }
            if let span = analysis.analyzedSpan {
                LabeledContent("Analyzed span") {
                    Text(span.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                        + Text(" – ")
                        + Text(span.end, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
            }

            if let stats = analysis.statistics {
                Divider()
                LabeledContent("Mean bias (A − B)") { Text(signed(stats.meanBias, withUnit: true)) }
                LabeledContent("Mean absolute difference") { Text(kind.formatWithUnit(stats.meanAbsoluteDifference)) }
                LabeledContent("Difference SD") { Text(kind.formatWithUnit(stats.differenceSD)) }
                LabeledContent("95% limits") {
                    Text("\(signed(stats.limitsOfAgreement.lowerBound)) to \(signed(stats.limitsOfAgreement.upperBound)) \(kind.unit)")
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Charts

    private func pairedTimeline(
        _ analysis: PairwiseAnalysis,
        points: [PairwiseObservation]
    ) -> some View {
        Chart {
            ForEach(points, id: \.start) { observation in
                LineMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceA.value),
                    series: .value("Device", analysis.sourceA)
                )
                .foregroundStyle(sourceAColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceA.value)
                )
                .foregroundStyle(sourceAColor)
                .symbolSize(selectedObservationStart == observation.start ? 80 : 28)

                LineMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceB.value),
                    series: .value("Device", analysis.sourceB)
                )
                .foregroundStyle(sourceBColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceB.value)
                )
                .foregroundStyle(sourceBColor)
                .symbolSize(selectedObservationStart == observation.start ? 80 : 28)
            }

            if let selected = selectedObservation(in: points) {
                RuleMark(x: .value("Selected window", selected.start))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: timelineYDomain(points))
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartOverlay { proxy in timelineSelectionOverlay(proxy: proxy, points: points) }
        .accessibilityLabel("Paired value timeline for \(sourceAName) and \(sourceBName)")
        .accessibilityHint("Drag across the chart to select the nearest paired window")
    }

    private func blandAltmanChart(
        _ analysis: PairwiseAnalysis,
        points: [PairwiseObservation]
    ) -> some View {
        Chart {
            RuleMark(y: .value("Zero difference", 0))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1))

            toleranceRules(kind.agreement.warn, label: "Warning", color: .orange, dash: [6, 4])
            toleranceRules(kind.agreement.alert, label: "Major", color: .red, dash: [2, 4])

            if let stats = analysis.statistics {
                RuleMark(y: .value("Mean bias", stats.meanBias))
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                RuleMark(y: .value("Lower 95% limit", stats.limitsOfAgreement.lowerBound))
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [8, 4]))

                RuleMark(y: .value("Upper 95% limit", stats.limitsOfAgreement.upperBound))
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [8, 4]))
            }

            ForEach(points, id: \.start) { observation in
                PointMark(
                    x: .value("Paired mean", observation.pairedMean),
                    y: .value("A minus B", observation.signedDifference)
                )
                .foregroundStyle(differenceColor(observation, analysis: analysis))
                .symbolSize(differenceSymbolSize(observation, analysis: analysis))
            }

            if let selected = selectedObservation(in: points) {
                RuleMark(x: .value("Selected paired mean", selected.pairedMean))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: blandAltmanXDomain(points))
        .chartYScale(domain: blandAltmanYDomain(analysis, points: points))
        .chartXAxisLabel("Paired mean (\(kind.unit))")
        .chartYAxisLabel("A − B (\(kind.unit))")
        .chartXAxis { AxisMarks(preset: .aligned) }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartOverlay { proxy in differenceSelectionOverlay(proxy: proxy, points: points) }
        .accessibilityLabel("Bland Altman plot of Device A minus Device B")
        .accessibilityHint("Drag across the chart to select the observation with the nearest paired mean")
    }

    @ChartContentBuilder
    private func toleranceRules(
        _ tolerance: Double,
        label: String,
        color: Color,
        dash: [CGFloat]
    ) -> some ChartContent {
        RuleMark(y: .value("Positive \(label) tolerance", tolerance))
            .foregroundStyle(color.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: dash))
        RuleMark(y: .value("Negative \(label) tolerance", -tolerance))
            .foregroundStyle(color.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: dash))
    }

    private func timelineSelectionOverlay(
        proxy: ChartProxy,
        points: [PairwiseObservation]
    ) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let plotX = value.location.x - frame.origin.x
                            guard let date: Date = proxy.value(atX: plotX) else { return }
                            selectedObservationStart = points.min {
                                abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
                            }?.start
                        }
                )
        }
    }

    private func differenceSelectionOverlay(
        proxy: ChartProxy,
        points: [PairwiseObservation]
    ) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let plotX = value.location.x - frame.origin.x
                            guard let pairedMean: Double = proxy.value(atX: plotX) else { return }
                            selectedObservationStart = points.min {
                                abs($0.pairedMean - pairedMean) < abs($1.pairedMean - pairedMean)
                            }?.start
                        }
                )
        }
    }

    private var deviceLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                sourceLegend(name: "A  \(sourceAName)", color: sourceAColor)
                sourceLegend(name: "B  \(sourceBName)", color: sourceBColor)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                sourceLegend(name: "A  \(sourceAName)", color: sourceAColor)
                sourceLegend(name: "B  \(sourceBName)", color: sourceBColor)
            }
        }
    }

    private func sourceLegend(name: String, color: Color) -> some View {
        HStack(spacing: 6) {
            SourceDot(color: color, size: 8)
            Text(name).font(.caption2).lineLimit(1)
        }
    }

    private var differenceLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            legendRule(color: .blue, label: "Mean bias")
            legendRule(color: .purple, label: "95% limits of agreement", dashed: true)
            legendRule(color: .orange, label: "Warning tolerance", dashed: true)
            legendRule(color: .red, label: "Major tolerance", dashed: true)
            HStack(spacing: 6) {
                Circle().fill(.purple).frame(width: 7, height: 7)
                Text("Purple point: outside the observed 95% limits")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func legendRule(color: Color, label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 22, height: dashed ? 2 : 3)
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func selectedObservationCard(
        _ observation: PairwiseObservation,
        analysis: PairwiseAnalysis
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(observation.start, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                .font(.subheadline.weight(.semibold))

            LabeledContent("Device A · \(sourceAName)") {
                Text(kind.formatWithUnit(observation.sourceA.value))
            }
            LabeledContent("Device B · \(sourceBName)") {
                Text(kind.formatWithUnit(observation.sourceB.value))
            }
            LabeledContent("A − B") {
                Text(signed(observation.signedDifference, withUnit: true))
                    .foregroundStyle(observation.severity.tint)
            }
            LabeledContent("Paired mean") {
                Text(kind.formatWithUnit(observation.pairedMean))
            }
            LabeledContent("Raw contribution") {
                Text("A \(observation.sourceA.sampleCount)  ·  B \(observation.sourceB.sampleCount)")
            }
            LabeledContent("Within-window SD") {
                Text("A \(kind.format(observation.sourceA.standardDeviation))  ·  B \(kind.format(observation.sourceB.standardDeviation)) \(kind.unit)")
            }
            LabeledContent("Provenance") {
                Text("A \(observation.sourceA.provenance.title)  ·  B \(observation.sourceB.provenance.title)")
            }

            if outsideLimits(observation, analysis: analysis) {
                Label("Outside the observed 95% limits of agreement", systemImage: "circle.dashed.inset.filled")
                    .font(.caption)
                    .foregroundStyle(.purple)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func timelineYDomain(_ points: [PairwiseObservation]) -> ClosedRange<Double> {
        let values = points.flatMap { [$0.sourceA.value, $0.sourceB.value] }
        guard let low = values.min(), let high = values.max() else { return kind.displayRange }
        let padding = max((high - low) * 0.15, max(kind.agreement.warn * 0.2, 0.1))
        return (low - padding)...(high + padding)
    }

    private func blandAltmanXDomain(_ points: [PairwiseObservation]) -> ClosedRange<Double> {
        let values = points.map(\.pairedMean)
        guard let low = values.min(), let high = values.max() else { return kind.displayRange }
        let padding = max((high - low) * 0.15, max(kind.agreement.warn * 0.2, 0.1))
        return (low - padding)...(high + padding)
    }

    private func blandAltmanYDomain(
        _ analysis: PairwiseAnalysis,
        points: [PairwiseObservation]
    ) -> ClosedRange<Double> {
        var values = points.map(\.signedDifference)
        values += [0, kind.agreement.warn, -kind.agreement.warn, kind.agreement.alert, -kind.agreement.alert]
        if let limits = analysis.statistics?.limitsOfAgreement {
            values += [analysis.statistics?.meanBias ?? 0, limits.lowerBound, limits.upperBound]
        }
        let low = values.min() ?? -kind.agreement.alert
        let high = values.max() ?? kind.agreement.alert
        let padding = max((high - low) * 0.12, 0.1)
        return (low - padding)...(high + padding)
    }

    private func differenceColor(
        _ observation: PairwiseObservation,
        analysis: PairwiseAnalysis
    ) -> Color {
        if outsideLimits(observation, analysis: analysis) { return .purple }
        return observation.severity.tint
    }

    private func differenceSymbolSize(
        _ observation: PairwiseObservation,
        analysis: PairwiseAnalysis
    ) -> CGFloat {
        if selectedObservationStart == observation.start { return 115 }
        if outsideLimits(observation, analysis: analysis) || observation.severity != .agreeing { return 75 }
        return 42
    }

    private func outsideLimits(
        _ observation: PairwiseObservation,
        analysis: PairwiseAnalysis
    ) -> Bool {
        guard let limits = analysis.statistics?.limitsOfAgreement else { return false }
        return !limits.contains(observation.signedDifference)
    }

    private func selectedObservation(in points: [PairwiseObservation]) -> PairwiseObservation? {
        guard let selectedObservationStart else { return nil }
        return points.first { $0.start == selectedObservationStart }
    }

    // MARK: - Plot thinning

    /// Swift Charts emits one mark per observation per series, and a 30-day range of a
    /// 60-second metric can pair tens of thousands of windows. Statistics, the evidence
    /// card, and the export always use every paired window; only the drawn set is thinned.
    private static let maximumPlottedObservations = 500

    /// Extra points kept regardless of the even sampling, so thinning cannot hide the
    /// outliers a Bland–Altman plot exists to show.
    private static let maximumPlottedExtremes = 60

    private func plotted(_ analysis: PairwiseAnalysis) -> [PairwiseObservation] {
        analysis.plotSample(
            limit: Self.maximumPlottedObservations,
            extremes: Self.maximumPlottedExtremes
        )
    }

    /// Says so when the chart is not showing every paired window. Silently drawing a
    /// subset would misrepresent how much evidence the analysis actually rests on.
    private func thinningNote(
        _ analysis: PairwiseAnalysis,
        points: [PairwiseObservation]
    ) -> String {
        guard points.count < analysis.observations.count else { return "" }
        return " Showing \(points.count) of \(analysis.observations.count) paired windows for legibility, including the widest differences; every window is used for the statistics and the export."
    }

    // MARK: - Interpretation

    private struct StatePresentation {
        var title: String
        var systemImage: String
        var tint: Color
    }

    private func statePresentation(_ analysis: PairwiseAnalysis) -> StatePresentation {
        switch analysis.state {
        case .noOverlap:
            StatePresentation(
                title: "No overlapping windows",
                systemImage: "rectangle.on.rectangle.slash",
                tint: .secondary
            )
        case let .collecting(pairedWindowCount, requiredWindowCount):
            StatePresentation(
                title: "Collecting evidence · \(pairedWindowCount) of \(requiredWindowCount) paired windows",
                systemImage: "hourglass",
                tint: .orange
            )
        case let .ready(statistics):
            StatePresentation(
                title: "Analysis ready · \(statistics.severity.title)",
                systemImage: statistics.severity.systemImage,
                tint: statistics.severity.tint
            )
        }
    }

    private func interpretation(for analysis: PairwiseAnalysis) -> String {
        switch analysis.state {
        case .noOverlap:
            return "The devices did not report in any shared aligned window, so this range cannot support an agreement conclusion. This is missing overlap, not evidence that the devices agree or disagree."

        case let .collecting(pairedWindowCount, requiredWindowCount):
            return "Only \(pairedWindowCount) paired windows are available; HeartSync requires \(requiredWindowCount) before describing agreement. The observations and export remain available, but any apparent pattern may be coincidence."

        case let .ready(statistics):
            switch statistics.classification {
            case .noApparentDifference:
                return "Across these paired windows, the mean absolute difference is \(kind.formatWithUnit(statistics.meanAbsoluteDifference)), within the app’s fixed tolerance. This describes the selected observations only; it does not prove equivalence, statistical significance, or medical accuracy."

            case .systematicBias:
                let higher = statistics.meanBias >= 0 ? sourceAName : sourceBName
                let lower = statistics.meanBias >= 0 ? sourceBName : sourceAName
                return "\(higher) reads about \(kind.formatWithUnit(abs(statistics.meanBias))) higher than \(lower) on average in these paired windows. That is a consistent offset, but neither device is a medical reference and this analysis cannot say which is more accurate."

            case .measurementNoise:
                return "The difference changes direction across paired windows, with a difference SD of \(kind.formatWithUnit(statistics.differenceSD)). That pattern is more consistent with variable measurement spread than a stable offset; it does not identify either device as correct."
            }
        }
    }

    // MARK: - Export

    private func prepareExport(_ analysis: PairwiseAnalysis) {
        discardShareFiles()

        do {
            // A source record can be missing for an analysis that still has observations
            // (a device removed mid-session). The exporter falls back to the stable source
            // ID, so the export stays available rather than failing on cosmetic metadata.
            let export = PairwiseExporter.makeExport(
                analysis: analysis,
                sources: [sourceA, sourceB].compactMap { $0 },
                appVersion: appVersion,
                generatedAt: .now
            )
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HeartSync-Pairwise-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

            do {
                let csvURL = directory.appendingPathComponent(export.csvFilename)
                let summaryURL = directory.appendingPathComponent(export.summaryFilename)
                try export.csvData.write(to: csvURL, options: .atomic)
                try export.summaryData.write(to: summaryURL, options: .atomic)
                shareDirectory = directory
                sharePayload = PairwiseSharePayload(urls: [csvURL, summaryURL])
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } catch {
            exportError = "HeartSync could not create the temporary export files. \(error.localizedDescription)"
        }
    }

    private func discardShareFiles() {
        if let shareDirectory {
            try? FileManager.default.removeItem(at: shareDirectory)
        }
        shareDirectory = nil
        sharePayload = nil
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    // MARK: - Formatting

    private func signed(_ value: Double, withUnit: Bool = false) -> String {
        let magnitude = kind.format(abs(value))
        let valueText = value >= 0 ? "+\(magnitude)" : "−\(magnitude)"
        return withUnit ? "\(valueText) \(kind.unit)" : valueText
    }

    private func windowDescription(_ seconds: TimeInterval) -> String {
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(Int(seconds / 86_400))-day"
        }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
            return "\(Int(seconds / 3_600))-hour"
        }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            return "\(Int(seconds / 60))-minute"
        }
        return "\(Int(seconds))-second"
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .hour, .sixHours: .dateTime.hour().minute()
        case .day:             .dateTime.hour()
        case .week, .month:    .dateTime.month(.abbreviated).day()
        }
    }
}

private struct PairwiseSharePayload: Identifiable {
    let id = UUID()
    var urls: [URL]
}

private struct PairwiseActivityView: UIViewControllerRepresentable {
    var items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
