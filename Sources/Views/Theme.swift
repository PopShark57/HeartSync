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
