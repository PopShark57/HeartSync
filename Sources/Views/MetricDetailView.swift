import Charts
import SwiftUI

/// Full history of one metric with every source overlaid, plus the pairwise agreement
/// statistics for that metric.
struct MetricDetailView: View {
    @Environment(AppModel.self) private var model
    let kind: MetricKind
    /// A saved session whose exact span this screen analyses, or nil for a rolling preset.
    let session: ComparisonSession?

    /// Seeded once, in `init`. `onAppear` runs again when a pushed pair view is popped, so
    /// assigning the initial range there reset the user's choice on every Back.
    @State private var range: TimeRange
    /// Presentation only. Estimated values are drawn as dashed lines when this is on; they
    /// are never fed into a comparison verdict either way \u{2014} see `MetricDetailSnapshot`.
    @State private var showEstimates = true
    /// Bumped by the retry button so the load key changes and the query runs again.
    @State private var retryToken = 0
    @State private var snapshot: MetricDetailSnapshot?
    /// The last completed load, so a reload caused only by new data can be coalesced.
    @State private var lastLoadedKey: LoadKey?
    @State private var lastLoadedAt: Date?

    // MARK: Chart interaction (improvements 32 and 33)

    /// The window the chart's callout describes. It survives the finger lifting and is
    /// cleared by a touch in empty plot area, by Clear, and by any zoom, pan, or range change.
    @State private var selectedWindowStart: Date?
    /// A legend entry the user emphasised. Presentation only: no data is hidden.
    @State private var emphasisedSourceID: String?
    /// The zoomed-in span, or nil for the whole analysed period.
    @State private var viewport: ChartViewport?
    /// The visible span re-read at its own, finer bucket (semantic zoom).
    @State private var zoomSnapshot: MetricZoomSnapshot?
    @State private var zoomLoadedKey: ZoomLoadKey?
    @State private var zoomLoadedAt: Date?
    /// While true, a drag across the chart chooses a period instead of scrubbing.
    @State private var isSelectingPeriod = false
    /// A period the user dragged out, with its own pair evidence below the chart.
    @State private var selectedPeriod: DateInterval?
    @State private var periodEvidence: MetricPeriodEvidence?
    @State private var periodLoadedKey: PeriodLoadKey?
    @State private var periodLoadedAt: Date?
    @State private var savingPeriod = false

    init(kind: MetricKind, initialRange: TimeRange = .day, session: ComparisonSession? = nil) {
        self.kind = kind
        self.session = session
        _range = State(initialValue: initialRange)
    }

    /// The span analysed: a saved session's fixed seconds when one is open, otherwise the
    /// rolling preset. Opening "Morning walk" must not quietly show the last 24 hours.
    private var period: ComparisonPeriod {
        session.map { .fixed($0.interval) } ?? .rolling(range)
    }

    /// Everything the snapshot depends on. An unrelated view update leaves this unchanged
    /// and reuses the resolved snapshot instead of re-reading and re-windowing the range.
    private struct LoadKey: Hashable {
        var generation: Int
        var hrvQualityCount: Int
        var kind: MetricKind
        var period: ComparisonPeriod
        var showEstimates: Bool
        var retryToken: Int

        /// True when `other` asks the same question and only the data may have changed.
        func sameSelection(as other: LoadKey) -> Bool {
            var aligned = other
            aligned.generation = generation
            aligned.hrvQualityCount = hrvQualityCount
            return aligned == self
        }
    }

    private var loadKey: LoadKey {
        LoadKey(
            generation: model.store.changeToken,
            hrvQualityCount: isHRV ? model.bluetooth.hrvQuality.count : 0,
            kind: kind,
            period: period,
            showEstimates: showEstimates,
            retryToken: retryToken
        )
    }

    /// Everything a zoomed chart depends on. Selection is deliberately absent: a scrub must
    /// never cause a store read.
    private struct ZoomLoadKey: Hashable {
        var viewport: ChartViewport
        var generation: Int
        var showEstimates: Bool
        var seriesIDs: [String]
        var retryToken: Int

        func sameSelection(as other: ZoomLoadKey) -> Bool {
            var aligned = other
            aligned.generation = generation
            return aligned == self
        }
    }

