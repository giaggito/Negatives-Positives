import Foundation
import simd

/// Film simulation choices for one photo.
public struct FilmSettings: Codable, Equatable, Sendable {
    /// Stock id from `FilmLibrary`, nil = no film (digital rendering).
    public var stock: String?
    /// Print paper for negatives, nil = the stock's usual paper.
    public var paper: String?
    /// 0…100: blend between the digital rendering and the film.
    public var intensity: Double = 100
    /// Print filtration, −100…+100: warmth (blue ↔ yellow) and tint (green ↔ magenta).
    public var warmth: Double = 0
    public var tint: Double = 0
    /// Halation in percent of the stock's (CineStill-style red glow around highlights).
    public var halation: Double = 100
    /// Lab variant of the look: −1, 0 (standard), +1, +2 (see `FilmLook.variants`).
    public var variant: Int = 0
    /// Lens filter for black & white looks.
    public var bwFilter: BWFilter = .none
    public init() {}

    /// Print filtration as gains on scene light (luminance kept): warmth blue ↔ yellow, tint green ↔ magenta.
    public static func balance(warmth: Double, tint: Double) -> SIMD3<Float> {
        let w = warmth / 100, t = tint / 100
        var g = SIMD3<Double>(pow(2, 0.35 * w), pow(2, -0.3 * t), pow(2, -0.45 * w))
        let y = 0.2627 * g.x + 0.6780 * g.y + 0.0593 * g.z
        g /= y
        return SIMD3<Float>(g)
    }

    public var isActive: Bool { stock != nil && intensity > 0 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stock = try c.decodeIfPresent(String.self, forKey: .stock)
        paper = try c.decodeIfPresent(String.self, forKey: .paper)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 100
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        halation = try c.decodeIfPresent(Double.self, forKey: .halation) ?? 100
        variant = try c.decodeIfPresent(Int.self, forKey: .variant) ?? 0
        bwFilter = (try? c.decodeIfPresent(BWFilter.self, forKey: .bwFilter)) ?? .none
    }
}

public enum FilmFormat: String, Codable, CaseIterable, Sendable {
    case f35 = "35mm", f645 = "6x4.5", f66 = "6x6", f67 = "6x7", f45 = "4x5"

    /// Long side of the exposed frame in millimetres.
    public var longSideMM: Double {
        switch self {
        case .f35: return 36
        case .f645: return 56
        case .f66: return 56
        case .f67: return 70
        case .f45: return 121
        }
    }

    public var displayName: String {
        switch self {
        case .f35: return "35 mm"
        case .f645: return "6×4.5"
        case .f66: return "6×6"
        case .f67: return "6×7"
        case .f45: return "4×5 in"
        }
    }
}

/// Grain: a property of the film (or of a neutral virtual film when no stock is chosen).
public struct GrainSettings: Codable, Equatable, Sendable {
    /// 0…200 % of the stock's granularity (0 = off).
    public var amount: Double = 0
    /// 25…400 % of the stock's grain size.
    public var size: Double = 100
    /// 0…100, nil = the stock's: clumpy (coarse grains) vs even.
    public var roughness: Double?
    /// 0…100, nil = the stock's: monochrome vs independent colour grain.
    public var colour: Double?
    /// 0…100: optical softness of the emulsion (light scattering), so grain replaces digital crispness.
    public var softness: Double = 50
    public var format: FilmFormat = .f35
    /// Changes the grain pattern only (same character).
    public var seed: UInt32 = 1
    /// Grain character preset (`GrainPreset.id`); nil = the film stock's own (ISO 400 without a stock).
    public var preset: String?
    public init() {}

    public var isActive: Bool { amount > 0 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 100
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness)
        colour = try c.decodeIfPresent(Double.self, forKey: .colour)
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? 50
        format = (try? c.decodeIfPresent(FilmFormat.self, forKey: .format)) ?? .f35
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed) ?? 1
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
    }
}

