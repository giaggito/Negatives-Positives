import Foundation
import simd

/// How a stock's grain looks, for a 35 mm frame (micrometres on the film).
public struct GrainCharacter: Sendable, Equatable {
    /// RMS granularity × 1000 at density 1 (48 µm aperture), the standard datasheet measure.
    public var granularity: Double
    /// Effective radius of the coarse grains / dye-cloud clumps and of the fine ones.
    public var coarseRadius: Double
    public var fineRadius: Double
    /// Share of the grain variance carried by the coarse grains (0…1): higher looks clumpier.
    public var roughness: Double
    /// How independent the three dye layers' grain is (0 = monochrome grain, 1 = fully independent).
    public var colour: Double
}

public struct FilmStock: Identifiable, Sendable {
    public enum Kind: String, Sendable { case colorNegative, slide, bwNegative }
    public let id: String
    public let name: String
    public let category: String
    public let kind: Kind
    public let referenceIlluminant: String
    public let viewingIlluminant: String
    public let logSensitivity: [SIMD3<Double>]
    public let dyeDensity: [SIMD3<Double>]
    public let baseDensity: [Double]
    public let logExposure: [Double]
    public let densityCurves: [SIMD3<Double>]
    public let grain: GrainCharacter
    /// Back-reflection halation strength per layer (R, G, B) and its first radius in µm.
    public let halation: SIMD3<Double>
    public let halationRadius: Double
    public let defaultPaper: String?
    public let note: String
}

public struct PrintPaper: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isBlackAndWhite: Bool
    public let referenceIlluminant: String
    public let viewingIlluminant: String
    public let logSensitivity: [SIMD3<Double>]
    public let dyeDensity: [SIMD3<Double>]
    public let baseDensity: [Double]
    public let logExposure: [Double]
    public let densityCurves: [SIMD3<Double>]
}

/// The film stocks and papers Positives can simulate.
///
/// Colour stocks and papers: spektrafilm profiles by Andrea Volpato (CC BY-SA 4.0), built from the
/// manufacturers' datasheets (spectral sensitivities, dye densities, characteristic curves).
/// Black & white stocks: built here from Ilford / Kodak datasheet characteristics (spectral sensitivity
/// shape, characteristic curve in standard developer) — an approximation, documented as such.
public final class FilmLibrary: @unchecked Sendable {
    public static let shared = FilmLibrary()

    public let films: [FilmStock]
    public let papers: [PrintPaper]
    public let cmf: [SIMD3<Double>]
    public let daylightBasis: [SIMD3<Double>]
    public let kg3: [Double]
    public let attribution: String

    public func film(_ id: String?) -> FilmStock? { id.flatMap { i in films.first { $0.id == i } } }
    public func paper(_ id: String?) -> PrintPaper? { id.flatMap { i in papers.first { $0.id == i } } }
    public var categories: [String] { var seen: [String] = []; for f in films where !seen.contains(f.category) { seen.append(f.category) }; return seen }

    private struct File: Decodable {
        var about: String
        var cmf: [[Double]]
        var daylightBasis: [[Double]]
        var kg3: [Double]
        var films: [Stock]
        var papers: [Stock]
    }
    private struct Stock: Decodable {
        var id: String, name: String, category: String, type: String
        var referenceIlluminant: String, viewingIlluminant: String
        var logSensitivity: [[Double]], dyeDensity: [[Double]], baseDensity: [Double]
        var logExposure: [Double], densityCurves: [[Double]]
    }

    private init() {
        let url = Bundle.module.url(forResource: "FilmData", withExtension: "json")!
        let f = try! JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        func v3(_ a: [[Double]]) -> [SIMD3<Double>] { a.map { SIMD3($0[0], $0[1], $0[2]) } }
        cmf = v3(f.cmf)
        daylightBasis = v3(f.daylightBasis)
        kg3 = f.kg3
        attribution = f.about
        var films: [FilmStock] = f.films.map { s in
            let kind: FilmStock.Kind = s.type == "positive" ? .slide : .colorNegative
            let c = Self.character(s.id)
            return FilmStock(id: s.id, name: s.name, category: s.category, kind: kind,
                             referenceIlluminant: s.referenceIlluminant, viewingIlluminant: s.viewingIlluminant,
                             logSensitivity: v3(s.logSensitivity), dyeDensity: v3(s.dyeDensity), baseDensity: s.baseDensity,
                             logExposure: s.logExposure, densityCurves: v3(s.densityCurves),
                             grain: c.grain, halation: c.halation, halationRadius: c.halationRadius,
                             defaultPaper: kind == .slide ? nil : (s.id.hasPrefix("fujifilm") ? "fujifilm_crystal_archive_typeii" : "kodak_portra_endura"),
                             note: c.note)
        }
        films += Self.blackAndWhiteFilms()
        self.films = films
        papers = f.papers.map { s in
            PrintPaper(id: s.id, name: s.name, isBlackAndWhite: false, referenceIlluminant: s.referenceIlluminant,
                       viewingIlluminant: s.viewingIlluminant, logSensitivity: v3(s.logSensitivity), dyeDensity: v3(s.dyeDensity),
                       baseDensity: s.baseDensity, logExposure: s.logExposure, densityCurves: v3(s.densityCurves))
        } + [Self.multigradePaper()]
    }

