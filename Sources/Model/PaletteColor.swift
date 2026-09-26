import Foundation

/// An sRGB colour as plain numbers in `0...1`.
///
/// Chart colours that carry meaning are defined this way, not as `Color` literals, so the
/// colour-vision validator in the tests measures exactly the values that are drawn. A
/// `Color` cannot be read back into components portably; these can.
struct SRGBColor: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#RRGGBB`, for documentation and test messages.
    var hex: String {
        let channels = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }
}

/// One source colour slot: the value drawn in light appearance and the one drawn in dark.
///
/// A device keeps its slot for life (`DataSource.colorIndex` persists), so a slot's two
/// values stay in the same hue family: the device looks like itself in either appearance.
struct SourcePaletteSlot: Hashable, Sendable {
    /// Hue family, for documentation and test messages only.
    var name: String
    var light: SRGBColor
    var dark: SRGBColor
}
