import Foundation

/// Oura's `sleep_phase_5_min` codes, ordered by depth, with the colours the ribbon draws.
///
/// Depth is encoded as lightness: the deeper the stage, the darker its band, in one hue.
/// The previous colours (indigo, blue, purple, orange) told stages apart by hue alone, and
/// deep and REM collapsed to a ΔE of 4.1 for a protanope. A lightness ramp survives every
/// colour-vision deficiency, and Awake also carries a hatch pattern so it never depends on
/// colour at all. `ColourVisionTests` checks both properties.
///
/// These are Oura's own classifications, drawn as delivered; HeartSync does not stage sleep.
enum OuraSleepStage: CaseIterable, Sendable {
    case deep, light, rem, awake

    /// Oura's `sleep_phase_5_min` code for this stage.
    var code: Character {
        switch self {
        case .deep:  "1"
        case .light: "2"
        case .rem:   "3"
        case .awake: "4"
        }
    }

    init?(code: Character) {
        guard let stage = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = stage
    }

    var title: String {
        switch self {
        case .deep:  "Deep"
        case .light: "Light"
        case .rem:   "REM"
        case .awake: "Awake"
        }
    }

    /// 0 for awake, rising with depth. The colour's lightness falls as this rises.
    var depth: Int {
        switch self {
        case .awake: 0
        case .rem:   1
        case .light: 2
        case .deep:  3
        }
    }

    /// CAM02-UCS lightness ≈ 32, 54, 76 for deep, light, REM in one blue hue, and a pale
    /// amber at ≈ 90 for awake.
    var fill: SRGBColor {
        switch self {
        case .deep:  SRGBColor(red: 0.00, green: 0.26, blue: 0.69)    // #0042B0
        case .light: SRGBColor(red: 0.28, green: 0.49, blue: 0.85)    // #477DD9
        case .rem:   SRGBColor(red: 0.61, green: 0.72, blue: 0.91)    // #9CB8E8
        case .awake: SRGBColor(red: 1.00, green: 0.84, blue: 0.58)    // #FFD694
        }
    }

    /// Awake is hatched as well as coloured, so it is identifiable without any colour.
    var isPatterned: Bool { self == .awake }
}