    // MARK: Per-stock character (grain, halation)

    private struct Character { var grain: GrainCharacter; var halation: SIMD3<Double>; var halationRadius: Double; var note: String }

    /// Granularity from datasheets where published (RMS × 1000), otherwise estimated from Kodak's print grain
    /// index; grain sizes chosen per family. Halation: films with an anti-halation layer get a faint
    /// halo; Vision3 stocks shot as CineStill (remjet removed) get the strong red glow they are known for.
    private static func character(_ id: String) -> Character {
        let ah = SIMD3<Double>(0.035, 0.010, 0), cine = SIMD3<Double>(0.30, 0.09, 0.008)
        func neg(_ g: Double, _ rough: Double = 0.6, _ note: String) -> Character {
            Character(grain: GrainCharacter(granularity: g, coarseRadius: 6.0, fineRadius: 1.3, roughness: rough, colour: 0.35),
                      halation: ah, halationRadius: 65, note: note)
        }
        func slide(_ g: Double, _ note: String) -> Character {
            Character(grain: GrainCharacter(granularity: g, coarseRadius: 4.5, fineRadius: 1.0, roughness: 0.45, colour: 0.3),
                      halation: ah * 0.8, halationRadius: 60, note: note)
        }
        switch id {
        case "kodak_portra_160": return neg(8, 0.5, "Soft, natural skin tones, very fine grain.")
        case "kodak_portra_400": return neg(11, 0.55, "The classic: warm, gentle contrast, forgiving highlights.")
        case "kodak_portra_800": return neg(14, 0.6, "Warmer and grainier, made for low light.")
        case "kodak_portra_800_push1": return neg(17, 0.68, "Pushed one stop: more contrast and grain.")
        case "kodak_gold_200": return neg(12, 0.6, "Golden, nostalgic consumer colour.")
        case "kodak_ultramax_400": return neg(14, 0.65, "Punchy consumer colour, visible grain.")
        case "kodak_ektar_100": return neg(6, 0.45, "Vivid, saturated, the finest-grained colour negative.")
        case "fujifilm_c200": return neg(13, 0.6, "Fresh greens and cool shadows.")
        case "fujifilm_xtra_400": return neg(14, 0.62, "Fujicolor Superia: green-leaning, contrasty, grainy.")
        case "fujifilm_pro_400h": return neg(11, 0.55, "Airy pastels and soft greens.")
        case "kodak_vision3_500t":
            return Character(grain: GrainCharacter(granularity: 13, coarseRadius: 6.5, fineRadius: 1.4, roughness: 0.6, colour: 0.4),
                             halation: cine, halationRadius: 110, note: "Tungsten-balanced cinema film without its remjet layer: red halation around lights.")
        case "kodak_vision3_250d":
            return Character(grain: GrainCharacter(granularity: 9, coarseRadius: 5.5, fineRadius: 1.2, roughness: 0.55, colour: 0.35),
                             halation: cine * 0.8, halationRadius: 100, note: "Daylight cinema film, wide latitude.")
        case "kodak_vision3_50d":
            return Character(grain: GrainCharacter(granularity: 6, coarseRadius: 5.0, fineRadius: 1.1, roughness: 0.45, colour: 0.35),
                             halation: cine * 0.7, halationRadius: 95, note: "Daylight cinema film, extremely fine grain.")
        case "kodak_kodachrome_64": return slide(9, "Deep reds and blues, dense shadows — the National Geographic look.")
        case "kodak_ektachrome_100": return slide(8, "Clean, neutral-to-cool slide film.")
        case "fujifilm_velvia_100": return slide(8, "Extremely saturated landscapes.")
        case "fujifilm_provia_100f": return slide(8, "Accurate, neutral slide film.")
        default: return neg(11, 0.55, "")
        }
    }

    // MARK: Black & white (datasheet approximations)

