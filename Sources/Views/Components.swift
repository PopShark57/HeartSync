import SwiftUI

/// A coloured dot identifying a source, used everywhere a value is attributed.
struct SourceDot: View {
    var color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.background, lineWidth: 1))
    }
}

/// One source's reading of one metric, in a row: dot, name, value, freshness.
struct SourceValueRow: View {
    var source: DataSource
    var kind: MetricKind
    var value: Double
    var provenance: Provenance
    var timestamp: Date?
    /// Difference from the cross-device consensus, shown when more than one source
    /// reported in the same window.
    var deltaFromConsensus: Double?

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
                if let delta = deltaFromConsensus, abs(delta) >= 0.05 {
                    Text(delta > 0 ? "+\(kind.format(delta))" : kind.format(delta))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(kind.agreement.severity(forDelta: delta).tint)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Badge summarising how well the sources in a window agree.
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

/// Empty-state panel with an optional call to action.
struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
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
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
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
