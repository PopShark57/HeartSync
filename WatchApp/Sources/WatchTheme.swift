import SwiftUI

/// Wrist surfaces. Presentation only: nothing here changes what a value or verdict means.
///
/// watchOS 26 draws controls in Liquid Glass; earlier releases (the target is watchOS 11)
/// get a tinted translucent fill with the same shape, so the layout does not change between
/// them. The `compiler` guard keeps the file building with an SDK that predates glass.
enum WatchTheme {
    /// Behind every page: a faint rose wash at the top that fades into black, so the glass
    /// rows have something to refract without lowering contrast.
    static var backdrop: some ShapeStyle {
        LinearGradient(
            colors: [Color.pink.opacity(0.32), Color.purple.opacity(0.12), .black],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static let rowCornerRadius: CGFloat = 18
}

/// A list row's surface: glass tinted by the metric.
struct WatchCardBackground: View {
    var tint: Color = .pink

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WatchTheme.rowCornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(watchOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(.regular.tint(tint.opacity(0.18)), in: shape)
        } else {
            legacy(shape)
        }
        #else
        legacy(shape)
        #endif
    }

    private func legacy(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(tint.opacity(0.16))
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

extension View {
    /// Glass on watchOS 26, a bordered capsule before it.
    @ViewBuilder
    func watchGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(watchOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
        #else
        buttonStyle(.bordered).buttonBorderShape(.capsule)
        #endif
    }

    /// A selectable capsule for the period picker: prominent glass when selected.
    @ViewBuilder
    func watchGlassCapsule(selected: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(watchOS 26.0, *) {
            glassEffect(
                selected ? .regular.tint(Color.pink.opacity(0.55)).interactive() : .regular.interactive(),
                in: Capsule()
            )
        } else {
            background(Capsule().fill(selected ? Color.pink.opacity(0.45) : Color.gray.opacity(0.22)))
        }
        #else
        background(Capsule().fill(selected ? Color.pink.opacity(0.45) : Color.gray.opacity(0.22)))
        #endif
    }
}