/// Grain presets: ISO character on a neutral film, independent of colour.
public struct GrainPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let character: GrainCharacter
    /// The film speed alone, for small controls.
    public var shortName: String { String(id.dropFirst(3)) }

    public static let all: [GrainPreset] = [
        GrainPreset(id: "iso100", name: "ISO 100 — fine", character: GrainCharacter(granularity: 7, coarseRadius: 4.5, fineRadius: 1.0, roughness: 0.45, colour: 0.3)),
        GrainPreset(id: "iso400", name: "ISO 400 — classic", character: GrainCharacter(granularity: 12, coarseRadius: 6.0, fineRadius: 1.3, roughness: 0.6, colour: 0.35)),
        GrainPreset(id: "iso800", name: "ISO 800 — visible", character: GrainCharacter(granularity: 16, coarseRadius: 6.8, fineRadius: 1.4, roughness: 0.68, colour: 0.4)),
        GrainPreset(id: "iso3200", name: "ISO 3200 — heavy", character: GrainCharacter(granularity: 26, coarseRadius: 8.0, fineRadius: 1.6, roughness: 0.8, colour: 0.4)),
    ]
}

/// Lens and print effects.
public struct Effects: Codable, Equatable, Sendable {
    public struct Bloom: Codable, Equatable, Sendable {
        /// 0…100.
        public var amount: Double = 0
        /// Stops above middle grey where light starts to glow.
        public var threshold: Double = 2
        /// 0…100: size of the glow (fraction of the picture).
        public var radius: Double = 30
        /// −100…+100: cool ↔ warm glow.
        public var warmth: Double = 20
        public init() {}
    }
    public struct Vignette: Codable, Equatable, Sendable {
        /// −100 (dark corners) … +100 (light corners).
        public var amount: Double = 0
        /// 0…100: where the falloff starts.
        public var midpoint: Double = 50
        /// −100 (rectangular) … +100 (round).
        public var roundness: Double = 0
        /// 0…100: softness of the transition.
        public var feather: Double = 50
        /// 0…100: keep bright areas from darkening.
        public var highlights: Double = 0
        public init() {}
    }
    public var bloom = Bloom()
    public var vignette = Vignette()
    public init() {}
    public var isNeutral: Bool { bloom.amount == 0 && vignette.amount == 0 }
}

/// Fujifilm-style recipe: the in-camera settings photographers combine with a film simulation (dynamic range,
/// highlight and shadow tone, colour, clarity, white balance shift; Color Chrome lives in `EditState.color`).
public struct FilmRecipe: Codable, Equatable, Sendable {
    /// 100, 200 or 400: DR200 / DR400 keep one / two more stops of highlights.
    public var dynamicRange: Int = 100
    /// −2 (soft) … +4 (hard), in half steps: tone of the highlights and of the shadows.
    public var highlight: Double = 0
    public var shadow: Double = 0
    /// −4 … +4: colour saturation; −5 … +5: clarity.
    public var color: Double = 0
    public var clarity: Double = 0
    /// −9 … +9: white balance shift towards red / blue, as on the camera.
    public var redShift: Double = 0
    public var blueShift: Double = 0
    public init() {}
    public var isNeutral: Bool { self == FilmRecipe() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dynamicRange = try c.decodeIfPresent(Int.self, forKey: .dynamicRange) ?? 100
        highlight = try c.decodeIfPresent(Double.self, forKey: .highlight) ?? 0
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        color = try c.decodeIfPresent(Double.self, forKey: .color) ?? 0
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        redShift = try c.decodeIfPresent(Double.self, forKey: .redShift) ?? 0
        blueShift = try c.decodeIfPresent(Double.self, forKey: .blueShift) ?? 0
    }

    /// Highlight compression for the dynamic range setting (see `ToneMath.dynamicRange`).
    public var highlightCompression: Float { dynamicRange >= 400 ? 0.65 : (dynamicRange >= 200 ? 0.4 : 0) }

    /// White-balance shift as gains on scene light (red, blue), luminance kept.
    public var shiftGains: SIMD3<Double> {
        var g = SIMD3<Double>(pow(2, 0.04 * redShift), 1, pow(2, 0.05 * blueShift))
        g /= 0.2627 * g.x + 0.6780 * g.y + 0.0593 * g.z
        return g
    }
}

