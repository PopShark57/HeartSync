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
    /// A saved session whose exact span this screen analyses and exports, or nil.
    let session: ComparisonSession?

    @State private var range: TimeRange
    /// The only state a drag writes. Everything it is compared against lives in `snapshot`.
    @State private var selectedObservationStart: Date?
    @State private var snapshot: PairwiseSnapshot?
    @State private var retryToken = 0
    @State private var lastLoadedKey: LoadKey?
    @State private var lastLoadedAt: Date?
    @State private var sharePayload: PairwiseSharePayload?
    @State private var shareDirectory: URL?
    @State private var exportError: String?

    init(
        kind: MetricKind,
        sourceAID: String,
        sourceBID: String,
        initialRange: TimeRange = .day,
        session: ComparisonSession? = nil
    ) {
        self.kind = kind
        self.sourceAID = min(sourceAID, sourceBID)
        self.sourceBID = max(sourceAID, sourceBID)
        self.session = session
        _range = State(initialValue: initialRange)
    }

    /// The span analysed: a saved session's fixed seconds, otherwise the rolling preset.
    private var period: ComparisonPeriod {
        session.map { .fixed($0.interval) } ?? .rolling(range)
    }

    /// Everything the snapshot depends on. Selection is deliberately absent: a drag must
    /// never cause a store read or a re-analysis.
    private struct LoadKey: Hashable {
        var generation: Int
        var kind: MetricKind
        var sourceA: String
        var sourceB: String
        var period: ComparisonPeriod
        var retryToken: Int

        /// True when `other` asks the same question and only the data may have changed.
        func sameSelection(as other: LoadKey) -> Bool {
            var aligned = other
            aligned.generation = generation
            return aligned == self
        }
    }

    private var loadKey: LoadKey {
        LoadKey(
            generation: model.store.changeToken,
            kind: kind,
            sourceA: sourceAID,
            sourceB: sourceBID,
            period: period,
            retryToken: retryToken
        )
    }

    var body: some View {
        Group {
            if let snapshot {
                content(snapshot)
            } else {
                List {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading comparison\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("pairwise.loading")
                }
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: range) {
            selectedObservationStart = nil
        }
        // Cancels a superseded load and rejects a late one. New data alone is coalesced,
        // so a live strap does not re-analyse a month once a second.
        .task(id: loadKey) {
            let key = loadKey
            let wait = LiveReloadPolicy.delay(
                dataOnly: lastLoadedKey.map { key.sameSelection(as: $0) } ?? false,
                elapsed: lastLoadedAt.map { Date.now.timeIntervalSince($0) },
                minimumInterval: LiveReloadPolicy.minimumInterval(for: period)
            )
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let resolved = PairwiseSnapshot(
                store: model.store,
                kind: kind,
                sourceA: sourceAID,
                sourceB: sourceBID,
                period: period
            )
            guard !Task.isCancelled, key == loadKey else { return }
            snapshot = resolved
            lastLoadedKey = key
            lastLoadedAt = .now
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

    @ViewBuilder
    private func content(_ snapshot: PairwiseSnapshot) -> some View {
        let currentAnalysis = snapshot.analysis
        // These read the store/Bluetooth manager's small in-memory state, so they are
        // resolved once per render rather than from inside a computed property that several
        // subviews would each re-evaluate. None of them touches the database.
        let sensingNote = sensingDifferenceNote
        let relationshipNote = sourceRelationshipNote
        let beatQuality = hrvBeatQuality()

        List {
            Section {
                // A saved session's span is fixed, so the rolling picker is replaced rather
                // than left to imply a range this screen is not analysing.
                if let session {
                    ComparisonSessionBanner(session: session)
                        .accessibilityIdentifier("pairwise.session")
                } else {
                    Picker("Range", selection: $range) {
                        ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .accessibilityIdentifier("pairwise.range")
                }
                if snapshot.generation != model.store.changeToken {
                    SnapshotLagNote(resolvedAt: snapshot.resolvedAt)
                }
            }

            if let failure = snapshot.queryFailure {
                // A failed read is not "no overlapping windows"; that would be a claim about
                // the user's devices that this screen cannot support.
                Section {
                    HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                        .accessibilityIdentifier("pairwise.unavailable")
                }
            }

            Section {
                sourceOrder
                evidenceCard(currentAnalysis, beatQuality: beatQuality)
            } header: {
                Text("Evidence")
            } footer: {
                Text("A signed difference is always Device A minus Device B. Estimates are excluded, and raw samples are reduced to one median per aligned window.")
            }

            if snapshot.queryFailure != nil {
                // Already stated above; drawing empty charts here would contradict it.
                EmptyView()
            } else if currentAnalysis.observations.isEmpty {
                Section {
                    EmptyStateView(
                        systemImage: "rectangle.on.rectangle.slash",
                        title: "No overlapping windows",
                        message: session == nil
                            ? "These devices never reported inside the same aligned \(windowDescription(currentAnalysis.windowSize)) window in this range. Widen the range, or wear both devices at the same time."
                            : "These devices never reported inside the same aligned \(windowDescription(currentAnalysis.windowSize)) window during this saved session."
                    )
                }
            } else {
                Section {
                    pairedTimeline(snapshot)
                        .frame(height: 250)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 12))
                    deviceLegend
                } header: {
                    Text("Paired values")
                } footer: {
                    Text("Each line connects the per-window medians for one device. Drag across the chart to inspect the nearest paired window.\(snapshot.thinningNote)")
                }

                Section {
                    blandAltmanChart(snapshot)
                        .frame(height: 280)
                        .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 8, trailing: 12))
                    differenceLegend
                } header: {
                    Text("Difference versus paired mean")
                } footer: {
                    Text("The horizontal position is the mean of the two device values. The vertical position is A minus B. Limits of agreement describe these observations; they are not inferential confidence intervals.")
                }

                if let selected = snapshot.observation(startingAt: selectedObservationStart) {
                    Section("Selected paired window") {
                        selectedObservationCard(selected, snapshot: snapshot)
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
    }

    private var sourceA: DataSource? { model.store.source(id: sourceAID) }
    private var sourceB: DataSource? { model.store.source(id: sourceBID) }
    private var sourceAName: String { model.store.displayName(forSource: sourceAID) }
    private var sourceBName: String { model.store.displayName(forSource: sourceBID) }
    /// A removed source falls back to validated palette slots, never to a system hue that
    /// could collide with a device or with the agreement scale.
    private var sourceAColor: Color { sourceA?.color ?? DataSource.palette[0] }
    private var sourceBColor: Color { sourceB?.color ?? DataSource.palette[1] }

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
            // Overlap counts shared buckets; these say whether the readings inside those
            // buckets were actually taken at the same time, and how much of the span they
            // cover. A high window count over sparse coverage is not continuous evidence.
            LabeledContent("Typical separation") {
                Text(medianSeparationText(analysis))
            }
            if analysis.evidence.temporallySeparatedCount > 0 || analysis.evidence.unknownTimingCount > 0 {
                LabeledContent("Timing caveats") {
                    Text(timingCaveatText(analysis))
                        .foregroundStyle(.orange)
                }
            }
            if let coverage = analysis.evidence.coverageFraction {
                LabeledContent("Paired coverage") {
                    Text(percentText(coverage))
                }
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

    /// A's and B's mark shapes: each device's own slot shape, split apart in the rare case
    /// that two devices share a palette slot.
    private var pairSymbols: (a: SourceSymbol, b: SourceSymbol) {
        switch (sourceA, sourceB) {
        case let (a?, b?):
            let symbols = MetricDetailSnapshot.symbols(for: [a, b])
            return (symbols[0], symbols[1])
        case let (a?, nil):
            return (a.symbol, a.symbol == .square ? .circle : .square)
        case let (nil, b?):
            return (b.symbol == .circle ? .square : .circle, b.symbol)
        case (nil, nil):
            return (.circle, .square)
        }
    }

    private func pairedTimeline(_ snapshot: PairwiseSnapshot) -> some View {
        let points = snapshot.plotted
        let selected = snapshot.observation(startingAt: selectedObservationStart)
        let symbols = pairSymbols

        return Chart {
            ForEach(Array(points.enumerated()), id: \.element.start) { position, observation in
                // Keyed per segment, not per device: a stretch with no paired window is a
                // gap in the comparison, and the line must not run through it.
                let segment = snapshot.timelineSegments[position]
                let isSelected = selectedObservationStart == observation.start

                LineMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceA.value),
                    series: .value("Device", ChartSegmentation.key(series: "A", segment: segment))
                )
                .foregroundStyle(sourceAColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)

                // Every window keeps its point, so an isolated pairing stays visible after
                // the line breaks around it. Shape as well as colour separates A from B.
                PointMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceA.value)
                )
                .foregroundStyle(sourceAColor)
                .symbol(symbols.a.chartSymbol)
                .symbolSize(isSelected ? 80 : 28)

                LineMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceB.value),
                    series: .value("Device", ChartSegmentation.key(series: "B", segment: segment))
                )
                .foregroundStyle(sourceBColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)

                PointMark(
                    x: .value("Window", observation.start),
                    y: .value(kind.title, observation.sourceB.value)
                )
                .foregroundStyle(sourceBColor)
                .symbol(symbols.b.chartSymbol)
                .symbolSize(isSelected ? 80 : 28)
            }

            // "A" and "B" at the line ends, the higher label above and the lower below, so
            // the two lines can be told apart without comparing colours at all.
            if let last = points.last {
                let aIsHigher = last.sourceA.value >= last.sourceB.value
                lineEndLabel("A", value: last.sourceA.value, at: last.start, above: aIsHigher, color: sourceAColor)
                lineEndLabel("B", value: last.sourceB.value, at: last.start, above: !aIsHigher, color: sourceBColor)
            }

            if let selected {
                RuleMark(x: .value("Selected window", selected.start))
                    .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk.opacity(0.7))
                    .lineStyle(HeartSyncTheme.Chart.selection)
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: snapshot.timelineYDomain)
        .chartXAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat(snapshot.period.displayRange))
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartOverlay { proxy in timelineSelectionOverlay(proxy: proxy, snapshot: snapshot) }
        .accessibilityLabel("Paired value timeline for \(sourceAName) and \(sourceBName)")
        .accessibilityHint("Drag across the chart to select the nearest paired window")
    }

    /// An invisible anchor at a line's last point that carries its "A" or "B" label.
    private func lineEndLabel(
        _ text: String,
        value: Double,
        at date: Date,
        above: Bool,
        color: Color
    ) -> some ChartContent {
        PointMark(
            x: .value("Window", date),
            y: .value(kind.title, value)
        )
        .symbolSize(0)
        .annotation(
            position: above ? .top : .bottom,
            spacing: 4,
            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
        ) {
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
        }
        .accessibilityHidden(true)
    }

    private func blandAltmanChart(_ snapshot: PairwiseSnapshot) -> some View {
        let points = snapshot.plotted
        let selected = snapshot.observation(startingAt: selectedObservationStart)

        return Chart {
            // Reference lines are neutral ink told apart by dash pattern and weight. Hue is
            // reserved for devices and for the agreement scale, so no statistic can be
            // mistaken for a device line on the timeline above.
            RuleMark(y: .value("Zero difference", 0))
                .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
                .lineStyle(HeartSyncTheme.Chart.zeroDifference)

            toleranceRules(kind.agreement.warn, label: "Warning", style: HeartSyncTheme.Chart.warningTolerance)
            toleranceRules(kind.agreement.alert, label: "Major", style: HeartSyncTheme.Chart.majorTolerance)

            if let stats = snapshot.analysis.statistics {
                RuleMark(y: .value("Mean bias", stats.meanBias))
                    .foregroundStyle(HeartSyncTheme.Chart.referenceInk)
                    .lineStyle(HeartSyncTheme.Chart.meanBias)

                RuleMark(y: .value("Lower 95% limit", stats.limitsOfAgreement.lowerBound))
                    .foregroundStyle(HeartSyncTheme.Chart.referenceInk)
                    .lineStyle(HeartSyncTheme.Chart.limitsOfAgreement)

                RuleMark(y: .value("Upper 95% limit", stats.limitsOfAgreement.upperBound))
                    .foregroundStyle(HeartSyncTheme.Chart.referenceInk)
                    .lineStyle(HeartSyncTheme.Chart.limitsOfAgreement)
            }

            ForEach(points, id: \.start) { observation in
                let outside = snapshot.isOutsideLimits(observation)
                PointMark(
                    x: .value("Paired mean", observation.pairedMean),
                    y: .value("A minus B", observation.signedDifference)
                )
                .foregroundStyle(observation.severity.tint)
                .symbolSize(differenceSymbolSize(observation, outside: outside))

                // Outside the limits is a statistical fact, so it is marked in the limits'
                // own neutral ink: a ring, rather than a hue that a device also wears.
                if outside {
                    PointMark(
                        x: .value("Paired mean", observation.pairedMean),
                        y: .value("A minus B", observation.signedDifference)
                    )
                    .symbol {
                        Circle()
                            .strokeBorder(HeartSyncTheme.Chart.referenceInk, lineWidth: 1.5)
                            .frame(width: 15, height: 15)
                    }
                    .accessibilityHidden(true)
                }
            }

            if let selected {
                RuleMark(x: .value("Selected paired mean", selected.pairedMean))
                    .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk.opacity(0.55))
                    .lineStyle(HeartSyncTheme.Chart.selection)
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: snapshot.differenceXDomain)
        .chartYScale(domain: snapshot.differenceYDomain)
        .chartXAxisLabel("Paired mean (\(kind.unit))")
        .chartYAxisLabel("A − B (\(kind.unit))")
        .chartXAxis { AxisMarks(preset: .aligned) }
        .chartYAxis { AxisMarks(position: .leading) }
        .chartOverlay { proxy in differenceSelectionOverlay(proxy: proxy, snapshot: snapshot) }
        .accessibilityLabel("Bland Altman plot of Device A minus Device B")
        .accessibilityHint("Drag across the chart to select the observation with the nearest paired mean")
    }

    @ChartContentBuilder
    private func toleranceRules(
        _ tolerance: Double,
        label: String,
        style: StrokeStyle
    ) -> some ChartContent {
        RuleMark(y: .value("Positive \(label) tolerance", tolerance))
            .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
            .lineStyle(style)
        RuleMark(y: .value("Negative \(label) tolerance", -tolerance))
            .foregroundStyle(HeartSyncTheme.Chart.secondaryReferenceInk)
            .lineStyle(style)
    }

    /// Selection writes one date. The nearest window comes from a binary search over starts
    /// the snapshot sorted when it loaded, so a drag never reads the store or re-analyses.
    private func timelineSelectionOverlay(
        proxy: ChartProxy,
        snapshot: PairwiseSnapshot
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
                            selectedObservationStart = snapshot.observation(nearestStart: date)?.start
                        }
                )
        }
    }

    private func differenceSelectionOverlay(
        proxy: ChartProxy,
        snapshot: PairwiseSnapshot
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
                            selectedObservationStart = snapshot.observation(nearestPairedMean: pairedMean)?.start
                        }
                )
        }
    }

    private var deviceLegend: some View {
        let symbols = pairSymbols
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                sourceLegend(label: "A", name: sourceAName, color: sourceAColor, symbol: symbols.a)
                sourceLegend(label: "B", name: sourceBName, color: sourceBColor, symbol: symbols.b)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                sourceLegend(label: "A", name: sourceAName, color: sourceAColor, symbol: symbols.a)
                sourceLegend(label: "B", name: sourceBName, color: sourceBColor, symbol: symbols.b)
            }
        }
    }

    private func sourceLegend(label: String, name: String, color: Color, symbol: SourceSymbol) -> some View {
        HStack(spacing: 6) {
            SourceSymbolGlyph(symbol: symbol, color: color)
            Text("\(label)  \(name)").font(.caption2).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Device \(label), \(name), \(symbol.accessibilityName) marks")
    }

    private var differenceLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            legendRule(ink: HeartSyncTheme.Chart.referenceInk, style: HeartSyncTheme.Chart.meanBias, label: "Mean bias")
            legendRule(ink: HeartSyncTheme.Chart.referenceInk, style: HeartSyncTheme.Chart.limitsOfAgreement, label: "95% limits of agreement")
            legendRule(ink: HeartSyncTheme.Chart.secondaryReferenceInk, style: HeartSyncTheme.Chart.warningTolerance, label: "Warning tolerance")
            legendRule(ink: HeartSyncTheme.Chart.secondaryReferenceInk, style: HeartSyncTheme.Chart.majorTolerance, label: "Major tolerance")
            HStack(spacing: 6) {
                Circle()
                    .strokeBorder(HeartSyncTheme.Chart.referenceInk, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)
                Text("Ringed point: outside the observed 95% limits")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    ForEach([DiscrepancySeverity.agreeing, .notable, .major], id: \.self) { severity in
                        Circle().fill(severity.tint).frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
                Text("Point colour: agreement for that window, from within tolerance to major")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func legendRule(ink: Color, style: StrokeStyle, label: String) -> some View {
        HStack(spacing: 6) {
            ReferenceLineSwatch(ink: ink, style: style)
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func selectedObservationCard(
        _ observation: PairwiseObservation,
        snapshot: PairwiseSnapshot
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
            // Being in the same bucket is not the same as being at the same moment, and a
            // user investigating one disagreement needs to know which of the two this is.
            LabeledContent("Measurement timing") {
                Text(observation.timing.title)
                    .foregroundStyle(observation.timing.supportsConclusion ? Color.secondary : Color.orange)
            }
            LabeledContent("Apart in time") {
                Text(separationText(observation))
            }
            LabeledContent("Contributing span") {
                Text("A \(durationText(observation.contributingDurationA))  ·  B \(durationText(observation.contributingDurationB))")
            }
            if observation.timing == .separated {
                Text("These two readings landed in the same aligned window but were taken far enough apart that the gap may reflect when each device measured, not how they differ.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if observation.sourceA.isCompacted || observation.sourceB.isCompacted {
                Text("Compacted window median; old corrections and upstream deletions cannot be reapplied.")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Provenance") {
                Text("A \(observation.sourceA.provenance.title)  ·  B \(observation.sourceB.provenance.title)")
            }

            if snapshot.isOutsideLimits(observation) {
                Label("Outside the observed 95% limits of agreement", systemImage: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func differenceSymbolSize(_ observation: PairwiseObservation, outside: Bool) -> CGFloat {
        if selectedObservationStart == observation.start { return 115 }
        if outside || observation.severity != .agreeing { return 75 }
        return 42
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

    /// Unknown separation is spelled out rather than shown as a dash or a zero: a compacted
    /// window genuinely does not know, and that is different from "at the same instant".
    private func separationText(_ observation: PairwiseObservation) -> String {
        switch observation.timing {
        case .notApplicable:
            return "Not applicable to an interval summary"
        case .unknown:
            return "Unknown — compacted window"
        case .simultaneous, .separated:
            guard let separation = observation.timingSeparation else { return "Unknown" }
            return WindowLabel.elapsed(separation)
        }
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "unknown" }
        return duration == 0 ? "instant" : WindowLabel.elapsed(duration)
    }

    private func medianSeparationText(_ analysis: PairwiseAnalysis) -> String {
        guard analysis.kind.timingTolerance != nil else { return "Interval summary" }
        guard let median = analysis.evidence.medianTimingSeparation else { return "Unknown" }
        return WindowLabel.elapsed(median)
    }

    private func timingCaveatText(_ analysis: PairwiseAnalysis) -> String {
        var parts: [String] = []
        let separated = analysis.evidence.temporallySeparatedCount
        let unknown = analysis.evidence.unknownTimingCount
        if separated > 0 { parts.append("\(separated) too far apart") }
        if unknown > 0 { parts.append("\(unknown) unknown") }
        return parts.joined(separator: " · ")
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

    /// Keyed on the analysed period rather than the picker, so a saved session is labelled
    /// at the zoom that fits its span.
    private func axisFormat(_ displayRange: TimeRange) -> Date.FormatStyle {
        switch displayRange {
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
