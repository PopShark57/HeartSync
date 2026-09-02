import SwiftUI

/// A coloured dot identifying a source, used everywhere a value is attributed.
///
/// Purely decorative for assistive technology: the colour repeats information the
/// surrounding row already states in words, so it is hidden rather than announced.
struct SourceDot: View {
    var color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.background, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Wording for the epoch-aligned comparison grid.
///
/// The Now card and the metric-detail chart both name bucket lengths to the user, and a
/// window called "1-minute" on one screen must not be called "60-second" on the other, so
/// the phrasing lives in one place.
enum WindowLabel {

    /// Length of a comparison or chart bucket, e.g. `"1-minute"`, `"24-hour"`.
    static func length(_ seconds: TimeInterval) -> String {
        if seconds >= 3_600 { return "\(Int(seconds / 3_600))-hour" }
        return "\(max(1, Int(seconds / 60)))-minute"
    }

    /// Coarse elapsed time, e.g. `"12 min"`, used inside sentences that explain why two
    /// readings were not compared. Deliberately vague: the exact age is already on the row.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let elapsed = max(0, seconds)
        if elapsed < 60    { return "\(Int(elapsed.rounded())) sec" }
        if elapsed < 3_600 { return "\(Int((elapsed / 60).rounded())) min" }
        if elapsed < 86_400 { return "\(Int((elapsed / 3_600).rounded())) hr" }
        return "\(Int((elapsed / 86_400).rounded())) days"
    }
}

/// One source's reading of one metric, in a row: dot, name, value, freshness.
struct SourceValueRow: View {
    var source: DataSource
    var kind: MetricKind
    var value: Double
    var provenance: Provenance
    var timestamp: Date?
    /// Offset from the consensus of one epoch-aligned comparison window.
    ///
    /// Pass a value **only** when this reading actually falls inside a
    /// `kind.comparisonWindow` bucket that two or more sources shared. A difference taken
    /// between readings minutes apart measures the devices' sampling schedules rather than
    /// the devices, and rendering it in a severity colour would present that artefact as a
    /// disagreement verdict. When the reading was not compared, pass `nil` and say so
    /// elsewhere in the row's container.
    var deltaFromWindowConsensus: Double?

    var body: some View {
        HStack(spacing: 10) {
            SourceDot(color: source.color)

            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if provenance != .measured {
                        Image(systemName: provenance.systemImage)
                            .font(.caption2)
                        Text(provenance.title)
                            .font(.caption2)
                    }
                    if let timestamp {
                        Text(timestamp, format: .relative(presentation: .numeric))
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(kind.format(value))
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let delta = deltaFromWindowConsensus, abs(delta) >= 0.05 {
                    Text(delta > 0 ? "+\(kind.format(delta))" : kind.format(delta))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(kind.agreement.severity(forDelta: delta).tint)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    /// VoiceOver reads the row as one sentence; the visual layout splits the same facts
    /// across three columns, which otherwise arrive as disconnected fragments.
    private var accessibilityDescription: String {
        var parts: [String] = [source.displayName, kind.formatWithUnit(value)]
        if provenance != .measured { parts.append(provenance.title) }
        if let timestamp { parts.append(timestamp.formatted(.relative(presentation: .named))) }
        if let delta = deltaFromWindowConsensus, abs(delta) >= 0.05 {
            let direction = delta > 0 ? "above" : "below"
            parts.append("\(kind.formatWithUnit(abs(delta))) \(direction) the window consensus")
        }
        return parts.joined(separator: ", ")
    }
}

/// Badge summarising how well the sources in one epoch-aligned window agree.
///
/// Only build this from sources that shared a `kind.comparisonWindow` bucket. It is the
/// app's agreement verdict, and a verdict drawn from readings taken minutes apart would be
/// measuring the timing offset. Use `ComparisonUnavailableNote` for everything else.
struct AgreementBadge: View {
    var severity: DiscrepancySeverity
    var spread: Double
    var kind: MetricKind
    var sourceCount: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: severity.systemImage)
                .font(.caption2)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(severity.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(severity.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(severity.title). \(label).")
    }

    private var label: String {
        guard sourceCount >= 2 else { return "Single source" }
        switch severity {
        case .agreeing: return "Agree within \(kind.format(spread)) \(kind.unit)"
        case .notable:  return "\(kind.format(spread)) \(kind.unit) apart"
        case .major:    return "\(kind.format(spread)) \(kind.unit) apart"
        }
    }
}

/// Stands in for `AgreementBadge` when devices reported the same metric but never inside
/// the same aligned window.
///
/// Deliberately neutral in colour and wording: insufficient evidence is not agreement, and
/// this note must never be mistaken for a green result.
struct ComparisonUnavailableNote: View {
    /// Plain-language reason, e.g. "readings 12 min apart · no shared 1-minute window".
    var detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock.badge.questionmark")
                .font(.caption2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Not compared")
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Not compared. \(detail).")
    }
}

/// Empty-state panel with an optional call to action.
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    /// The glyph is sized in points rather than by text style, so it is scaled explicitly
    /// against `.largeTitle` instead of staying fixed while the rest of the panel grows.
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 42

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: glyphSize))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

/// Prominent, unmissable note attached to anything the app modelled rather than measured.
struct EstimateDisclaimer: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimate. \(text)")
    }
}

/// Battery pill for a Bluetooth source.
struct BatteryBadge: View {
    var percent: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text("\(percent)%")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(percent <= 15 ? .red : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent <= 15 ? "Battery low, \(percent) percent" : "Battery \(percent) percent")
    }

    private var symbol: String {
        switch percent {
        case ..<13:  "battery.0percent"
        case ..<38:  "battery.25percent"
        case ..<63:  "battery.50percent"
        case ..<88:  "battery.75percent"
        default:     "battery.100percent"
        }
    }
}

/// Signal-strength bars for a scan result.
struct SignalBars: View {
    var bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index <= bars ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(index) * 4 + 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal strength \(bars) of 3")
    }
}

extension View {
    /// Standard card treatment for dashboard tiles.
    func metricCard() -> some View {
        self
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}
