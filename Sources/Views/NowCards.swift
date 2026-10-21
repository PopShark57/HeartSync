import Charts
import SwiftUI

// The pieces of the Now screen, shared by `DashboardView` on iPhone and the Mac mirror's
// Now screen, so both draw a reading, its age, and its verdict the same way.

/// The on-device summary of the cards: a plain paragraph, not a card, so it reads as a
/// subtitle rather than competing with the measurements.
struct NowBriefView: View {
    var text: String
    var generatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label {
                #if os(macOS)
                Text("Written on this Mac by Apple Intelligence from the readings below, \(generatedAt, style: .time). Not medical advice.")
                #else
                Text("Written on this iPhone by Apple Intelligence from the readings below, \(generatedAt, style: .time). Not medical advice.")
                #endif
            } icon: {
                Image(systemName: "sparkles")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("now.brief")
    }
}

/// One source in the Sources header, with a status it can support.
struct SourceChip: View {
    var source: DataSource
    var status: SourceChipStatus
    var now: Date

    var body: some View {
        let title = status.title(relativeTo: now)
        HStack(spacing: 6) {
            SourceDot(color: source.color, size: 8)
            Text(source.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(title)
                .font(.caption2.weight(status == .live ? .semibold : .regular))
                .foregroundStyle(status == .live ? AnyShapeStyle(source.color) : AnyShapeStyle(.secondary))
            if let battery = source.batteryPercent {
                BatteryMeter(percent: battery, isCharging: source.batteryIsCharging ?? false, width: 18)
                Text("\(battery)%")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(battery <= 15 && source.batteryIsCharging != true ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .heartSyncGlassCapsule(tint: source.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(title))
    }

    private func accessibilityText(_ title: String) -> String {
        var parts = [source.displayName, title.lowercased()]
        if let battery = source.batteryPercent {
            parts.append(BatteryBadge.spoken(percent: battery, isCharging: source.batteryIsCharging ?? false).lowercased())
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Card

/// One metric, with every reporting source stacked beneath a consensus value.
///
/// Takes a resolved summary rather than the model: everything on this card came from the
/// screen's single snapshot, so drawing it costs no store reads.
struct MetricCard: View {
    var summary: MetricSummary
    /// A Bluetooth source on this card is streaming right now.
    var isBluetoothStreaming: Bool
    /// For the stress card: which signals moved the latest score most.
    var stressDrivers: String?

    /// Keeps the larger Now numerals while still tracking Dynamic Type (fixed 34pt does not).
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = 34
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(summary.kind.title)
                } icon: {
                    // Pulses only for a genuinely streaming Bluetooth heart rate. SF Symbol
                    // effects follow Reduce Motion on their own.
                    Image(systemName: summary.kind.systemImage)
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            isActive: summary.kind == .heartRate && isBluetoothStreaming
                        )
                }
                .font(.headline)
                .foregroundStyle(summary.kind.tint)
                Spacer()
                if let headline = summary.headline {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(summary.kind.format(headline))
                            .font(.system(size: headlineSize, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText(value: headline))
                            .animation(reduceMotion ? nil : .snappy, value: headline)
                        Text(summary.kind.unit)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(headlineAccessibilityLabel(headline))
                }
            }

            // A spot or nightly measurement stays on Now after the live window, but it must
            // not read as a current value.
            if !summary.isCurrent, let newest = summary.newestTimestamp {
                Label {
                    Text("Last reported \(newest, format: .relative(presentation: .named)). Not a live value.")
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("now.card.lastReported")
            }

            if let comparison = summary.comparison {
                VStack(alignment: .leading, spacing: 4) {
                    AgreementBadge(
                        severity: comparison.severity,
                        spread: comparison.spread,
                        kind: summary.kind,
                        sourceCount: comparison.sourceCount
                    )
                    Text("\(comparison.sourceCount) devices measured in the same \(WindowLabel.length(comparison.windowSize)) window.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let detail = summary.notComparedDetail {
                ComparisonUnavailableNote(detail: detail)
            }

            if let sparkline = summary.sparkline {
                SparklineView(
                    sparkline: sparkline,
                    sources: Dictionary(summary.rows.map { ($0.source.id, $0.source) }, uniquingKeysWith: { first, _ in first })
                )
            }

            VStack(spacing: 2) {
                ForEach(summary.rows) { row in
                    SourceValueRow(
                        source: row.source,
                        kind: summary.kind,
                        value: row.value,
                        provenance: row.provenance,
                        timestamp: row.timestamp,
                        deltaFromWindowConsensus: row.deltaFromWindowConsensus
                    )
                }
            }

            if summary.rows.contains(where: { $0.source.id == AppModel.estimateSourceID }),
               summary.kind == .bloodPressureSystolic || summary.kind == .bloodPressureDiastolic {
                EstimateDisclaimer(text: Estimators.BloodPressureEstimate.disclaimer)
            }

            if summary.kind == .stress {
                if let stressDrivers, summary.isCurrent {
                    Text(stressDrivers)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("now.stress.drivers")
                }
                EstimateDisclaimer(text: StressModel.disclaimer)
            }

            NavigationLink {
                MetricDetailView(kind: summary.kind)
            } label: {
                HStack {
                    Text("History and agreement")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                // Apple's minimum hit target is 44 × 44 points.
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .heartSyncGlassCapsule(tint: summary.kind.tint, interactive: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(summary.kind.tint)
            .accessibilityLabel("History and agreement for \(summary.kind.title)")
        }
        .metricCard(tint: summary.kind.tint)
    }

    /// Says which number this is, because the headline means different things depending on
    /// whether the devices could be compared.
    private func headlineAccessibilityLabel(_ value: Double) -> String {
        let formatted = summary.kind.formatWithUnit(value)
        guard summary.isCurrent else {
            return "\(summary.kind.title), last reported \(formatted)"
        }
        return summary.comparison == nil
            ? "\(summary.kind.title), latest reading \(formatted)"
            : "\(summary.kind.title), window consensus \(formatted)"
    }
}

// MARK: - Sparkline

/// An axis-free trend: the gap rules of every other chart (`ChartSegmentation`), windowed
/// medians only, a monotone line that cannot overshoot, and a pinned domain so a quiet
/// stretch stays empty. It is not interactive; the full chart is one tap away.
struct SparklineView: View {
    var sparkline: Sparkline
    var sources: [String: DataSource]

    var body: some View {
        Chart {
            ForEach(sparkline.series) { series in
                let color = sources[series.sourceID]?.color ?? .secondary
                let isolated = series.isolated
                ForEach(Array(series.points.enumerated()), id: \.offset) { index, point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(sparkline.kind.title, point.value),
                        series: .value(
                            "Series",
                            ChartSegmentation.key(series: series.sourceID, segment: series.segments[index])
                        )
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .foregroundStyle(color)
                    if isolated.contains(index) {
                        PointMark(x: .value("Time", point.date), y: .value(sparkline.kind.title, point.value))
                            .symbolSize(14)
                            .foregroundStyle(color)
                    }
                }
            }
        }
        .chartXScale(domain: sparkline.start...sparkline.through)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: HeartSyncTheme.Chart.sparklineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sparkline.spokenSummary(names: sources.mapValues(\.displayName)))
        .accessibilityIdentifier("now.sparkline.\(sparkline.kind.rawValue)")
    }
}
