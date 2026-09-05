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
        // Both of these read the store/Bluetooth manager, so they are resolved once per
        // render alongside the analysis rather than from inside a computed property that
        // several subviews would each re-evaluate.
        let sensingNote = sensingDifferenceNote
        let relationshipNote = sourceRelationshipNote
        let beatQuality = hrvBeatQuality()

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
                evidenceCard(currentAnalysis, beatQuality: beatQuality)
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

                // Deliberately a separate, secondary row rather than part of the verdict:
                // explicit technology metadata or reported placement can provide context,
                // but neither decides which device is right.
                if let sensingNote {
                    Label {
                        Text(sensingNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let relationshipNote {
                Section {
                    Label(relationshipNote, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } header: {
                    Text("Source independence")
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
        .accessibilityLabel("Device A \(sourceAName)\(accessibleSensing(sourceA)), minus Device B \(sourceBName)\(accessibleSensing(sourceB))")
    }

    /// Spoken form keeps reported placement separate from independently known technology.
    private func accessibleSensing(_ source: DataSource?) -> String {
        var facts: [String] = []
        if let location = source?.bodyLocation { facts.append("worn at the \(location.title.lowercased())") }
        if let technology = source?.sensingTechnology { facts.append("\(technology.title) technology") }
        return facts.isEmpty ? "" : ", " + facts.joined(separator: ", ")
    }

    /// Visible description of where a sensor sits and what it senses.
    ///
    /// `.other` is shown as a location only. The model treats every non-chest location as
    /// optical, which is a sound default for a finger, wrist or ear sensor but is not
    /// evidence about a device that declined to say where it sits, and this screen must
    /// not turn that default into a stated technology.
    private func sensingDescription(_ source: DataSource) -> String? {
        let facts = [source.bodyLocation?.title, source.sensingTechnology?.title].compactMap { $0 }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
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
                // Only Bluetooth devices that report Body Sensor Location (0x2A38) have
                // this; the row is simply absent for everything else rather than guessing.
                if let source, let description = sensingDescription(source) {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func evidenceCard(
        _ analysis: PairwiseAnalysis,
        beatQuality: [HRVBeatQuality]
    ) -> some View {
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
            LabeledContent("Original samples") {
                Text("A \(sampleCountText(analysis.rawSampleCountA))  ·  B \(sampleCountText(analysis.rawSampleCountB))")
            }
            LabeledContent("Evidence grade") { Text(analysis.evidence.grade.title) }
            if !analysis.evidence.reasons.isEmpty {
                Text(analysis.evidence.reasons.joined(separator: ". "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                if let interval = stats.meanBiasConfidenceInterval {
                    LabeledContent("Bias confidence interval") {
                        Text("\(signed(interval.lowerBound)) to \(signed(interval.upperBound)) \(kind.unit)")
                    }
                }
            }

            if !beatQuality.isEmpty {
                Divider()
                ForEach(beatQuality) { entry in
                    LabeledContent("Beat quality · \(entry.label)") {
                        Text("\(percentText(entry.quality.artefactFraction)) rejected  ·  \(entry.quality.beatCount) beats  ·  ")
                            + Text(entry.quality.measuredAt, format: .relative(presentation: .named))
                    }
                }
                Text(beatQualityCaveat(beatQuality))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Text("A \(sampleCountText(observation.sourceA.sampleCount))  ·  B \(sampleCountText(observation.sourceB.sampleCount))")
            }
            LabeledContent("Within-window SD") {
                Text("A \(spreadText(observation.sourceA.standardDeviation))  ·  B \(spreadText(observation.sourceB.standardDeviation)) \(kind.unit)")
            }
            if observation.sourceA.isCompacted || observation.sourceB.isCompacted {
                Text("Compacted window median; old corrections and upstream deletions cannot be reapplied.")
                    .foregroundStyle(.secondary)
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

    // MARK: - Sensing technology

    /// One sentence explaining that the two devices sense different physical signals,
    /// or `nil` when that cannot be said honestly.
    ///
    /// Returns a note only when *both* devices reported Body Sensor Location (0x2A38) and
    /// one is optical while the other is electrical. A missing location is not assumed to
    /// mean anything, and two devices using the same technology get no note: the point is
    /// to name a known difference in what is being sensed, not to speculate.
    ///
    /// Framing invariant: this text explains where a difference can originate. It must
    /// never claim the devices therefore agree, never excuse or discount a measured
    /// disagreement, and never present either technology as the reference standard — an
    /// electrical sensor is not "the correct one" here. It is deliberately rendered as a
    /// secondary row beneath the verdict, and the verdict text itself is untouched.
    private var sensingDifferenceNote: String? {
        guard let locationA = sourceA?.bodyLocation, let locationB = sourceB?.bodyLocation,
              locationA != locationB
        else { return nil }

        var sentences = [
            "These devices report different placements: \(sourceAName) at the \(locationA.title.lowercased()), and \(sourceBName) at the \(locationB.title.lowercased()). Placement can contribute to disagreement, but it does not identify PPG or ECG.",
        ]

        if isVariabilityMetric {
            sentences.append("Different placements can observe beat timing under different motion and contact conditions, so they may affect \(kind.title).")
        } else {
            sentences.append("Part of the difference can come from placement or contact rather than either device malfunctioning.")
        }

        sentences.append("This explains where a difference can come from. It does not resolve one, does not make either value correct, and neither technology is treated as a reference standard.")

        return sentences.joined(separator: " ")
    }

    private var sourceRelationshipNote: String? {
        guard let sourceA, let sourceB, sourceA.likelyRepresentsSameDevice(as: sourceB) else { return nil }
        return "These sources likely describe the same upstream device through different transports. Agreement is not independent corroboration."
    }

    private func sampleCountText(_ count: Int?) -> String { count.map(String.init) ?? "unknown" }
    private func spreadText(_ spread: Double?) -> String { spread.map(kind.format) ?? "unknown" }

    /// Whether this screen compares a beat-to-beat variability metric. Exhaustive so a new
    /// `MetricKind` has to decide whether the HRV beat-quality caveat applies to it.
    private var isVariabilityMetric: Bool {
        switch kind {
        case .hrvSDNN, .hrvRMSSD:
            true
        case .heartRate, .restingHeartRate, .spo2, .respiratoryRate, .bodyTemperature,
             .vo2Max, .bloodPressureSystolic, .bloodPressureDiastolic:
            false
        }
    }

    // MARK: - Beat quality

    /// The most recent HRV window quality HeartSync derived for one side of the pair.
    ///
    /// Only exists for Bluetooth sources, because it comes from this app's own R–R
    /// artefact rejection (`HRVCalculator`); HealthKit and Oura deliver finished HRV
    /// numbers with no beat-level provenance to report.
    private struct HRVBeatQuality: Identifiable {
        var id: String { sourceID }
        /// "A" or "B", matching the canonical ordering used everywhere else on this screen.
        var label: String
        var sourceID: String
        var sourceName: String
        var quality: HRVQuality
    }

    /// Artefact fraction at or above which the caveat is escalated from descriptive to a
    /// warning. `HRVMetrics.maximumArtefactFraction` (0.25) already discards a window
    /// outright, so anything reaching this screen is below that; 10% is the point where
    /// enough beats were discarded that the surviving HRV figure deserves a hedge.
    private static let notableArtefactFraction = 0.10

    /// Latest beat quality for each side of the pair, in canonical A-then-B order. Empty
    /// for non-variability metrics and for pairs with no Bluetooth-derived HRV.
    private func hrvBeatQuality() -> [HRVBeatQuality] {
        guard isVariabilityMetric else { return [] }

        return [(label: "A", id: sourceAID, name: sourceAName), (label: "B", id: sourceBID, name: sourceBName)]
            .compactMap { entry in
                guard model.store.source(id: entry.id)?.transport == .bluetooth else { return nil }
                // Bluetooth source IDs are the peripheral's `CBPeripheral.identifier`
                // string, which is exactly how `BluetoothManager` keys its HRV quality.
                guard let peripheralID = UUID(uuidString: entry.id),
                      let quality = model.bluetooth.hrvQuality[peripheralID] else { return nil }
                return HRVBeatQuality(
                    label: entry.label,
                    sourceID: entry.id,
                    sourceName: entry.name,
                    quality: quality
                )
            }
    }

    /// States exactly what the artefact fraction covers, and hedges the comparison when a
    /// large share of beats was discarded.
    ///
    /// Two honesty constraints: the figure describes the *latest* HRV window from that
    /// device, not every window in the selected range, so it is never presented as a
    /// property of the analysis; and a weak window weakens this comparison rather than
    /// transferring the difference onto the other device.
    private func beatQualityCaveat(_ entries: [HRVBeatQuality]) -> String {
        let base = "Beat quality is the most recent HRV window HeartSync derived for that device, not every window in this range. Rejected beats are R–R intervals the artefact filter discarded before HRV was computed."

        guard let worst = entries.max(by: { $0.quality.artefactFraction < $1.quality.artefactFraction }),
              worst.quality.artefactFraction >= Self.notableArtefactFraction else {
            return base
        }

        return base + " \(worst.sourceName) discarded \(percentText(worst.quality.artefactFraction)) of its intervals in that window, so its HRV there is weak evidence. That weakens this comparison; it does not attribute the difference to the other device."
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

    /// Formats a 0...1 fraction as a whole-number percentage.
    private func percentText(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
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
