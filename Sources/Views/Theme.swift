import SwiftUI

/// Visual tokens for HeartSync's screens.
///
/// Presentation only. Nothing here interprets a measurement, changes an evidence rule,
/// or replaces a semantic colour that already carries meaning (source palette, metric tint,
/// severity green/orange/red). Those stay owned by the model types that define them.
enum HeartSyncTheme {

    /// Primary brand accent: a deep rose that reads as "pulse" without competing with
    /// the green/orange/red agreement scale.
    static let accent = Color(red: 0.91, green: 0.20, blue: 0.38)

    /// Cooler companion used in gradients and the Oura chrome, so the app is not one flat red.
    static let accentSecondary = Color(red: 0.55, green: 0.22, blue: 0.72)

    static let cardCornerRadius: CGFloat = 22
    static let compactCornerRadius: CGFloat = 14

    /// Soft lift used on dashboard tiles. Kept low so lists and Forms stay quiet.
    static let cardShadow = Color.black.opacity(0.10)

    /// Styling for statistical reference lines on charts.
    ///
    /// Reference lines are drawn in neutral ink and told apart by dash pattern and weight,
    /// never by hue. A mean-bias line in system blue matched palette slot 0 almost exactly,
    /// so "Device A" and "mean bias" shared a colour on one screen; neutral ink is reserved
    /// for statistics so a reference line can never be read as a device. The palette
    /// validator in the tests checks every source colour against these inks.
    enum Chart {
        /// Mean bias and limits of agreement.
        static var referenceInk: Color { .primary }
        /// Zero difference and the fixed agreement tolerances.
        static var secondaryReferenceInk: Color { .secondary }

        static var meanBias: StrokeStyle { StrokeStyle(lineWidth: 2) }
        static var limitsOfAgreement: StrokeStyle { StrokeStyle(lineWidth: 1.5, dash: [10, 4]) }
        static var zeroDifference: StrokeStyle { StrokeStyle(lineWidth: 1) }
        static var warningTolerance: StrokeStyle { StrokeStyle(lineWidth: 1, dash: [4, 3]) }
        static var majorTolerance: StrokeStyle { StrokeStyle(lineWidth: 1, dash: [1.5, 3]) }
        /// The dashed rule marking a selected window.
        static var selection: StrokeStyle { StrokeStyle(lineWidth: 1, dash: [3, 3]) }

        /// Caveats drawn on a chart: estimates, sparse timing, noisy spread. Orange is the
        /// app's "look closer" colour, never a device.
        static var cautionInk: Color { .orange }
        /// Heart-rate traces from a single cloud source (Oura), which has no palette slot.
        static var heartRateInk: Color { .pink }
        /// Opaque, adaptive surface for chart annotations. Backdrop-blurring materials
        /// can render as dark bands inside Swift Charts' annotation renderer.
        static var calloutBackground: Color { Color(uiColor: .secondarySystemBackground) }

        /// Fill opacity of the spread band behind per-device lines.
        static let bandOpacity: Double = 0.14

        // Plot heights at the default text size. `heartSyncChartHeight(_:)` scales them with
        // Dynamic Type and the available width, so the plot never collapses under large
        // axis labels and uses the room an iPad or a landscape iPhone offers.
        static let sparklineHeight: CGFloat = 36
        static let historyHeight: CGFloat = 240
        static let pairTimelineHeight: CGFloat = 250
        static let blandAltmanHeight: CGFloat = 280
        static let ouraHeartRateHeight: CGFloat = 210
        static let ouraMovementHeight: CGFloat = 150
        static let ouraHypnogramHeight: CGFloat = 132

        /// X-axis labels for a time span: minutes within a day, hours for a day, dates
        /// beyond. Shared so every history chart labels the same span the same way.
        static func axisFormat(span: TimeInterval) -> Date.FormatStyle {
            switch TimeRange.fitting(duration: span) {
            case .hour, .sixHours: .dateTime.hour().minute()
            case .day:             .dateTime.hour()
            case .week, .month:    .dateTime.month(.abbreviated).day()
            }
        }

        /// A spoken time for an Audio Graph axis: always to the minute, with the date once
        /// the span is longer than a day.
        static func axisDescription(_ date: Date, span: TimeInterval) -> String {
            span <= 86_400
                ? date.formatted(date: .omitted, time: .shortened)
                : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }
}

/// Sizes a chart's plot from a base height: larger with Dynamic Type (the axis labels grow
/// too, so a fixed height leaves a sliver of plot at accessibility sizes), larger again in
/// a regular width (iPad) or a landscape iPhone.
private struct ChartHeightModifier: ViewModifier {
    var base: CGFloat
    /// 100 at the default text size; tracks the body text style.
    @ScaledMetric(relativeTo: .body) private var textScale: CGFloat = 100
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content.frame(height: height)
    }

    private var height: CGFloat {
        // Capped so AX5 labels still leave room for the rest of the screen.
        var value = base * min(max(textScale / 100, 1), 2.2)
        if horizontalSizeClass == .regular { value *= 1.4 }
        if verticalSizeClass == .compact { value *= 1.2 }
        return value.rounded()
    }
}

extension View {
    func heartSyncChartHeight(_ base: CGFloat) -> some View {
        modifier(ChartHeightModifier(base: base))
    }
}

extension SRGBColor {
    /// The same value in both appearances. Source slots use their own light/dark pair
    /// instead (`SourcePaletteSlot.color`).
    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// A legend swatch that draws a reference line with its real stroke, so the key shows the
/// same dash pattern the chart does rather than a coloured capsule.
struct ReferenceLineSwatch: View {
    var ink: Color
    var style: StrokeStyle

    var body: some View {
        HorizontalRule()
            .stroke(ink, style: style)
            .frame(width: 24, height: max(style.lineWidth, 2))
            .accessibilityHidden(true)
    }

    private struct HorizontalRule: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

// MARK: - Surfaces

/// Ambient wash behind the live dashboard. Subtle enough that cards stay the focus,
/// strong enough that the screen no longer sits on a flat system grey.
struct HeartSyncAmbientBackground: View {
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(
                colors: [
                    HeartSyncTheme.accent.opacity(0.16),
                    HeartSyncTheme.accentSecondary.opacity(0.08),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
}

/// Glass tile used by Now cards and empty states.
struct HeartSyncCardBackground: View {
    var tint: Color = HeartSyncTheme.accent
    var cornerRadius: CGFloat = HeartSyncTheme.cardCornerRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(0.10),
                                Color.white.opacity(0.02),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                tint.opacity(0.22),
                                Color.white.opacity(0.06),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: HeartSyncTheme.cardShadow, radius: 16, y: 8)
    }
}

// MARK: - View chrome

extension View {
    /// Standard card treatment for dashboard tiles.
    func metricCard(tint: Color = HeartSyncTheme.accent) -> some View {
        self
            .padding(16)
            .background { HeartSyncCardBackground(tint: tint) }
    }

    /// Applies the brand tint to controls and selected tabs.
    func heartSyncChrome() -> some View {
        self
            .tint(HeartSyncTheme.accent)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
