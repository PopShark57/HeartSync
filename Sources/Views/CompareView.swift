import Charts
import SwiftUI

/// Side-by-side history for one metric at a time, plus the agreement analysis between
/// every pair of devices that reported it.
struct CompareView: View {
    @Environment(AppModel.self) private var model
    @State private var range: TimeRange = .day
    @State private var selectedKind: MetricKind?

    var body: some View {
        NavigationStack {
            Group {
                if comparable.isEmpty {
                    EmptyStateView(
                        systemImage: "chart.xyaxis.line",
                        title: "Nothing to compare yet",
                        message: "Comparison needs two or more devices reporting the same metric in the same period. Add another device, or widen the time range."
                    )
                } else {
                    List {
                        Section {
                            Picker("Range", selection: $range) {
                                ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }

                        Section("Metrics measured by more than one device") {
                            ForEach(comparable) { kind in
                                NavigationLink {
                                    MetricDetailView(kind: kind, initialRange: range)
                                } label: {
                                    ComparisonSummaryRow(kind: kind, range: range)
                                }
                            }
                        }

                        let flagged = discrepancies
                        Section {
                            if flagged.isEmpty {
                                Label(
                                    "Your devices agree within tolerance across \(range.title.lowercased()).",
                                    systemImage: "checkmark.circle.fill"
                                )
                                .foregroundStyle(.green)
                                .font(.subheadline)
                            } else {
                                ForEach(flagged) { discrepancy in
                                    DiscrepancyRow(discrepancy: discrepancy)
                                }
                            }
                        } header: {
                            Text("Disagreements")
                        } footer: {
                            Text("Compared using mean bias and 95% limits of agreement (Bland\u{2013}Altman), which is the standard method when neither device is a reference. Estimated values are excluded.")
                        }
                    }
                }
            }
            .navigationTitle("Compare")
        }
    }

    private var comparable: [MetricKind] {
        model.store.comparableMetrics(in: range.interval)
    }

    private var discrepancies: [Discrepancy] {
        model.discrepancies(in: range.interval)
    }
}

/// A compact row showing how many devices reported a metric and how far apart they are.
private struct ComparisonSummaryRow: View {
    @Environment(AppModel.self) private var model
    var kind: MetricKind
    var range: TimeRange

    var body: some View {
        let windows = model.windows(kind: kind, in: range.interval)
        let multi = windows.filter { $0.values.count >= 2 }
        let worst = multi.map(\.severity).max() ?? .agreeing
        let meanSpread = multi.isEmpty ? 0 : multi.reduce(0) { $0 + $1.spread } / Double(multi.count)
        let sourceIDs = Set(windows.flatMap { $0.values.map(\.sourceID) })

        HStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(kind.tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 5) {
                    ForEach(sourceIDs.sorted(), id: \.self) { id in
                        if let source = model.store.source(id: id) {
                            SourceDot(color: source.color, size: 7)
                        }
                    }
                    Text("\(sourceIDs.count) devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !multi.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\u{00B1}\(kind.format(meanSpread))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(worst.tint)
                    Text("typical gap")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One line of the disagreement list.
struct DiscrepancyRow: View {
    @Environment(AppModel.self) private var model
    var discrepancy: Discrepancy

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: discrepancy.severity.systemImage)
                    .foregroundStyle(discrepancy.severity.tint)
                    .font(.caption)
                Text(discrepancy.kind.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(discrepancy.windowCount) windows")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                sourceChip(discrepancy.sourceA)
                Image(systemName: "arrow.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                sourceChip(discrepancy.sourceB)
            }
        }
        .padding(.vertical, 4)
    }

    private func sourceChip(_ id: String) -> some View {
        let source = model.store.source(id: id)
        return HStack(spacing: 5) {
            SourceDot(color: source?.color ?? .gray, size: 7)
            Text(source?.displayName ?? "Unknown")
                .font(.caption)
                .lineLimit(1)
        }
    }

    /// Plain-language reading of the statistics, because "mean bias \u{2212}4.2, SD 6.1" is not
    /// useful to someone deciding which of their two rings to trust.
    private var explanation: String {
        let kind = discrepancy.kind
        let nameA = model.store.displayName(forSource: discrepancy.sourceA)
        let nameB = model.store.displayName(forSource: discrepancy.sourceB)
        let gap = kind.formatWithUnit(discrepancy.meanAbsoluteDifference)

        if discrepancy.isSystematicBias {
            let higher = discrepancy.meanBias > 0 ? nameA : nameB
            let lower = discrepancy.meanBias > 0 ? nameB : nameA
            let bias = kind.formatWithUnit(abs(discrepancy.meanBias))
            return "\(higher) reads consistently higher than \(lower), by \(bias) on average. A steady offset like this usually means the two devices are calibrated differently rather than one being faulty."
        } else {
            return "They differ by \(gap) on average, but the direction flips between windows, so this looks like measurement noise rather than one device being biased."
        }
    }
}