/// Coloured filters for black & white film, as screwed on the lens: they hold back the light of the other
/// colours, so those turn darker (a red filter makes a blue sky almost black and clouds pop; green lightens
/// foliage and gives natural skin; blue darkens reds and adds haze).
public enum BWFilter: String, Codable, CaseIterable, Sendable {
    case none, yellow, orange, red, green, blue

    public var title: String { self == .none ? "None" : rawValue.capitalized }

    /// Transmittance at 380…780 nm (10 nm steps), shaped after Kodak Wratten filters: #8 yellow, #21 orange,
    /// #25 red, #11 yellow-green, #47 blue.
    public var transmittance: [Double] {
        func step(_ l: Double, _ c: Double, _ w: Double) -> Double { 1 / (1 + exp(-(l - c) / w)) }
        return Spectral.wavelengths.map { l in
            switch self {
            case .none: return 1
            case .yellow: return 0.02 + 0.88 * step(l, 505, 9)
            case .orange: return 0.005 + 0.88 * step(l, 555, 8)
            case .red: return 0.001 + 0.9 * step(l, 600, 7)
            case .green: return 0.03 + 0.72 * step(l, 480, 10) * (1 - step(l, 590, 12)) + 0.22 * step(l, 650, 15)
            case .blue: return 0.01 + 0.6 * (1 - step(l, 505, 10)) * step(l, 395, 8)
            }
        }
    }

    private static let lock = NSLock()
    private static var cache: [BWFilter: simd_float3x3] = [:]

    /// Linear Rec.2020 -> the light the film receives through the filter (3×3, least-squares over natural
    /// reflectance spectra lit by D65), scaled so a neutral grey keeps its luminance (the filter factor is
    /// compensated, as a photographer opens up the lens).
    public var matrix: simd_float3x3 {
        if self == .none { return matrix_identity_float3x3 }
        Self.lock.lock(); defer { Self.lock.unlock() }
        if let m = Self.cache[self] { return m }
        let d65 = Spectral.illuminant("D65")
        let t = transmittance
        let white = Spectral.xyz(d65)
        let toRGB = Spectral.toRec2020(adaptingFrom: white)
        var ata = simd_double3x3(0), atb = simd_double3x3(0)   // normal equations, one column per output channel
        let n = SpectralUpsampling.gridSize
        for j in 0..<n {
            for i in 0..<n {
                guard let coef = SpectralUpsampling.coefficients[i * n + j] ?? nil else { continue }
                let r = SpectralUpsampling.reflectance(coef)
                for scale in [1.0, 0.4] {
                    let plain = toRGB * Spectral.xyz((0..<Spectral.count).map { d65[$0] * r[$0] * scale })
                    let filtered = toRGB * Spectral.xyz((0..<Spectral.count).map { d65[$0] * r[$0] * t[$0] * scale })
                    ata += simd_double3x3(columns: (plain * plain.x, plain * plain.y, plain * plain.z))
                    atb += simd_double3x3(columns: (plain * filtered.x, plain * filtered.y, plain * filtered.z))
                }
            }
        }
        // Rows of F: F = (Aᵀ A)⁻¹ Aᵀ B, transposed.
        let f = (ata.inverse * atb).transpose
        let grey = f * SIMD3<Double>(repeating: 1)
        let y = 0.2627 * grey.x + 0.6780 * grey.y + 0.0593 * grey.z
        let m = simd_float3x3(f * (1 / max(y, 1e-6)))
        Self.cache[self] = m
        return m
    }

    /// What a black & white film records through the filter, as a neutral grey: the film's channel
    /// sensitivity (`weights`) applied to the filtered light, the same value in all three channels — so the
    /// film's table sees an ordinary grey picture and keeps its full tone (a filtered image fed in colour is
    /// pushed outside the table's range and comes out flat). Greys keep their brightness.
    public func greyMatrix(weights: SIMD3<Float>) -> simd_float3x3 {
        if self == .none { return matrix_identity_float3x3 }
        var r = matrix.transpose * weights
        r /= max(r.sum(), 1e-6)
        return simd_float3x3(rows: [r, r, r])
    }
}