    /// Characteristic curve of a B&W negative: base + fog excluded; a toe, a straight section of slope γ and a
    /// very late shoulder. x = log exposure relative to middle grey.
    private static func bwCurve(_ x: Double, gamma: Double, toe: Double, speedPoint: Double, dmax: Double) -> Double {
        let s = toe
        let linear = gamma * s * log(1 + exp((x - speedPoint) / s))
        // Straight line up to high densities, then a late shoulder towards dmax (B&W negatives barely shoulder).
        return linear / pow(1 + pow(linear / dmax, 4), 0.25)
    }

    private static func bwStock(id: String, name: String, cutoff: Double, dip: Double, gamma: Double, toe: Double,
                                speed: Double, base: Double, grain: GrainCharacter, note: String) -> FilmStock {
        let wl = Spectral.wavelengths
        // Panchromatic sensitivity: flat in the blue and green with a shallow dip near 500 nm, extended red to
        // `cutoff`, then a steep fall (datasheet wedge spectrograms).
        let sens = wl.map { w -> SIMD3<Double> in
            var l = -dip * exp(-pow((w - 500) / 25, 2))
            if w < 400 { l -= (400 - w) / 40 }
            if w > cutoff { l -= pow((w - cutoff) / 12, 2) }
            return SIMD3(repeating: l)
        }
        let logE = (0..<256).map { -3 + 7 * Double($0) / 255 }
        let curve = logE.map { SIMD3(repeating: bwCurve($0, gamma: gamma, toe: toe, speedPoint: speed, dmax: 3.0)) }
        return FilmStock(id: id, name: name, category: "Black & white", kind: .bwNegative,
                         referenceIlluminant: "D55", viewingIlluminant: "D50",
                         logSensitivity: sens, dyeDensity: Array(repeating: SIMD3(repeating: 1.0 / 3), count: Spectral.count),
                         baseDensity: Array(repeating: base, count: Spectral.count),
                         logExposure: logE, densityCurves: curve, grain: grain,
                         halation: SIMD3(repeating: 0.025), halationRadius: 60, defaultPaper: "ilford_multigrade", note: note)
    }

    private static func blackAndWhiteFilms() -> [FilmStock] {
        [
            bwStock(id: "ilford_hp5_plus", name: "Ilford HP5 Plus 400", cutoff: 655, dip: 0.12, gamma: 0.62, toe: 0.28, speed: -1.15, base: 0.28,
                    grain: GrainCharacter(granularity: 16, coarseRadius: 5.0, fineRadius: 1.1, roughness: 0.7, colour: 0),
                    note: "Classic press film: soft tonality, open shadows, generous grain. (Built from Ilford's datasheet.)"),
            bwStock(id: "kodak_trix_400", name: "Kodak Tri-X 400", cutoff: 640, dip: 0.08, gamma: 0.70, toe: 0.22, speed: -1.1, base: 0.27,
                    grain: GrainCharacter(granularity: 17, coarseRadius: 5.5, fineRadius: 1.1, roughness: 0.75, colour: 0),
                    note: "Gritty, punchy, the street-photography look. (Built from Kodak's datasheet.)"),
            bwStock(id: "ilford_delta_3200", name: "Ilford Delta 3200", cutoff: 670, dip: 0.05, gamma: 0.58, toe: 0.32, speed: -1.25, base: 0.32,
                    grain: GrainCharacter(granularity: 44, coarseRadius: 7.0, fineRadius: 1.4, roughness: 0.8, colour: 0),
                    note: "Very fast, low-contrast, big grain. (Built from Ilford's datasheet.)"),
        ]
    }

    /// Variable-contrast fibre/RC paper around grade 2, neutral silver image (datasheet approximation).
    private static func multigradePaper() -> PrintPaper {
        let logE = (0..<256).map { -3 + 7 * Double($0) / 255 }
        let curve = logE.map { x -> SIMD3<Double> in
            let d = 2.1 / (1 + exp(-(x - 0.0) / 0.24))
            return SIMD3(repeating: d)
        }
        return PrintPaper(id: "ilford_multigrade", name: "Ilford Multigrade (grade 2)", isBlackAndWhite: true,
                          referenceIlluminant: "TH-KG3", viewingIlluminant: "D50",
                          logSensitivity: Array(repeating: SIMD3(repeating: 0), count: Spectral.count),
                          dyeDensity: Array(repeating: SIMD3(repeating: 1.0 / 3), count: Spectral.count),
                          baseDensity: Array(repeating: 0.04, count: Spectral.count),
                          logExposure: logE, densityCurves: curve)
    }
}
