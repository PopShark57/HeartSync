import SwiftUI

/// Visual language for HeartSync screens.
///
/// Presentation only. Cards, atmosphere, and motion live here so every tab shares one
/// look without views inventing their own palette. Analysis, evidence wording, and
/// source colours stay where they already live.
enum HeartSyncTheme {
    /// Primary brand rose — warmer and deeper than system pink.
    static let accent = Color(red: 0.95, green: 0.22, blue: 0.42)
    static let accentDeep = Color(red: 0.58, green: 0.06, blue: 0.24)
    static let gold = Color(red: 0.93, green: 0.74, blue: 0.42)

    static let cardRadius: CGFloat = 22
}

/// Soft wash behind lists and stacks. Light mode stays warm and paper-like; dark mode
/// goes near-black with a rose bloom so the glass cards have something to sit on.
struct AtmosphereBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [
                    HeartSyncTheme.accent.opacity(0.28),
                    HeartSyncTheme.accentDeep.opacity(0.08),
                    .clear,
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            RadialGradient(
                colors: [
                    Color.purple.opacity(0.16),
                    .clear,
                ],
                center: UnitPoint(x: 0.05, y: 0.78),
                startRadius: 10,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Breathing halo used next to a live heart-rate figure. Honours Reduce Motion.
struct PulseHalo: View {
    var tint: Color = HeartSyncTheme.accent
    var size: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.35), lineWidth: 1.5)
                .frame(width: size, height: size)
                .scaleEffect(expanded ? 1.28 : 0.92)
                .opacity(expanded ? 0 : 0.8)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.55), tint.opacity(0.12)],
                        center: .center,
                        startRadius: 2,
                        endRadius: size / 2
                    )
                )
                .frame(width: size * 0.72, height: size * 0.72)
                .scaleEffect(expanded ? 1.06 : 0.94)
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: tint.opacity(0.6), radius: 6)
        }
        .frame(width: size * 1.35, height: size * 1.35)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.92).repeatForever(autoreverses: true)) {
                expanded = true
            }
        }
    }
}

struct GlassCardModifier: ViewModifier {
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: HeartSyncTheme.cardRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: HeartSyncTheme.cardRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        (tint ?? .clear).opacity(tint == nil ? 0 : 0.10),
                                        .clear,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: HeartSyncTheme.cardRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.38),
                                        Color.white.opacity(0.06),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: HeartSyncTheme.accentDeep.opacity(0.14), radius: 16, y: 8)
            }
    }
}

extension View {
    /// Glass treatment for dashboard and explorer tiles.
    func heartSyncCard(tint: Color? = nil) -> some View {
        modifier(GlassCardModifier(tint: tint))
    }

    /// Puts the shared atmosphere behind a navigation stack without stealing list backgrounds.
    func heartSyncAtmosphere() -> some View {
        background { AtmosphereBackground() }
    }
}
