import SwiftUI

/// Small presentation pieces shared by every card in the Oura dashboard.
///
/// These were file-private helpers inside `OuraDashboardView` while that screen was a single
/// file. They are module-internal now so the per-section views in this directory render
/// identical chrome; every one of them is `Oura`-prefixed to keep generic names such as
/// "ScoreCard" out of the module namespace.
///
/// Nothing here interprets a measurement. Values arrive already formatted by `OuraFormat`,
/// and no component may add agreement, trend, or reference-standard language of its own.

// MARK: - Card chrome

extension View {
    /// The single card treatment every Oura section shares.
    func ouraCard() -> some View {
        padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.secondary.opacity(0.08))
            }
    }
}

/// Grid geometry shared by the Oura sections, so score and metric grids stay aligned across
/// files.
///
/// Main-actor isolated because `GridItem` values are created lazily on first use, and the
/// only callers are SwiftUI view bodies, which are already on the main actor.
@MainActor
enum OuraCardLayout {
    /// Score cards: wide enough for the value plus its progress ring.
    static let cardColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    /// Biomarker cards and mini-stat grids.
    static let metricColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]
}

// MARK: - Headings and pills

struct OuraSectionHeading: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.indigo)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct OuraHeaderPill: View {
    var icon: String
    var text: String
    var tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

// MARK: - Score and biomarker cards

struct OuraScoreCard: View {
    var title: String
    var value: String
    var progress: Double?
    var detail: String
    var icon: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 4)
                if let progress {
                    ZStack {
                        Circle()
                            .stroke(tint.opacity(0.14), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: min(max(progress, 0), 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                }
            }
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .ouraCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// Combining the children reads the card as "Activity 82 3 Mar", and the `—` placeholder
    /// as a bare dash. Naming the missing state keeps an absent score audibly absent instead
    /// of sounding like something the ring reported.
    private var accessibilityDescription: String {
        let spokenValue = value == "—" ? "No score yet" : value
        return "\(title), \(spokenValue). \(detail)"
    }
}

struct OuraBiomarkerItem: Identifiable {
    var id: String
    var title: String
    var value: String
    var unit: String
    var detail: String
    var icon: String
    var tint: Color
}

struct OuraBiomarkerCard: View {
    var item: OuraBiomarkerItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(item.title, systemImage: item.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.tint)
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.value)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                Text(item.unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(item.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .ouraCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// The value and its unit are separate `Text` views, so the combined element would read
    /// "— bpm" for a metric Oura has not reported. The label keeps value and unit together
    /// and says outright when there is no value, without implying a measurement.
    private var accessibilityDescription: String {
        let spokenValue = item.value == "—" ? "No recent value" : "\(item.value) \(item.unit)"
        return "\(item.title), \(spokenValue). \(item.detail)"
    }
}

// MARK: - Stats and ribbons

struct OuraMiniStat: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OuraCategoricalRibbon: View {
    var values: [Character]
    var colors: [Character: Color]
    var fallback: Color
    var accessibilityText: String

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let width = size.width / CGFloat(values.count)
            for (index, value) in values.enumerated() {
                let rect = CGRect(
                    x: CGFloat(index) * width,
                    y: 0,
                    width: max(width + 0.5, 1),
                    height: size.height
                )
                context.fill(Path(rect), with: .color(colors[value] ?? fallback))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.secondary.opacity(0.12))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

struct OuraRibbonLegend: View {
    var items: [(String, Color)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Circle()
                        .fill(item.1)
                        .frame(width: 7, height: 7)
                    Text(item.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Timeline

struct OuraTimelineItem: Identifiable {
    var id: String
    var date: Date
    var title: String
    var subtitle: String
    var icon: String
    var tint: Color
}

struct OuraTimelineRow: View {
    var item: OuraTimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.subheadline)
                .foregroundStyle(item.tint)
                .frame(width: 30, height: 30)
                .background(item.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(item.date, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Empty and explanatory rows

struct OuraInlineEmptyState: View {
    var icon: String
    var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 10)
    }
}

/// A limitation stated plainly on screen. The copy these rows carry — cloud timing, the
/// absence of raw accelerometer samples, on-device token storage — is the screen's honesty
/// contract and must not be softened or dropped when a section is rearranged.
struct OuraHonestInfoRow: View {
    var icon: String
    var tint: Color
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Permissions

/// How a requested OAuth scope should be presented. `unknown` exists because Oura is the
/// authority on permissions: a missing scope name in the callback metadata is not proof that
/// access was denied, so it must never be rendered as "Missing".
enum OuraPermissionDisplayState {
    case granted
    case unknown
    case missing
}

struct OuraScopeRow: View {
    var scope: String
    var state: OuraPermissionDisplayState

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(scopeTitle)
                    .font(.subheadline)
                Text(scopeDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(stateTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(tint.opacity(0.10), in: Capsule())
        }
    }

    private var icon: String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        case .missing: "lock.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .granted: .green
        case .unknown: .blue
        case .missing: .orange
        }
    }

    private var stateTitle: String {
        switch state {
        case .granted: "Granted"
        case .unknown: "Checked by Oura"
        case .missing: "Missing"
        }
    }

    private var scopeTitle: String {
        switch scope {
        case "personal": "Profile & ring"
        case "daily": "Daily health summaries"
        case "heartrate": "Heart-rate samples"
        case "workout": "Workouts"
        case "tag": "Tags & rest mode"
        case "session": "Guided sessions"
        case "spo2Daily", "spo2": "Nightly blood oxygen"
        case "stress": "Stress & resilience"
        case "heart_health": "Heart health"
        case "ring_configuration": "Ring details"
        default: scope
        }
    }

    private var scopeDescription: String {
        switch scope {
        case "personal": "Profile information"
        case "daily": "Sleep, activity, readiness, and daily recovery"
        case "heartrate": "Oura's processed heart-rate time series"
        case "workout": "Detected and manually entered workouts"
        case "tag": "Tags, enhanced tags, and rest-mode periods"
        case "session": "Meditation, breathing, rest, and motion summaries"
        case "spo2Daily", "spo2": "Sleep SpO₂ average and disturbance index"
        case "stress": "Daily stress, recovery, and resilience"
        case "heart_health": "Cardiovascular age and VO₂ max"
        case "ring_configuration": "Ring battery, hardware, and firmware"
        default: "Oura data permission"
        }
    }
}