    private var zoomLoadKey: ZoomLoadKey? {
        guard let viewport, let snapshot else { return nil }
        return ZoomLoadKey(
            viewport: viewport,
            generation: model.store.changeToken,
            showEstimates: showEstimates,
            seriesIDs: snapshot.styleDomain,
            retryToken: retryToken
        )
    }

    /// Everything a selected period's evidence depends on.
    private struct PeriodLoadKey: Hashable {
        var period: DateInterval
        var generation: Int
        var retryToken: Int

        func sameSelection(as other: PeriodLoadKey) -> Bool {
            var aligned = other
            aligned.generation = generation
            return aligned == self
        }
    }

    private var periodLoadKey: PeriodLoadKey? {
        selectedPeriod.map {
            PeriodLoadKey(period: $0, generation: model.store.changeToken, retryToken: retryToken)
        }
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
        // Cancels a superseded load and rejects a late one, so a slow month-range result
        // cannot replace a newer hour-range selection.
        .task(id: loadKey) {
            let key = loadKey
            // A changed question loads after one frame; new data alone is coalesced, so a
            // 1 Hz strap does not re-read and re-window a month on every reading.
            let wait = LiveReloadPolicy.delay(
                dataOnly: lastLoadedKey.map { key.sameSelection(as: $0) } ?? false,
                elapsed: lastLoadedAt.map { Date.now.timeIntervalSince($0) },
                minimumInterval: LiveReloadPolicy.minimumInterval(for: period)
            )
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let resolved = MetricDetailSnapshot(
                store: model.store,
                kind: kind,
                period: period,
                includeEstimates: showEstimates,
                hrvQuality: isHRV ? model.bluetooth.hrvQuality : [:]
            )
            guard !Task.isCancelled, key == loadKey else { return }
            snapshot = resolved
            lastLoadedKey = key
            lastLoadedAt = .now
        }
        .task(id: zoomLoadKey) {
            await loadZoom()
        }
        .task(id: periodLoadKey) {
            await loadPeriodEvidence()
        }
        // A new range is a new question: nothing selected, zoomed, or chosen on the old
        // range describes the new one.
        .onChange(of: range) {
            resetChartInteraction()
        }
        // A rolling period moves with the clock. The zoomed view stays where the user put
        // it while it still fits, and moves only as far as it must when it does not.
        .onChange(of: snapshot?.interval) { _, interval in
            guard let interval, let current = viewport else { return }
            viewport = current.clamped(to: interval, kind: kind)
        }
        .sheet(isPresented: $savingPeriod) {
            if let selectedPeriod {
                SaveComparisonSessionView(start: selectedPeriod.start, end: selectedPeriod.end, metric: kind)
            }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: MetricDetailSnapshot) -> some View {
        let chart = displayedChart(snapshot)
        List {
            Section {
                // A saved session's span is fixed, so the rolling picker is replaced rather
                // than left to imply a range this screen is not analysing.
                if let session {
                    ComparisonSessionBanner(session: session)
                        .accessibilityIdentifier("metric.session")
                } else {
                    Picker("Range", selection: $range) {
                        ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .accessibilityIdentifier("metric.range")
                }

                if let resolvedAt = lagResolvedAt(snapshot) {
                    SnapshotLagNote(resolvedAt: resolvedAt)
                }

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
                    chartRow(snapshot, chart: chart)
                    chartControls(snapshot, chart: chart)
                    legend(snapshot)
                }
            } header: {
                Text(kind.title)
            } footer: {
                if !snapshot.points.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Drag across the chart to read each device's window median. The selection stays when you lift your finger; touch empty chart area, or Clear selection, to remove it. Tap a device below the chart to emphasise it; nothing is hidden.")
                        if !chart.bandPoints.isEmpty {
                            Text("The shaded band spans the highest and lowest device reading in each \(WindowLabel.length(chart.bucketSize)) window, coloured by that window's agreement. A wide band means your devices disagree at that moment. Lines and band break where a device, or a second device to compare with, did not report.")
                        }
                    }
                }
            }

            if let selectedPeriod {
                periodSection(selectedPeriod)
            }

            if !snapshot.perSourceStats.isEmpty {
                Section {
                    ForEach(snapshot.perSourceStats) { entry in
                        PerSourceStatsRow(kind: kind, entry: entry)
                    }
                } header: {
                    Text("Per device, \(periodPhrase(snapshot.period))")
                } footer: {
                    Text("These summarise one median per device per \(WindowLabel.length(snapshot.bucketSize)) window \u{2014} the same windows the chart draws. They are not raw sample statistics: readings older than the compaction age are stored as one median per window, so the original minimum, maximum and mean no longer exist. Where the original sample count was recorded it is shown separately; where it was not, it is shown as unknown.")
                }
            }

            if !snapshot.pairwiseAnalyses.isEmpty {
                Section {
                    ForEach(snapshot.pairwiseAnalyses) { analysis in
                        NavigationLink {
                            // Carries the session too, so a pair opened from a saved
                            // session analyses — and exports — the session's own span.
                            PairwiseAnalysisView(
                                kind: kind,
                                sourceAID: analysis.sourceA,
                                sourceBID: analysis.sourceB,
                                initialRange: range,
                                session: session
                            )
                        } label: {
                            PairwiseAnalysisRow(analysis: analysis)
                        }
                        .accessibilityIdentifier("metric.pair")
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

    // MARK: - Chart

    /// The zoomed chart once it has loaded for the current viewport; until then the last
    /// chart shown stays up, dimmed, rather than flashing empty. Each projection carries
    /// its own domains, so nothing is ever drawn outside the span it was read for.
    private func displayedChart(_ snapshot: MetricDetailSnapshot) -> MetricChartProjection {
        guard viewport != nil, let zoomSnapshot else { return snapshot.chart }
        return zoomSnapshot.chart
    }

    /// True while the chart shown is not yet the one for the current viewport.
    private var isZoomLoading: Bool {
        viewport != nil && zoomSnapshot?.viewport != viewport
    }

    /// A failed read of the zoomed span, which is reported rather than drawn as empty.
    private var zoomFailure: HealthStoreQueryError? {
        guard let zoomSnapshot, zoomSnapshot.viewport == viewport else { return nil }
        return zoomSnapshot.queryFailure
    }

    @ViewBuilder
    private func chartRow(_ snapshot: MetricDetailSnapshot, chart: MetricChartProjection) -> some View {
        if let failure = zoomFailure {
            HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                .accessibilityIdentifier("metric.zoomUnavailable")
        } else {
            MetricDetailChart(
                kind: kind,
                chart: chart,
                series: snapshot.series,
                emphasisedSourceID: emphasisedSourceID,
                selectedPeriod: selectedPeriod,
                isSelectingPeriod: isSelectingPeriod,
                selectedWindowStart: $selectedWindowStart,
                onSelectPeriod: { chosen in
                    selectedPeriod = chosen
                    isSelectingPeriod = false
                }
            )
            .frame(height: 240)
            .opacity(isZoomLoading ? 0.45 : 1)
            .overlay {
                if isZoomLoading {
                    ProgressView()
                        .accessibilityLabel("Loading the zoomed span")
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 12))
            .accessibilityIdentifier("metric.chart")
        }
    }

    /// Zoom, pan, and period selection, as buttons. Swift Charts' own scrolling would hide
    /// the selection callout (see `ChartViewport`), and buttons also reach VoiceOver.
    private func chartControls(_ snapshot: MetricDetailSnapshot, chart: MetricChartProjection) -> some View {
        let analysed = snapshot.interval
        let selected = chart.window(startingAt: selectedWindowStart)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                chartButton(
                    "Zoom out",
                    systemImage: "minus.magnifyingglass",
                    identifier: "metric.zoomOut",
                    enabled: viewport != nil
                ) {
                    zoomOut(analysed)
                }
                chartButton(
                    "Zoom in",
                    systemImage: "plus.magnifyingglass",
                    identifier: "metric.zoomIn",
                    enabled: ChartViewport.canZoomIn(from: viewport, period: analysed, kind: kind)
                ) {
                    zoomIn(analysed, chart: chart)
                }
                if let viewport {
                    chartButton(
                        "Show earlier",
                        systemImage: "chevron.left",
                        identifier: "metric.panEarlier",
                        enabled: viewport.canPan(.earlier, period: analysed, kind: kind)
                    ) {
                        pan(.earlier, analysed)
                    }
                    chartButton(
                        "Show later",
                        systemImage: "chevron.right",
                        identifier: "metric.panLater",
                        enabled: viewport.canPan(.later, period: analysed, kind: kind)
                    ) {
                        pan(.later, analysed)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    isSelectingPeriod.toggle()
                    if isSelectingPeriod { selectedWindowStart = nil }
                } label: {
                    Group {
                        if isSelectingPeriod {
                            Label("Cancel", systemImage: "xmark.circle")
                        } else {
                            Label("Select period", systemImage: "arrow.left.and.right.square")
                        }
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("metric.selectPeriod")
            }

            Text("Showing \(ChartViewport.bucketDescription(chart.bucketSize)), \(spanText(chart.interval))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("metric.bucket")

            if isSelectingPeriod {
                Text("Drag across the chart to choose a period, or use the span shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Use the span shown") {
                    selectedPeriod = ChartViewport.snappedPeriod(
                        from: chart.xDomain.lowerBound,
                        to: chart.xDomain.upperBound,
                        bucket: chart.bucketSize,
                        within: chart.xDomain
                    )
                    isSelectingPeriod = false
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .accessibilityIdentifier("metric.useVisibleSpan")
            } else if let selected {
                HStack {
                    Text("Selected: \(spanText(DateInterval(start: selected.start, duration: selected.duration)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Clear selection") { selectedWindowStart = nil }
                        .font(.caption)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("metric.clearSelection")
                }
            }
        }
        // Several controls share this row: without a borderless style, a tap anywhere in
        // a list row triggers its buttons together.
        .buttonStyle(.borderless)
    }

    private func chartButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }

    private func zoomIn(_ analysed: DateInterval, chart: MetricChartProjection) {
        // Towards the selected window when there is one, so zooming keeps it in view;
        // otherwise towards the newest drawn window, so a zoom lands on data rather than
        // on the empty middle of a long range.
        let anchor = (chart.window(startingAt: selectedWindowStart) ?? chart.windows.last)
            .map { $0.start.addingTimeInterval($0.duration / 2) }
        guard let next = ChartViewport.zoomedIn(from: viewport, period: analysed, kind: kind, toward: anchor) else { return }
        viewport = next
        selectedWindowStart = nil
    }

    private func zoomOut(_ analysed: DateInterval) {
        viewport = viewport?.zoomedOut(period: analysed, kind: kind)
        selectedWindowStart = nil
    }

    private func pan(_ direction: ChartViewport.PanDirection, _ analysed: DateInterval) {
        viewport = viewport?.panned(direction, period: analysed, kind: kind)
        selectedWindowStart = nil
    }

    private func resetChartInteraction() {
        selectedWindowStart = nil
        viewport = nil
        zoomSnapshot = nil
        isSelectingPeriod = false
        selectedPeriod = nil
    }

    private func loadZoom() async {
        guard let key = zoomLoadKey, let series = snapshot?.series else {
            zoomSnapshot = nil
            return
        }
        let wait = LiveReloadPolicy.delay(
            dataOnly: zoomLoadedKey.map { key.sameSelection(as: $0) } ?? false,
            elapsed: zoomLoadedAt.map { Date.now.timeIntervalSince($0) },
            minimumInterval: LiveReloadPolicy.minimumInterval(for: .fixed(key.viewport.visible))
        )
        try? await Task.sleep(for: .seconds(wait))
        guard !Task.isCancelled else { return }
        let resolved = MetricZoomSnapshot(
            store: model.store,
            kind: kind,
            viewport: key.viewport,
            includeEstimates: key.showEstimates,
            series: series
        )
        guard !Task.isCancelled, key == zoomLoadKey else { return }
        zoomSnapshot = resolved
        zoomLoadedKey = key
        zoomLoadedAt = .now
    }

    /// Says how old the drawn result is while newer readings wait for the next refresh:
    /// the whole period's, or the zoomed span's when the chart is zoomed.
    private func lagResolvedAt(_ snapshot: MetricDetailSnapshot) -> Date? {
        let token = model.store.changeToken
        if viewport != nil, let zoomSnapshot, zoomSnapshot.generation != token {
            return min(zoomSnapshot.resolvedAt, snapshot.generation != token ? snapshot.resolvedAt : .distantFuture)
        }
        return snapshot.generation != token ? snapshot.resolvedAt : nil
    }

    /// Legend entries come from the same `series` the chart scales use, so a label here can
    /// never name a different device than the line it points at. The symbol is spoken as
    /// well as drawn: a legend that only differs by colour is unusable to a reader who
    /// cannot distinguish the two colours. Each entry toggles emphasis for its device.
    private func legend(_ snapshot: MetricDetailSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendEntries(snapshot) }
            VStack(alignment: .leading, spacing: 0) { legendEntries(snapshot) }
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func legendEntries(_ snapshot: MetricDetailSnapshot) -> some View {
        ForEach(snapshot.series) { entry in
            let isEmphasised = emphasisedSourceID == entry.sourceID
            let isDimmed = emphasisedSourceID != nil && !isEmphasised
            Button {
                emphasisedSourceID = isEmphasised ? nil : entry.sourceID
            } label: {
                HStack(spacing: 5) {
                    // The same shape the chart plots, so the key works without colour.
                    SourceSymbolGlyph(symbol: entry.symbol, color: entry.color)
                    Text(entry.label)
                        .font(.caption2)
                        .fontWeight(isEmphasised ? .semibold : .regular)
                        .lineLimit(1)
                }
                .opacity(isDimmed ? 0.45 : 1)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityLabel("\(entry.label), \(entry.symbol.accessibilityName) marks")
            .accessibilityValue(isEmphasised ? "Emphasised" : "")
            .accessibilityHint("Emphasises this device on the chart and dims the others. Nothing is hidden.")
            .accessibilityAddTraits(isEmphasised ? .isSelected : [])
        }
        Spacer(minLength: 0)
    }

    // MARK: - Selected period

    @ViewBuilder
    private func periodSection(_ chosen: DateInterval) -> some View {
        Section {
            LabeledContent("Period") {
                Text(spanText(chosen))
            }
            if let evidence = periodEvidence, evidence.interval == chosen {
                if let failure = evidence.queryFailure {
                    HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                } else if evidence.analyses.isEmpty {
                    Text("Fewer than two devices reported \(kind.title.lowercased()) in this period, so there is nothing to compare.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(evidence.analyses) { analysis in
                        PairwiseAnalysisRow(analysis: analysis)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking this period\u{2026}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                savingPeriod = true
            } label: {
                Label("Save as session\u{2026}", systemImage: "bookmark")
            }
            .accessibilityIdentifier("metric.savePeriod")
            Button {
                selectedPeriod = nil
            } label: {
                Label("Clear period", systemImage: "xmark.circle")
            }
            .accessibilityIdentifier("metric.clearPeriod")
        } header: {
            Text("Selected period")
                .accessibilityIdentifier("metric.period")
        } footer: {
            Text("This is the evidence for exactly this period, computed the way a saved session over the same seconds is computed. Saving keeps these bounds, this metric, and the devices currently included in your comparison.")
        }
    }

    private func loadPeriodEvidence() async {
        guard let key = periodLoadKey else {
            periodEvidence = nil
            return
        }
        let wait = LiveReloadPolicy.delay(
            dataOnly: periodLoadedKey.map { key.sameSelection(as: $0) } ?? false,
            elapsed: periodLoadedAt.map { Date.now.timeIntervalSince($0) },
            minimumInterval: LiveReloadPolicy.minimumInterval(for: .fixed(key.period))
        )
        try? await Task.sleep(for: .seconds(wait))
        guard !Task.isCancelled else { return }
        let resolved = MetricPeriodEvidence(store: model.store, kind: kind, interval: key.period)
        guard !Task.isCancelled, key == periodLoadKey else { return }
        periodEvidence = resolved
        periodLoadedKey = key
        periodLoadedAt = .now
    }

    // MARK: - Formatting

    /// "3 Sep 2026 at 10:00 – 11:00", with the end's date only when it differs.
    private func spanText(_ span: DateInterval) -> String {
        let start = span.start.formatted(date: .abbreviated, time: .shortened)
        let sameDay = Calendar.current.isDate(span.start, inSameDayAs: span.end)
        let end = span.end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return "\(start) \u{2013} \(end)"
    }

    /// "last 24 hours", or "saved session" for a fixed span. A formatted date is not
    /// lowercased: that would mangle month names in some languages.
    private func periodPhrase(_ period: ComparisonPeriod) -> String {
        period.rollingRange.map { $0.title.lowercased() } ?? "saved session"
    }
}
