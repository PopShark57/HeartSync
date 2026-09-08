import SwiftUI

/// Comparison entry point. Metrics remain discoverable even when their sources do not
/// share aligned timestamps; evidence state is resolved one device pair at a time.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .day
    /// Bumped by the retry button. Reading it here makes the snapshot depend on it, so a
    /// retry re-runs the query without touching or resetting any stored data.
    @State private var retryToken = 0

    var body: some View {
        // Read so the snapshot below depends on it: tapping Try again re-evaluates the
        // body and re-runs the query. Not dead code — deleting it disables the retry.
        let _ = retryToken
        // Resolved once per update and handed down. Every subview reading its own
        // computed property would re-window the whole archive, and `TimeRange.interval`
        // is relative to `.now`, so repeated calls would also compare slightly different
        // spans within a single frame.
        let snapshot = ComparisonSnapshot(
            store: model.store,
            range: range,
            alertThreshold: model.settings.snapshot.discrepancyThreshold
        )

        NavigationStack {
            // The range control lives outside the result content on purpose. When a narrow
            // range holds nothing comparable, the empty state tells the user to widen the
            // range \u{2014} so the control that widens it has to still be on screen.
            List {
                Section {
                    Picker("Range", selection: $range) {
                        ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .accessibilityIdentifier("compare.range")
                }

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
                            NavigationLink {
                                MetricDetailView(kind: kind, initialRange: range)
                            } label: {
                                ComparisonSummaryRow(
                                    kind: kind,
                                    analyses: snapshot.analyses(for: kind),
                                    sourceIDs: snapshot.sourceIDs(for: kind)
                                )
                            }
                        }
                    }

                    Section {
                        evidenceOverview(snapshot)
                    } header: {
                        Text("Evidence overview")
                            .accessibilityIdentifier("compare.root")
                    } footer: {
                        Text("HeartSync uses median values in epoch-aligned windows and excludes estimates. Ready analyses use mean bias and 95% limits of agreement; insufficient overlap is never treated as agreement.")
                    }
                }
            }
            .navigationTitle("Compare")
        }
    }

    /// Distinguishes an empty install from a range that happens to hold nothing, because
    /// only one of those is fixed by widening the range.
    @ViewBuilder
    private func emptyState(_ reason: ComparisonEmptyReason) -> some View {
        let wider = range.wider
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
                Text("\(snapshot.overview.readyCount) ready \(snapshot.overview.readyCount == 1 ? "pair" : "pairs") assessed across \(range.title.lowercased()).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !snapshot.incomplete.isEmpty {
                    Text("\(snapshot.incomplete.count) additional \(snapshot.incomplete.count == 1 ? "pair still needs" : "pairs still need") more overlap; no conclusion is made for those pairs.")
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
                    "\(snapshot.overview.suppressedCount) further \(snapshot.overview.suppressedCount == 1 ? "pair is" : "pairs are") outside tolerance but below your alert level. Change “Flag disagreements at” in Settings to list \(snapshot.overview.suppressedCount == 1 ? "it" : "them").",
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

    private func incompleteEvidenceSummary(_ items: [PairwiseAnalysis]) -> String {
        let noOverlap = items.filter {
            if case .noOverlap = $0.state { return true }
            return false
        }.count
        let collecting = items.count - noOverlap
        switch (noOverlap, collecting) {
        case (0, 0): return "No eligible device pairs are available."
        case (0, let count): return "\(count) \(count == 1 ? "pair is" : "pairs are") collecting paired windows; none has reached the five-window minimum."
        case (let count, 0): return "\(count) \(count == 1 ? "pair has" : "pairs have") no overlapping windows."
        case (let noOverlap, let collecting): return "\(collecting) \(collecting == 1 ? "pair is" : "pairs are") collecting evidence, and \(noOverlap) \(noOverlap == 1 ? "pair has" : "pairs have") no overlapping windows."
        }
    }
}

/// Why Compare has nothing to list. These are genuinely different situations and only two
/// of them are improved by widening the range, so they must not share one message.
enum ComparisonEmptyReason: Equatable, Sendable {
    /// No readings are stored at all: a new install, or history that was deleted.
    case noStoredData
    /// Readings exist, but none of them fall inside the selected range.
    case noDataInRange
    /// Exactly one source reported in this range, so no pair can exist.
    case singleSourceInRange
    /// Two or more sources reported, but no single metric was measured by two of them.
    case noSharedMetric

    /// Chooses the reason from facts the snapshot already resolved.
    ///
    /// Kept separate from the view so the distinction between "you have no data",
    /// "you have data but not here", and "you have one device" is unit-testable without
    /// rendering SwiftUI.
    ///
    /// - Parameters:
    ///   - comparableMetricCount: metrics measured by two or more sources in the range.
    ///   - sourcesInRange: distinct non-estimated sources reporting anything in the range.
    ///   - hasStoredReadings: whether the database holds any readings at all.
    static func resolve(
        comparableMetricCount: Int,
        sourcesInRange: Int,
        hasStoredReadings: Bool
    ) -> ComparisonEmptyReason {
        if comparableMetricCount > 0 { return .noSharedMetric }
        if sourcesInRange >= 2 { return .noSharedMetric }
        if sourcesInRange == 1 { return .singleSourceInRange }
        return hasStoredReadings ? .noDataInRange : .noStoredData
    }

    var systemImage: String {
        switch self {
        case .noStoredData:        "tray"
        case .noDataInRange:       "clock.arrow.circlepath"
        case .singleSourceInRange: "plus.circle"
        case .noSharedMetric:      "chart.xyaxis.line"
        }
    }

    var title: String {
        switch self {
        case .noStoredData:        "No measurements yet"
        case .noDataInRange:       "No measurements in this range"
        case .singleSourceInRange: "Only one device reported"
        case .noSharedMetric:      "No metric measured by two devices"
        }
    }

    /// Widening cannot conjure data that was never stored, and it cannot add a second
    /// device, so those two cases do not offer the action.
    var suggestsWidening: Bool {
        switch self {
        case .noStoredData:                             false
        case .noDataInRange, .singleSourceInRange, .noSharedMetric: true
        }
    }

    func message(range: TimeRange, wider: TimeRange?) -> String {
        let widerHint = wider.map { " Try \($0.title.lowercased())." } ?? ""
        switch self {
        case .noStoredData:
            return "Connect a device on the Devices tab, or allow Apple Health access in Settings. Comparison needs measured data from two or more devices for the same metric."
        case .noDataInRange:
            return "Measurements are stored, but none of them fall in \(range.title.lowercased()).\(widerHint)"
        case .singleSourceInRange:
            return "Only one device reported in \(range.title.lowercased()). Comparison needs two.\(widerHint)"
        case .noSharedMetric:
            return "Two or more devices reported in \(range.title.lowercased()), but no single metric was measured by two of them. Their timestamps do not need to overlap \u{2014} they do need to measure the same thing.\(widerHint)"
        }
    }
}

/// One resolved pass over the store for a time range.
///
/// Building the metric list, the per-metric pairs, and the overview from a single read
/// keeps the screen O(readings) instead of O(readings × metrics × subviews), and makes
/// every row on screen describe the same instant.
@MainActor
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

    private let analysesByKind: [MetricKind: [PairwiseAnalysis]]
    private let sourceIDsByKind: [MetricKind: [String]]

    init(store: HealthStore, range: TimeRange, alertThreshold: DiscrepancySeverity) {
        let interval = range.interval
        // Estimates never participate in a device comparison, so they are dropped before
        // the metric list is built as well as inside the engine — otherwise a metric with
        // one real device plus the estimate source would look comparable.
        let outcome = store.readingsOutcome(in: interval)
        self.queryFailure = outcome.error
        let readings = outcome.valueOrEmpty.filter { $0.provenance != .estimated }

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
        self.overview = PairwiseEvidenceOverview(analyses: analyses, alertThreshold: alertThreshold)
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
                    Text("\(sourceIDs.count) devices · \(analyses.count) \(analyses.count == 1 ? "pair" : "pairs")")
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
