import SwiftUI

/// A legend swatch drawn in the source's colour *and* its chart symbol.
///
/// Legends used a round dot for every device while the chart drew squares, triangles and
/// diamonds, so the one channel that survives colour-vision deficiency was missing from the
/// key. The shape here matches the plotted mark. Hidden from VoiceOver: the entry beside it
/// speaks the device name and the shape's name.
struct SourceSymbolGlyph: View {
    var symbol: SourceSymbol
    var color: Color
    var size: CGFloat = 9

    var body: some View {
        SourceSymbolShape(symbol: symbol)
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Outline of each `SourceSymbol`, approximating the matching Swift Charts symbol.
struct SourceSymbolShape: Shape {
    var symbol: SourceSymbol

    func path(in rect: CGRect) -> Path {
        switch symbol {
        case .circle:
            return Path(ellipseIn: rect)
        case .square:
            return Path(rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08))
        case .triangle:
            return polygon(in: rect, corners: 3, rotation: -.pi / 2)
        case .diamond:
            return polygon(in: rect, corners: 4, rotation: -.pi / 2)
        case .pentagon:
            return polygon(in: rect, corners: 5, rotation: -.pi / 2)
        case .cross:
            // Two bars at ±45°: an X, as Swift Charts draws `.cross`.
            let bar = min(rect.width, rect.height) * 0.3
            var path = Path()
            for angle in [CGFloat.pi / 4, -CGFloat.pi / 4] {
                let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                    .rotated(by: angle)
                path.addPath(
                    Path(CGRect(x: -rect.width / 2, y: -bar / 2, width: rect.width, height: bar)),
                    transform: transform
                )
            }
            return path
        case .asterisk:
            // Three bars through the centre, at 60° steps.
            let bar = min(rect.width, rect.height) * 0.22
            var path = Path()
            for angle in [CGFloat.zero, .pi / 3, 2 * .pi / 3] {
                let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                    .rotated(by: angle)
                path.addPath(
                    Path(CGRect(x: -rect.width / 2, y: -bar / 2, width: rect.width, height: bar)),
                    transform: transform
                )
            }
            return path
        }
    }

    private func polygon(in rect: CGRect, corners: Int, rotation: CGFloat) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        for corner in 0..<corners {
            let angle = rotation + CGFloat(corner) * 2 * .pi / CGFloat(corners)
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
