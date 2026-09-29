import SwiftUI

// MARK: - Rows

/// One device's window summary.
///
/// The labels are load-bearing. "Samples" over a row count read as "this many measurements
/// were taken", which stopped being true the moment compaction replaced a window's raw rows
/// with one median. These say "windows", keep the original sample count in its own row, and
/// say "unknown" where the archive genuinely no longer knows.
struct PerSourceStatsRow: View {
    var kind: MetricKind
    var entry: SourceStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SourceDot(color: entry.source.color)
                Text(entry.source.displayName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(kind.formatWithUnit(entry.typicalWindowValue))
                    .font(.subheadline.monospacedDigit())
            }
            HStack(spacing: 14) {
                statistic("Lowest window", kind.format(entry.lowestWindowValue))
                statistic("Highest window", kind.format(entry.highestWindowValue))
                statistic("Windows", "\(entry.windowCount)")
                statistic("Original samples", originalSampleText)
                Spacer()
            }
            if entry.includesCompactedWindows {
                Text(compactionNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var originalSampleText: String {
        entry.originalSampleCount.map(String.init) ?? "unknown"
    }

    private var compactionNote: String {
        entry.originalSampleCount == nil
            ? "Includes compacted window medians. Some original sample counts were never recorded, so the number of measurements behind these windows is unknown."
            : "Includes compacted window medians: the original samples are gone and only their count and spread were kept."
    }

    /// Spells out what each number is, because the shortened on-screen labels rely on
    /// column position that VoiceOver does not convey.
    private var accessibilityDescription: String {
        let windows = String(
            localized: "detail.spoken.windows",
            defaultValue: "\(entry.windowCount) windows",
            comment: "Spoken description of a device row. The argument is how many comparison windows it covers."
        )
        let base = String(
            localized: "detail.spoken.base",
            defaultValue: "\(entry.source.displayName), typical \(kind.formatWithUnit(entry.typicalWindowValue)) across \(windows), lowest window median \(kind.format(entry.lowestWindowValue)), highest window median \(kind.format(entry.highestWindowValue))",
            comment: "Spoken description of a device row. Arguments: device name, typical value with unit, a phrase such as '3 windows', lowest median, highest median."
        )
        let depth = entry.originalSampleCount.map { count in
            ", " + String(
                localized: "detail.spoken.originalSamples",
                defaultValue: "from \(count) original samples",
                comment: "Spoken description fragment. The argument is how many raw samples the windows were built from."
            )
        } ?? ", " + String(localized: "detail.spoken.sampleCountUnknown", defaultValue: "original sample count unknown", comment: "Spoken description fragment: the raw sample count was discarded by compaction")
        let compaction = entry.includesCompactedWindows
            ? ", " + String(localized: "detail.spoken.compacted", defaultValue: "includes compacted window medians", comment: "Spoken description fragment: some windows are stored medians")
            : ""
        return base + depth + compaction
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
struct HRVQualityRow: View {
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
struct PairwiseAnalysisRow: View {
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
