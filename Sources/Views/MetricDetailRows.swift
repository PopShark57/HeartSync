import SwiftUI

// MARK: - Rows

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
