import SwiftUI

/// Comparison entry point. Metrics remain discoverable even when their sources do not
/// share aligned timestamps; evidence state is resolved one device pair at a time.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .day
    /// Bumped by the retry button so the load key changes and the query runs again. It
    /// re-reads only; nothing here resets or reimports stored data.
    @State private var retryToken = 0
    @State private var snapshot: ComparisonSnapshot?
    /// Non-nil when the user has opened a saved session: the analysed span is then fixed
    /// rather than sliding with the clock.
    @State private var activeSession: ComparisonSession?
    @State private var showingSessions = false
    @State private var savingSession = false
    @State private var revisitNotice: String?
    /// The metric shown in the detail column of the regular-width split view.
    @State private var selectedMetric: MetricKind?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The span actually analysed. A saved session pins it; otherwise it rolls.
    private var period: ComparisonPeriod {
        activeSession.map { .fixed($0.interval) } ?? .rolling(range)
    }

    /// When the last snapshot load finished, and for which key. A reload caused only by new
    /// data is coalesced against these; one caused by the user is not.
    @State private var lastLoadedKey: LoadKey?
    @State private var lastLoadedAt: Date?

    /// Everything a snapshot depends on. When this changes the previous load is cancelled
    /// and a new one starts; when it has not changed, an unrelated view update reuses the
    /// snapshot instead of re-querying and re-windowing the whole range.
    private struct LoadKey: Hashable {
        var generation: Int
        var range: TimeRange
        var alertThreshold: DiscrepancySeverity
        var sessionID: UUID?
        var enabledSourceIDs: [String]
        var hiddenSourceIDs: [String]
        var retryToken: Int

        /// True when `other` asks the same question and only the data may have changed.
        func sameSelection(as other: LoadKey) -> Bool {
            var aligned = other
            aligned.generation = generation
            return aligned == self
        }
    }

    /// True while the shown snapshot answers a different question (range, session, sources,
    /// threshold) than the one now asked. New data alone is not a different question; the
    /// lag note covers that.
    private var isShowingPreviousSelection: Bool {
        guard snapshot != nil, let lastLoadedKey else { return false }
        return !loadKey.sameSelection(as: lastLoadedKey)
    }

    private var loadKey: LoadKey {
        LoadKey(
            generation: model.store.changeToken,
            range: range,
            alertThreshold: model.settings.snapshot.discrepancyThreshold,
            sessionID: activeSession?.id,
            enabledSourceIDs: model.store.enabledSources.map(\.id).sorted(),
            hiddenSourceIDs: model.settings.snapshot.comparisonHidden.sorted(),
            retryToken: retryToken
        )
    }

    var body: some View {
        // A regular width (iPad, or a large iPhone in landscape) shows metrics beside the
        // selected metric's detail. A compact width pushes, as before.
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                compareList(selection: $selectedMetric)
            } detail: {
                NavigationStack {
                    if let selectedMetric {
                        MetricDetailView(kind: selectedMetric, initialRange: range, session: activeSession)
                            // A different metric, range, or session is a new detail screen,
                            // not an update of the old one's interaction state.
                            .id(DetailIdentity(kind: selectedMetric, range: range, sessionID: activeSession?.id))
                    } else {
                        ContentUnavailableView(
                            "Choose a metric",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Its history, device agreement, and pairs appear here.")
                        )
                    }
                }
            }
        } else {
            NavigationStack {
                compareList(selection: nil)
            }
        }
    }

    private struct DetailIdentity: Hashable {
        var kind: MetricKind
        var range: TimeRange
        var sessionID: UUID?
    }

    private func compareList(selection: Binding<MetricKind?>?) -> some View {
        // The range control lives outside the result content on purpose. When a narrow
        // range holds nothing comparable, the empty state tells the user to widen the
        // range \u{2014} so the control that widens it has to still be on screen.
        List(selection: selection) {
            Section {
                if let session = activeSession {
                    sessionBanner(session)
                } else {
                    Picker("Range", selection: $range) {
                        ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .accessibilityIdentifier("compare.range")
                }
                if isShowingPreviousSelection {
                    // The results below answer the previous question until the new
                    // snapshot lands; say so instead of letting them pass as current.
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Updating for the new selection\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("compare.updating")
                } else if let snapshot, snapshot.generation != model.store.changeToken {
                    SnapshotLagNote(resolvedAt: snapshot.resolvedAt)
                }
            }

            if let snapshot {
                content(snapshot)
                    // Dimmed and inert while stale, so a tap cannot open the old range.
                    .opacity(isShowingPreviousSelection ? 0.45 : 1)
                    .disabled(isShowingPreviousSelection)
                    .accessibilityHidden(isShowingPreviousSelection)
            } else {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading comparison\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("compare.loading")
                }
            }
        }
        .navigationTitle("Compare")
        .toolbarTitleDisplayMode(.inlineLarge)
        .heartSyncScreenBackground()
        .toolbar {
            // Both menus trail: an inline-large title owns the leading edge, and a leading
            // item beside it is not shown.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Saved sessions\u{2026}", systemImage: "bookmark") { showingSessions = true }
                    Button("Save this period\u{2026}", systemImage: "bookmark.square") { savingSession = true }
                    if activeSession != nil {
                        Button("Back to rolling range", systemImage: "clock.arrow.circlepath") {
                            activeSession = nil
                            revisitNotice = nil
                        }
                    }
                } label: {
                    Label("Sessions", systemImage: "bookmark")
                }
                .accessibilityIdentifier("compare.sessions")
            }
            ToolbarItem(placement: .topBarTrailing) { sourceSelectionMenu }
        }
        .sheet(isPresented: $showingSessions) {
            ComparisonSessionsView { session in openSession(session) }
        }
        .sheet(isPresented: $savingSession) {
            SaveComparisonSessionView(
                start: period.interval.start,
                end: period.interval.end
            )
        }
        // `.task(id:)` cancels the in-flight load whenever the key changes, so a slow
        // month-range load cannot land after the user has switched back to an hour.
        .task(id: loadKey) {
            let key = loadKey
            // One frame of slack for a changed question, so dragging across the range
            // picker starts a single load. New data alone waits out the live-reload
            // interval instead: a Bluetooth strap bumps the key once a second, and a
            // month-range comparison must not be re-read that often.
            let wait = LiveReloadPolicy.delay(
                dataOnly: lastLoadedKey.map { key.sameSelection(as: $0) } ?? false,
                elapsed: lastLoadedAt.map { Date.now.timeIntervalSince($0) },
                minimumInterval: LiveReloadPolicy.minimumInterval(for: period)
            )
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            // Read and analysed off the main actor; only the result is published here.
            let history = model.store.history
            let period = period
            let threshold = model.settings.snapshot.discrepancyThreshold
            let hidden = model.settings.snapshot.comparisonHidden
            let resolved = await HealthHistory.offMain {
                ComparisonSnapshot(
                    history: history,
                    period: period,
                    alertThreshold: threshold,
                    hiddenSourceIDs: hidden
                )
            }
            // Rejects a late result: the selection may have moved on while this ran.
            guard !Task.isCancelled, key == loadKey else { return }
            snapshot = resolved
            lastLoadedKey = key
            lastLoadedAt = .now
        }
    }

    @ViewBuilder
    private func content(_ snapshot: ComparisonSnapshot) -> some View {
        Group {
                if let failure = snapshot.queryFailure {
                    Section {
                        HistoryUnavailableView(error: failure) { retryToken &+= 1 }
                            .accessibilityIdentifier("compare.unavailable")
                    }
                } else if snapshot.metrics.isEmpty {
                    Section {
                        emptyState(snapshot.emptyReason)
                            .accessibilityIdentifier("compare.empty")
                    }
                } else {
                    Section("Metrics measured by more than one device") {
                        ForEach(snapshot.metrics) { kind in
                            let row = ComparisonSummaryRow(
                                kind: kind,
                                analyses: snapshot.analyses(for: kind),
                                sourceIDs: snapshot.sourceIDs(for: kind)
                            )
                            if horizontalSizeClass == .regular {
                                // Selects into the split view's detail column.
                                NavigationLink(value: kind) { row }
                            } else {
                                NavigationLink {
                                    // The session, not only the picker value: with a session
                                    // open, detail must analyse the session's exact seconds.
                                    MetricDetailView(kind: kind, initialRange: range, session: activeSession)
                                } label: {
                                    row
                                }
                            }
                        }
                    }

                    Section {
                        evidenceOverview(snapshot)
                    } header: {
                        Text("Evidence overview")
                            .accessibilityIdentifier("compare.root")
                    } footer: {
                        Text(overviewFooter(snapshot))
                    }
                }
        }
    }

    /// Shows that a fixed span is in force, and whether the data behind it has moved.
    private func sessionBanner(_ session: ComparisonSession) -> some View {
        ComparisonSessionBanner(session: session, revisitNotice: revisitNotice)
            .accessibilityIdentifier("compare.session")
    }

    /// Opens a saved session and discloses what has changed since it was last viewed.
    private func openSession(_ session: ComparisonSession) {
        activeSession = session
        revisitNotice = nil
        Task {
            // Counted from the same fixed interval the analysis uses, restricted to the
            // session's own sources and metric, so the disclosure describes what the session
            // compares rather than every device in the database. Counted in SQL: the
            // readings themselves are not needed.
            let outcome = model.store.periodSummaryOutcome(
                interval: session.interval,
                sourceIDs: Set(session.sourceIDs),
                kind: session.metric
            )
            guard let summary = outcome.value else { return }
            revisitNotice = session.revisitDisclosure(
                currentReadingCount: summary.count,
                currentFingerprint: summary.fingerprint
            )
            await model.sessions.noteViewed(
                id: session.id,
                readingCount: summary.count,
                fingerprint: summary.fingerprint
            )
        }
    }

    /// Chooses which sources this comparison uses, without touching collection.
    ///
    /// Deliberately separate from Pause on the Devices tab, which disconnects the
    /// peripheral and stops it recording. Hiding a noisy ring here changes this screen
    /// only: the device stays connected and its history is untouched, so the choice is
    /// free to make and free to undo.
    @ViewBuilder
    private var sourceSelectionMenu: some View {
        @Bindable var settings = model.settings
        let sources = model.store.enabledSources
        Menu {
            if sources.isEmpty {
                Text("No collecting devices yet")
            } else {
                ForEach(sources) { source in
                    let hidden = settings.snapshot.comparisonHidden.contains(source.id)
                    Button {
                        settings.snapshot.setComparisonHidden(!hidden, forSource: source.id)
                    } label: {
                        Label(source.displayName, systemImage: hidden ? "circle" : "checkmark.circle.fill")
                    }
                }
                if !settings.snapshot.comparisonHidden.isEmpty {
                    Divider()
                    Button("Show all in comparison") {
                        settings.snapshot.comparisonHiddenSourceIDs = nil
                    }
                }
            }
            Divider()
            Text("Hiding a device here does not disconnect it or delete its data.")
        } label: {
            Label("Sources", systemImage: hiddenCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("compare.sources")
        .accessibilityLabel(
            hiddenCount == 0
                ? "Comparison sources, all included"
                : "Comparison sources, \(hiddenCount) hidden"
        )
    }

    private var hiddenCount: Int {
        let enabled = Set(model.store.enabledSources.map(\.id))
        return model.settings.snapshot.comparisonHidden.intersection(enabled).count
    }

    /// Distinguishes an empty install from a range that happens to hold nothing, because
    /// only one of those is fixed by widening the range.
    @ViewBuilder
    private func emptyState(_ reason: ComparisonEmptyReason) -> some View {
        // Widening is only offered for a rolling range. A saved session's span is fixed by
        // definition, so silently widening it would analyse a different period.
        let wider = activeSession == nil ? range.wider : nil
        EmptyStateView(
            systemImage: reason.systemImage,
            title: reason.title,
            message: reason.message(range: range, wider: wider),
            actionTitle: reason.suggestsWidening ? wider.map { "Show \($0.title.lowercased())" } : nil,
            action: reason.suggestsWidening ? wider.map { next in { range = next } } : nil
        )
    }

    @ViewBuilder
    private func evidenceOverview(_ snapshot: ComparisonSnapshot) -> some View {
        switch snapshot.overview.status {
        case .insufficientEvidence:
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not enough overlapping evidence")
                        .font(.subheadline.weight(.semibold))
                    Text(incompleteEvidenceSummary(snapshot.incomplete))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "hourglass").foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)

        case .allReadyPairsWithinTolerance:
            VStack(alignment: .leading, spacing: 5) {
                Label(
                    "Every device pair with enough evidence agrees within tolerance.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .font(.subheadline.weight(.semibold))
                // Names the span actually analysed: with a session open that is the saved
                // period, not the rolling preset the picker would otherwise imply.
                Text(String(
                    localized: "compare.summary.ready",
                    defaultValue: "\(snapshot.overview.readyCount) ready pairs assessed across \(period.title.lowercased()).",
                    comment: "Compare summary. The first argument is how many device pairs have enough evidence, the second the analysed period in lower case."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !snapshot.incomplete.isEmpty {
                    Text(String(
                        localized: "compare.summary.additionalIncomplete",
                        defaultValue: "\(snapshot.incomplete.count) additional pairs still need more overlap; no conclusion is made for those pairs.",
                        comment: "Compare summary. The argument is how many device pairs lack enough overlapping windows."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

        case .readyPairOutsideTolerance:
            ForEach(snapshot.flagged) { analysis in
                ReadyPairFindingRow(analysis: analysis)
            }
            // A pair the alert preference filters out is still a pair that disagrees, so
            // it is counted here rather than being silently folded into a green result.
            if snapshot.overview.suppressedCount > 0 {
                Label(
                    String(
                        localized: "compare.summary.suppressed",
                        defaultValue: "\(snapshot.overview.suppressedCount) further pairs are outside tolerance but below your alert level. Change \u{201C}Flag disagreements at\u{201D} in Settings to list them.",
                        comment: "Compare summary. The argument is how many pairs are outside tolerance but hidden by the alert-level setting. The quoted words are the name of a Settings control."
                    ),
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !snapshot.incomplete.isEmpty {
                Label(incompleteEvidenceSummary(snapshot.incomplete), systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Says plainly when some of the listed pairs are one device seen twice.
    ///
    /// Two paths from one ring disagreeing is a real sync problem and stays inspectable,
    /// but it is not two devices corroborating each other, and the overview must not read
    /// as though it were.
    private func overviewFooter(_ snapshot: ComparisonSnapshot) -> String {
        let base = "HeartSync uses median values in epoch-aligned windows and excludes estimates. Ready analyses use mean bias and 95% limits of agreement; insufficient overlap is never treated as agreement."
        var extra: [String] = []
        if snapshot.overview.sameDevicePairCount > 0 {
            let count = snapshot.overview.sameDevicePairCount
            extra.append(String(
                localized: "compare.footer.sameDevice",
                defaultValue: "\(count) of these pairs are two paths to the same device rather than two independent devices; they are useful for spotting a sync problem but do not corroborate a measurement.",
                comment: "Compare footer. The argument is how many listed pairs are the same physical device seen through two transports."
            ))
        }
        if hiddenCount > 0 {
            extra.append(String(
                localized: "compare.footer.hidden",
                defaultValue: "\(hiddenCount) devices are hidden from this comparison. They are still connected and still recording.",
                comment: "Compare footer. The argument is how many devices the user hid from comparisons."
            ))
        }
        return ([base] + extra).joined(separator: " ")
    }

    private func incompleteEvidenceSummary(_ items: [PairwiseAnalysis]) -> String {
        let noOverlap = items.filter {
            if case .noOverlap = $0.state { return true }
            return false
        }.count
        let collecting = items.count - noOverlap
        switch (noOverlap, collecting) {
        case (0, 0):
            return String(localized: "compare.incomplete.none", defaultValue: "No eligible device pairs are available.", comment: "Compare summary when no device pair can be assessed")
        case (0, let count):
            return String(
                localized: "compare.incomplete.collecting",
                defaultValue: "\(count) pairs are collecting paired windows; none has reached the five-window minimum.",
                comment: "Compare summary. The argument is how many pairs are still collecting paired windows."
            )
        case (let count, 0):
            return String(
                localized: "compare.incomplete.noOverlap",
                defaultValue: "\(count) pairs have no overlapping windows.",
                comment: "Compare summary. The argument is how many pairs have no overlapping windows."
            )
        case (let noOverlap, let collecting):
            // Two counts, each agreeing with its own noun, so two sentences rather than one.
            return String(
                localized: "compare.incomplete.collectingShort",
                defaultValue: "\(collecting) pairs are collecting evidence.",
                comment: "First half of a Compare summary. The argument is how many pairs are still collecting evidence."
            ) + " " + String(
                localized: "compare.incomplete.noOverlapShort",
                defaultValue: "\(noOverlap) pairs have no overlapping windows.",
                comment: "Second half of a Compare summary. The argument is how many pairs have no overlapping windows."
            )
        }
    }
}

/// One resolved pass over the store for a time range.
///
/// Building the metric list, the per-metric pairs, and the overview from a single read
/// keeps the screen O(readings) instead of O(readings × metrics × subviews), and makes
/// every row on screen describe the same instant.
///
/// Built from a `HealthHistory`, off the main actor.
private struct ComparisonSnapshot {
    let metrics: [MetricKind]
    /// Why `metrics` is empty. Only meaningful when it is.
    let emptyReason: ComparisonEmptyReason
    /// Set when the history query itself failed. An empty comparison caused by a failed
    /// read must never be presented as "you have no data"; it is a retryable error.
    let queryFailure: HealthStoreQueryError?
    let overview: PairwiseEvidenceOverview
    /// Ready pairs outside tolerance and at or above the user's alert threshold, worst first.
    let flagged: [PairwiseAnalysis]
    /// Pairs with no overlap or too few paired windows, in any metric.
    let incomplete: [PairwiseAnalysis]

    /// The span actually analysed, so callers can report it rather than re-deriving it.
    let interval: DateInterval

    /// Store generation this snapshot read, and when, so a coalesced live reload can say
    /// how far behind the newest reading it is.
    let generation: Int
    let resolvedAt: Date

    /// Pairs confirmed to be two transports of one device. Surfaced at this level, not
    /// only in pairwise detail, so the overview cannot imply independent corroboration.
    let sameDevicePairKeys: Set<String>

    private let analysesByKind: [MetricKind: [PairwiseAnalysis]]
    private let sourceIDsByKind: [MetricKind: [String]]

    init(
        history store: HealthHistory,
        period: ComparisonPeriod,
        alertThreshold: DiscrepancySeverity,
        hiddenSourceIDs: Set<String>
    ) {
        // Resolved once. A fixed period returns the same seconds on every read, which is
        // what makes a saved session re-openable; a rolling one resolves against `.now`.
        let interval = period.interval
        self.interval = interval
        self.generation = store.changeToken
        self.resolvedAt = .now
        // Estimates never participate in a device comparison, so they are dropped before
        // the metric list is built as well as inside the engine — otherwise a metric with
        // one real device plus the estimate source would look comparable.
        //
        // Comparison-only hiding. It filters this screen and nothing else: the source stays
        // connected, keeps recording, and keeps its history. The filter is in the query, so
        // a hidden or paused device's rows are never decoded.
        let included = Set(store.enabledSources.map(\.id)).subtracting(hiddenSourceIDs)
        let outcome = store.query { try $0.readings(range: interval, sourceIDs: included) }
        self.queryFailure = outcome.error
        // Interval averages (a night's mean) are never windowed either, so a device that
        // offers only those for a metric does not make that metric look comparable.
        let readings = outcome.valueOrEmpty.filter {
            $0.provenance != .estimated && !$0.isIntervalAverage
        }

        var sourceIDs: [MetricKind: Set<String>] = [:]
        for reading in readings {
            sourceIDs[reading.kind, default: []].insert(reading.sourceID)
        }
        self.sourceIDsByKind = sourceIDs.mapValues { $0.sorted() }
        self.metrics = MetricKind.allCases.filter { (sourceIDs[$0]?.count ?? 0) >= 2 }

        // Resolved from the same read as the metric list. `readingCount` is a COUNT(*) on
        // the indexed table, not a materialization of the history, and it is only consulted
        // when the range itself came back empty.
        let sourcesInRange = Set(readings.map(\.sourceID)).count
        // Only consulted when the range came back empty, and only trusted when it
        // succeeded: a failed COUNT(*) must not be read as "this install is empty".
        let storedCount = sourcesInRange > 0 ? nil : store.readingCountOutcome.value
        self.emptyReason = ComparisonEmptyReason.resolve(
            comparableMetricCount: self.metrics.count,
            sourcesInRange: sourcesInRange,
            hasStoredReadings: sourcesInRange > 0 || (storedCount ?? 0) > 0
        )

        let analyses = ComparisonEngine.allPairwiseAnalyses(from: readings, range: interval)
        self.analysesByKind = Dictionary(grouping: analyses, by: \.kind)
        let sameDevice = PairwiseEvidenceOverview.sameDevicePairKeys(
            analyses: analyses,
            sources: store.sources
        )
        self.sameDevicePairKeys = sameDevice
        self.overview = PairwiseEvidenceOverview(
            analyses: analyses,
            alertThreshold: alertThreshold,
            sameDevicePairs: sameDevice
        )
        self.incomplete = analyses.filter { $0.statistics == nil }
        self.flagged = analyses
            .filter { analysis in
                guard let statistics = analysis.statistics else { return false }
                return statistics.severity != .agreeing && statistics.severity >= alertThreshold
            }
            .sorted { lhs, rhs in
                guard let left = lhs.statistics, let right = rhs.statistics else { return false }
                if left.severity != right.severity { return left.severity > right.severity }
                return left.meanAbsoluteDifference > right.meanAbsoluteDifference
            }
    }

    func analyses(for kind: MetricKind) -> [PairwiseAnalysis] { analysesByKind[kind] ?? [] }
    func sourceIDs(for kind: MetricKind) -> [String] { sourceIDsByKind[kind] ?? [] }
}

private struct ComparisonSummaryRow: View {
    @Environment(AppModel.self) private var model
    var kind: MetricKind
    var analyses: [PairwiseAnalysis]
    var sourceIDs: [String]

    var body: some View {
        let ready = analyses.compactMap(\.statistics)
        let worst = ready.map(\.severity).max()

        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(kind.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    ForEach(sourceIDs, id: \.self) { id in
                        SourceDot(color: model.store.source(id: id)?.color ?? .gray, size: 7)
                    }
                    Text(String(
                        localized: "compare.row.devices",
                        defaultValue: "\(sourceIDs.count) devices",
                        comment: "Compare row subtitle, first half. The argument is how many devices report the metric."
                    ) + " \u{00B7} " + String(
                        localized: "compare.row.pairs",
                        defaultValue: "\(analyses.count) pairs",
                        comment: "Compare row subtitle, second half. The argument is how many device pairs they form."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let worst {
                    Text(worst.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(worst.tint)
                    Text("\(ready.count) ready").font(.caption2).foregroundStyle(.secondary)
                } else if let progress = bestCollectingProgress {
                    Text("\(progress.current) of \(progress.required)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                    Text("paired windows").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No overlap").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("no conclusion").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var bestCollectingProgress: (current: Int, required: Int)? {
        analyses.compactMap { analysis in
            if case let .collecting(current, required) = analysis.state { return (current, required) }
            return nil
        }.max { $0.current < $1.current }
    }
}

private struct ReadyPairFindingRow: View {
    @Environment(AppModel.self) private var model
    var analysis: PairwiseAnalysis

    var body: some View {
        if let statistics = analysis.statistics {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: statistics.severity.systemImage)
                        .foregroundStyle(statistics.severity.tint)
                        .font(.caption)
                    Text(analysis.kind.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(analysis.pairedWindowCount) windows")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(explanation(statistics))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    sourceChip(analysis.sourceA)
                    Text("A − B").font(.caption2).foregroundStyle(.tertiary)
                    sourceChip(analysis.sourceB)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sourceChip(_ id: String) -> some View {
        let source = model.store.source(id: id)
        return HStack(spacing: 5) {
            SourceDot(color: source?.color ?? .gray, size: 7)
            Text(source?.displayName ?? id).font(.caption).lineLimit(1)
        }
    }

    private func explanation(_ statistics: PairwiseSummaryStatistics) -> String {
        let nameA = model.store.displayName(forSource: analysis.sourceA)
        let nameB = model.store.displayName(forSource: analysis.sourceB)
        switch statistics.classification {
        case .noApparentDifference:
            return "This ready pair is within the fixed tolerance for the selected observations."
        case .systematicBias:
            let higher = statistics.meanBias >= 0 ? nameA : nameB
            let lower = statistics.meanBias >= 0 ? nameB : nameA
            return "\(higher) reads \(analysis.kind.formatWithUnit(abs(statistics.meanBias))) higher than \(lower) on average. This is a descriptive offset, not proof that either device is correct."
        case .measurementNoise:
            return "The pair differs by \(analysis.kind.formatWithUnit(statistics.meanAbsoluteDifference)) on average, but the direction varies between windows."
        }
    }
}
