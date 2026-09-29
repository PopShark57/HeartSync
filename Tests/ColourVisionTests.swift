import Foundation
import Testing
@testable import HeartSyncChecker

/// Simulated colour-vision deficiency and perceptual colour difference.
///
/// A direct port of what `colorspacious` 1.1.2 does for
/// `deltaE(cspace_convert(c, "sRGB1+CVD", "sRGB1"), …)`: the Machado, Oliveira & Fernandes
/// (2009) matrices at full severity, applied to linear sRGB, re-encoded and clipped; then
/// CIECAM02 under sRGB's viewing conditions (D65 white, Y_b 20, L_A 64/π/5, average
/// surround) and the Luo, Cui & Li (2006) CAM02-UCS distance. The script in the
/// improvements document's appendix produced the table this port is pinned against.
enum ColourVision {
    enum Condition: String, CaseIterable, Sendable {
        case normal, protan, deutan, tritan
    }

    private static let machado: [Condition: [[Double]]] = [
        .protan: [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
        .deutan: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
        .tritan: [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
    ]

    /// IEC 61966-2-1 XYZ → linear sRGB, inverted below as colorspacious does.
    private static let xyzToSRGB: [[Double]] = [[3.2406, -1.5372, -0.4986], [-0.9689, 1.8758, 0.0415], [0.0557, -0.2040, 1.0570]]
    private static let cat02: [[Double]] = [[0.7328, 0.4296, -0.1624], [-0.7036, 1.6975, 0.0061], [0.0030, 0.0136, 0.9834]]
    private static let hpe: [[Double]] = [[0.38971, 0.68898, -0.07868], [-0.22981, 1.18340, 0.04641], [0, 0, 1]]

    private struct Viewing {
        let srgbToXYZ: [[Double]]
        let hpeFromCAT02: [[Double]]
        let dRGB: [Double]
        let fL: Double
        let n: Double
        let z: Double
        let nbb: Double
        let achromaticWhite: Double
    }

    private static let viewing: Viewing = {
        let whitepoint = [95.047, 100.0, 108.883]
        let adaptingLuminance = (64 / Double.pi) / 5
        let backgroundLuminance = 20.0
        let rgbW = multiply(cat02, whitepoint)
        let d = min(1, max(0, 1 - (1 / 3.6) * exp((-adaptingLuminance - 42) / 92)))
        let dRGB = rgbW.map { d * whitepoint[1] / $0 + 1 - d }
        let k = 1 / (5 * adaptingLuminance + 1)
        let fL = 0.2 * pow(k, 4) * (5 * adaptingLuminance)
            + 0.1 * pow(1 - pow(k, 4), 2) * pow(5 * adaptingLuminance, 1.0 / 3)
        let n = backgroundLuminance / whitepoint[1]
        let nbb = 0.725 * pow(1 / n, 0.2)
        let hpeFromCAT02 = multiply(hpe, inverse(cat02))
        let rgbPrimeW = multiply(hpeFromCAT02, zip(dRGB, rgbW).map(*))
        let adaptedW = rgbPrimeW.map { value -> Double in
            let t = pow(fL * value / 100, 0.42)
            return 400 * (t / (t + 27.13)) + 0.1
        }
        return Viewing(
            srgbToXYZ: inverse(xyzToSRGB),
            hpeFromCAT02: hpeFromCAT02,
            dRGB: dRGB,
            fL: fL,
            n: n,
            z: 1.48 + n.squareRoot(),
            nbb: nbb,
            achromaticWhite: (2 * adaptedW[0] + adaptedW[1] + adaptedW[2] / 20 - 0.305) * nbb
        )
    }()

    static func simulate(_ color: SRGBColor, _ condition: Condition) -> SRGBColor {
        guard let matrix = machado[condition] else { return color }
        let simulated = multiply(matrix, [linear(color.red), linear(color.green), linear(color.blue)])
            .map { min(1, max(0, encode($0))) }
        return SRGBColor(red: simulated[0], green: simulated[1], blue: simulated[2])
    }

    /// CAM02-UCS J′a′b′.
    static func ucs(_ color: SRGBColor) -> [Double] {
        let v = viewing
        let xyz = multiply(v.srgbToXYZ, [linear(color.red), linear(color.green), linear(color.blue)]).map { $0 * 100 }
        let rgbC = zip(multiply(cat02, xyz), v.dRGB).map(*)
        let adapted = multiply(v.hpeFromCAT02, rgbC).map { value -> Double in
            let sign: Double = value > 0 ? 1 : (value < 0 ? -1 : 0)
            let t = pow(v.fL * sign * value / 100, 0.42)
            return sign * 400 * (t / (t + 27.13)) + 0.1
        }
        let a = adapted[0] - 12.0 / 11 * adapted[1] + 1.0 / 11 * adapted[2]
        let b = (adapted[0] + adapted[1] - 2 * adapted[2]) / 9
        let hue = atan2(b, a)
        let achromatic = (2 * adapted[0] + adapted[1] + adapted[2] / 20 - 0.305) * v.nbb
        let lightness = 100 * pow(max(achromatic, 0) / v.achromaticWhite, 0.69 * v.z)
        let eccentricity = 12_500.0 / 13 * v.nbb * (cos(hue + 2) + 3.8)
        let t = eccentricity * (a * a + b * b).squareRoot() / (adapted[0] + adapted[1] + 21.0 / 20 * adapted[2])
        let chroma = pow(t, 0.9) * (lightness / 100).squareRoot() * pow(1.64 - pow(0.29, v.n), 0.73)
        let colourfulness = chroma * pow(v.fL, 0.25)
        let jPrime = 1.7 * lightness / (1 + 0.007 * lightness)
        let mPrime = log(1 + 0.0228 * colourfulness) / 0.0228
        return [jPrime, mPrime * cos(hue), mPrime * sin(hue)]
    }

    /// CAM02-UCS ΔE between two colours as seen under `condition`.
    static func deltaE(_ first: SRGBColor, _ second: SRGBColor, _ condition: Condition) -> Double {
        let a = ucs(simulate(first, condition))
        let b = ucs(simulate(second, condition))
        return zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
    }

    /// The smallest ΔE across all four conditions.
    static func worstDeltaE(_ first: SRGBColor, _ second: SRGBColor) -> (value: Double, condition: Condition) {
        Condition.allCases
            .map { (deltaE(first, second, $0), $0) }
            .min { $0.0 < $1.0 }!
    }

    /// WCAG 2 contrast ratio.
    static func contrast(_ first: SRGBColor, _ second: SRGBColor) -> Double {
        func luminance(_ c: SRGBColor) -> Double {
            0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
        }
        let (high, low) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (high + 0.05) / (low + 0.05)
    }

    private static func linear(_ c: Double) -> Double {
        c < 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(abs(c), 1 / 2.4) - 0.055
    }

    private static func multiply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { row in row[0] * v[0] + row[1] * v[1] + row[2] * v[2] }
    }

    private static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    private static func inverse(_ m: [[Double]]) -> [[Double]] {
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        let cofactors: [[Double]] = [
            [m[1][1] * m[2][2] - m[1][2] * m[2][1], m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][1] * m[1][2] - m[0][2] * m[1][1]],
            [m[1][2] * m[2][0] - m[1][0] * m[2][2], m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][2] * m[1][0] - m[0][0] * m[1][2]],
            [m[1][0] * m[2][1] - m[1][1] * m[2][0], m[0][1] * m[2][0] - m[0][0] * m[2][1], m[0][0] * m[1][1] - m[0][1] * m[1][0]],
        ]
        return cofactors.map { row in row.map { $0 / det } }
    }
}

/// Chart colours stay distinguishable for colour-blind readers and between meanings
/// (improvement 31).
@Suite("Colour vision")
@MainActor
struct ColourVisionTests {

    /// The chosen floor. Below about 10 two colours are hard to tell apart at chart-mark
    /// sizes; 15 leaves margin. The previous palette fell to 4.4.
    static let floor = 15.0

    /// Neutral ink reserved for statistical reference lines, as drawn on the list cell a
    /// chart sits in: iOS `label` (primary) and `secondaryLabel` (#3C3C43 at 60% over white;
    /// #EBEBF5 at 60% over #1C1C1E in dark appearance).
    static let referenceInk: [(name: String, light: SRGBColor, dark: SRGBColor)] = [
        ("primary", SRGBColor(red: 0, green: 0, blue: 0), SRGBColor(red: 1, green: 1, blue: 1)),
        ("secondary", SRGBColor(red: 138 / 255, green: 138 / 255, blue: 142.2 / 255), SRGBColor(red: 152.2 / 255, green: 152.2 / 255, blue: 159 / 255)),
    ]

    /// iOS system green, orange, and red in each appearance: the agreement scale.
    static let severity: [(name: String, light: SRGBColor, dark: SRGBColor)] = [
        ("green", SRGBColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255), SRGBColor(red: 48 / 255, green: 209 / 255, blue: 88 / 255)),
        ("orange", SRGBColor(red: 1, green: 149 / 255, blue: 0), SRGBColor(red: 1, green: 159 / 255, blue: 10 / 255)),
        ("red", SRGBColor(red: 1, green: 59 / 255, blue: 48 / 255), SRGBColor(red: 1, green: 69 / 255, blue: 58 / 255)),
    ]

    /// Backgrounds a source colour is drawn on: grouped list and cell in each appearance.
    static let lightBackgrounds = [SRGBColor(red: 1, green: 1, blue: 1), SRGBColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255)]
    static let darkBackgrounds = [SRGBColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255), SRGBColor(red: 0, green: 0, blue: 0)]

    private func appearances() -> [(name: String, colours: [SRGBColor])] {
        [
            ("light", DataSource.paletteSlots.map(\.light)),
            ("dark", DataSource.paletteSlots.map(\.dark)),
        ]
    }

    // MARK: - The validator itself

    @Test("The validator reproduces the measured table it was specified against")
    func validatorMatchesPublishedValues() {
        let blue = SRGBColor(red: 0.00, green: 0.48, blue: 1.00)
        let orange = SRGBColor(red: 1.00, green: 0.42, blue: 0.21)
        let green = SRGBColor(red: 0.20, green: 0.72, blue: 0.47)
        let purple = SRGBColor(red: 0.69, green: 0.32, blue: 0.87)
        let rose = SRGBColor(red: 0.93, green: 0.26, blue: 0.45)
        let teal = SRGBColor(red: 0.12, green: 0.70, blue: 0.78)
        let indigo = SRGBColor(red: 88 / 255, green: 86 / 255, blue: 214 / 255)
        let systemPurple = SRGBColor(red: 175 / 255, green: 82 / 255, blue: 222 / 255)

        func expectClose(_ a: SRGBColor, _ b: SRGBColor, _ expected: [Double]) {
            for (condition, value) in zip(ColourVision.Condition.allCases, expected) {
                #expect(abs(ColourVision.deltaE(a, b, condition) - value) < 0.001, "\(condition)")
            }
        }
        expectClose(blue, purple, [33.2692, 6.9649, 6.7860, 40.1078])
        expectClose(green, rose, [60.6219, 29.9707, 4.8040, 67.2410])
        expectClose(orange, rose, [20.4998, 28.1085, 17.8471, 5.7867])
        expectClose(green, teal, [24.5677, 28.2798, 28.2376, 4.3884])
        expectClose(indigo, systemPurple, [24.0730, 4.1377, 11.5249, 38.1962])
    }

    @Test("A colour is identical to itself, and white and black are maximally apart")
    func validatorSanity() {
        let colour = SRGBColor(red: 0.3, green: 0.6, blue: 0.2)
        for condition in ColourVision.Condition.allCases {
            #expect(ColourVision.deltaE(colour, colour, condition) == 0)
        }
        #expect(abs(ColourVision.ucs(SRGBColor(red: 1, green: 1, blue: 1))[0] - 99.9987) < 0.001)
        #expect(ColourVision.deltaE(SRGBColor(red: 1, green: 1, blue: 1), SRGBColor(red: 0, green: 0, blue: 0), .normal) > 99)
        #expect(abs(ColourVision.contrast(SRGBColor(red: 1, green: 1, blue: 1), SRGBColor(red: 0, green: 0, blue: 0)) - 21) < 0.000_1)
    }

    // MARK: - Source palette

    /// Slots 0–5 were chosen against colour-vision simulation; the slots added after them
    /// (red, gold, teal, orchid) were chosen for ordinary vision only, and their shapes carry
    /// the distinction for a colour-blind reader.
    static let deficiencyCheckedSlots = 6

    @Test("Every two slots stay apart in ordinary vision, in both appearances")
    func allSlotsAreSeparableInOrdinaryVision() {
        for appearance in appearances() {
            let colours = appearance.colours
            for i in colours.indices {
                for j in colours.indices where j > i {
                    let value = ColourVision.deltaE(colours[i], colours[j], .normal)
                    #expect(
                        value >= Self.floor,
                        "\(appearance.name) slots \(i) \(colours[i].hex) and \(j) \(colours[j].hex): ΔE \(value)"
                    )
                }
            }
        }
    }

    @Test("The first six slots stay apart under every simulated deficiency, in both appearances")
    func paletteSlotsAreSeparable() {
        for appearance in appearances() {
            let colours = Array(appearance.colours.prefix(Self.deficiencyCheckedSlots))
            for i in colours.indices {
                for j in colours.indices where j > i {
                    let worst = ColourVision.worstDeltaE(colours[i], colours[j])
                    #expect(
                        worst.value >= Self.floor,
                        "\(appearance.name) slots \(i) \(colours[i].hex) and \(j) \(colours[j].hex): ΔE \(worst.value) under \(worst.condition)"
                    )
                }
            }
        }
    }

    @Test("No source slot can be mistaken for the ink reserved for statistical reference lines")
    func paletteIsSeparableFromReferenceInk() {
        for (index, slot) in DataSource.paletteSlots.enumerated() {
            let checked = index < Self.deficiencyCheckedSlots
            for ink in Self.referenceInk {
                let light = checked
                    ? ColourVision.worstDeltaE(slot.light, ink.light)
                    : (value: ColourVision.deltaE(slot.light, ink.light, .normal), condition: ColourVision.Condition.normal)
                let dark = checked
                    ? ColourVision.worstDeltaE(slot.dark, ink.dark)
                    : (value: ColourVision.deltaE(slot.dark, ink.dark, .normal), condition: ColourVision.Condition.normal)
                #expect(light.value >= Self.floor, "\(slot.name) vs \(ink.name) ink, light: ΔE \(light.value) under \(light.condition)")
                #expect(dark.value >= Self.floor, "\(slot.name) vs \(ink.name) ink, dark: ΔE \(dark.value) under \(dark.condition)")
            }
        }
    }

    @Test("Every source slot keeps 3:1 contrast against the backgrounds it is drawn on")
    func paletteHasGraphicalContrast() {
        for slot in DataSource.paletteSlots {
            for background in Self.lightBackgrounds {
                #expect(ColourVision.contrast(slot.light, background) >= 3, "\(slot.name) light on \(background.hex)")
            }
            for background in Self.darkBackgrounds {
                #expect(ColourVision.contrast(slot.dark, background) >= 3, "\(slot.name) dark on \(background.hex)")
            }
        }
    }

    /// The agreement scale is always paired with words and symbols, and on metric detail it
    /// is a 16%-opacity band behind the lines, so a deficiency floor is not required there.
    /// In ordinary vision, though, a device must never wear the scale's own colours.
    @Test("No source slot wears an agreement-scale colour in ordinary vision")
    func paletteStaysClearOfTheAgreementScale() {
        for slot in DataSource.paletteSlots {
            for tint in Self.severity {
                #expect(ColourVision.deltaE(slot.light, tint.light, .normal) >= Self.floor, "\(slot.name) vs \(tint.name), light")
                #expect(ColourVision.deltaE(slot.dark, tint.dark, .normal) >= Self.floor, "\(slot.name) vs \(tint.name), dark")
            }
        }
    }

    // MARK: - Symbols

    @Test("Slots take a shape of their own until the shapes run out, then repeat in order")
    func shapePerSlot() {
        let shapes = DataSource.paletteSlots.indices.map(SourceSymbol.forColorIndex)
        let distinct = min(SourceSymbol.allCases.count, DataSource.paletteSlots.count)
        #expect(Set(shapes.prefix(distinct)).count == distinct)
        #expect(SourceSymbol.forColorIndex(SourceSymbol.allCases.count) == SourceSymbol.forColorIndex(0))
        #expect(SourceSymbol.forColorIndex(-1) == SourceSymbol.allCases.last)
    }

    @Test("A device keeps its shape when other devices enter or leave the chart")
    func shapeFollowsTheDevice() {
        func source(_ id: String, _ index: Int) -> DataSource {
            var source = DataSource(id: id, displayName: id, transport: .bluetooth)
            source.colorIndex = index
            return source
        }
        let ring = source("ring", 3)
        let alone = MetricDetailSnapshot.makeSeries(for: [ring])
        let withStrap = MetricDetailSnapshot.makeSeries(for: [source("strap", 0), ring])
        let withThree = MetricDetailSnapshot.makeSeries(for: [source("a", 1), source("b", 2), ring])

        #expect(alone.first { $0.sourceID == "ring" }?.symbol == .diamond)
        #expect(withStrap.first { $0.sourceID == "ring" }?.symbol == .diamond)
        #expect(withThree.first { $0.sourceID == "ring" }?.symbol == .diamond)
    }

    @Test("Two visible devices sharing a slot are still told apart by shape")
    func sharedSlotGetsASpareShape() {
        var first = DataSource(id: "first", displayName: "First", transport: .bluetooth)
        var seventh = DataSource(id: "seventh", displayName: "Seventh", transport: .bluetooth)
        first.colorIndex = 0
        seventh.colorIndex = 0
        let series = MetricDetailSnapshot.makeSeries(for: [first, seventh])
        #expect(series[0].symbol == .circle)
        #expect(series[1].symbol != .circle)
    }

    // MARK: - Oura sleep stages

    @Test("Sleep stages get darker with depth and stay apart under every deficiency")
    func sleepStagesFollowDepth() {
        let byDepth = OuraSleepStage.allCases.sorted { $0.depth < $1.depth }
        let lightness = byDepth.map { ColourVision.ucs($0.fill)[0] }
        #expect(lightness == lightness.sorted(by: >), "lightness must fall as depth rises: \(lightness)")

        let stages = OuraSleepStage.allCases
        for i in stages.indices {
            for j in stages.indices where j > i {
                let worst = ColourVision.worstDeltaE(stages[i].fill, stages[j].fill)
                #expect(worst.value >= Self.floor, "\(stages[i].title) vs \(stages[j].title): ΔE \(worst.value) under \(worst.condition)")
            }
        }
    }

    @Test("Awake is marked by pattern as well as colour, and stage codes round-trip")
    func awakeHasANonColourCue() {
        #expect(OuraSleepStage.awake.isPatterned)
        #expect(OuraSleepStage.allCases.filter(\.isPatterned) == [.awake])
        for stage in OuraSleepStage.allCases {
            #expect(OuraSleepStage(code: stage.code) == stage)
        }
        #expect(OuraSleepStage(code: "9") == nil)
    }
}
