import Foundation
import simd

/// Per-roll description of how the film's three dye layers relate to each other.
///
/// A colour negative's layers obey (on the straight part of the characteristic curve)
///
///     D_c = γ_c · log10(E_c) + β_c        for channel c ∈ {R, G, B}
///
/// with a *different* gamma γ_c per layer. Undoing only an offset (a "white balance") therefore leaves
/// different casts in shadows and highlights. We remove both differences by mapping every channel onto
/// the green layer's density scale:
///
///     e_c = D_c / r_c − o_c,      r_c = γ_c / γ_G,   o_c = β_c/r_c − β_G    (r_G = 1, o_G = 0)
///
/// For any neutral grey the three `e_c` are then equal at *every* exposure level, not just one point.
/// `r` and `o` are measured once per roll (see `Estimators`) because they belong to the film stock and
/// its development, not to the scene.
public struct FilmCalibration: Codable, Equatable, Sendable {
    /// Gamma ratio of each layer relative to green.
    public var gammaRatio: SIMD3<Double>
    /// Density offset of each layer (green-equivalent units) relative to green.
    public var offset: SIMD3<Double>
    /// The neutral path, when measured as a curve: points (D_G, D_R − D_G, D_B − D_G) of neutral greys in
    /// ascending D_G, starting at the base (0, 0, 0). The film's toe and shoulder and a camera's overlapping
    /// filters bend this path, so a straight line (gamma ratio and offset) only approximates it; when present,
    /// it replaces them: each channel's density is mapped onto green's scale through the path.
    public var neutral: [SIMD3<Double>]?

    public init(gammaRatio: SIMD3<Double> = [1, 1, 1], offset: SIMD3<Double> = [0, 0, 0], neutral: [SIMD3<Double>]? = nil) {
        self.gammaRatio = gammaRatio
        self.offset = offset
        self.neutral = neutral
    }

    /// Green-scale value of channel `c` (0 = R, 2 = B) density `d` through the neutral path: the inverse of
    /// D_c(g) = g + path_c(g), piecewise linear, extended along the end segments.
    @inline(__always) public static func throughPath(_ d: Double, _ path: [SIMD3<Double>], channel c: Int) -> Double {
        let n = path.count
        guard n >= 2 else { return d }
        func x(_ k: Int) -> Double { path[k].x + path[k][c == 0 ? 1 : 2] }
        var k = 0
        while k < n - 2 && d > x(k + 1) { k += 1 }
        let x0 = x(k), x1 = x(k + 1)
        let t = (d - x0) / max(x1 - x0, 1e-9)
        return path[k].x + t * (path[k + 1].x - path[k].x)
    }

    public static let identity = FilmCalibration()

    /// Calibration that makes two neutral references (shadow and highlight densities, base-normalised) neutral.
    public static func from(shadow lo: SIMD3<Double>, highlight hi: SIMD3<Double>) -> FilmCalibration {
        let range = hi - lo
        let r = SIMD3(range.x / range.y, 1, range.z / range.y)
        let o = lo / r - SIMD3(repeating: lo.y)
        return FilmCalibration(gammaRatio: r, offset: SIMD3(o.x, 0, o.z))
    }

    @inline(__always) public func equivalentDensity(_ d: SIMD3<Double>) -> SIMD3<Double> {
        if let p = neutral, p.count >= 2 {
            return SIMD3(Self.throughPath(d.x, p, channel: 0), d.y, Self.throughPath(d.z, p, channel: 2))
        }
        return d / gammaRatio - offset
    }

    /// Most points the GPU kernel takes for the neutral path.
    public static let maxPathPoints = 12

    /// Colour model in equivalent-density space (rows sum to 1, so greys and lightness are untouched): undoes
    /// how a camera's filters see the film's dyes — their absorptions overlap the camera's bands differently
    /// from a lab scanner's narrow ones. Fitted with the test bench (negatives-bench fitcolor) over nine colour
    /// stocks, three camera sensitivities and three light sources against the original scenes: colour error
    /// 5.1 → 3.2 (OKLab chroma ×100).
    public static let colourModel = simd_double3x3(rows: [
        SIMD3(0.8006, -0.0371, 0.2365),
        SIMD3(0.1904, 0.5641, 0.2455),
        SIMD3(0.0090, 0.4730, 0.5180),
    ])
}

/// Every number the conversion needs, fully resolved. This is exactly what the GPU kernel receives;
/// `NegativeModel.positive` is the reference implementation the GPU is tested against.
public struct ConversionParameters: Equatable, Sendable {
    /// Film base (D-min) in camera RGB, after flat-field. Defines transmittance T = 1.
    public var filmBase: SIMD3<Double>
    public var calibration: FilmCalibration
    /// Green-equivalent density that maps to scene-linear 1.0 (≈ diffuse white).
    public var referenceDensity: Double
    /// Average film gamma (C-41 ≈ 0.6). Converts density differences to scene log exposure.
    public var filmGamma: Double
    public var monochrome: Bool
    /// Weights for combining the three equivalent densities in black & white mode (sum to 1).
    public var monochromeWeights: SIMD3<Double>
    /// Camera RGB (balanced, neutral = equal values) -> linear Rec.2020, white balance included.
    public var colorMatrix: simd_double3x3
    public var curve: PrintCurve.Resolved
    /// See `FilmCalibration.colourModel` (identity = off).
    public var colourModel = FilmCalibration.colourModel

    public init(filmBase: SIMD3<Double>, calibration: FilmCalibration, referenceDensity: Double, filmGamma: Double,
                monochrome: Bool, monochromeWeights: SIMD3<Double>, colorMatrix: simd_double3x3, curve: PrintCurve.Resolved) {
        self.filmBase = filmBase
        self.calibration = calibration
        self.referenceDensity = referenceDensity
        self.filmGamma = filmGamma
        self.monochrome = monochrome
        self.monochromeWeights = monochromeWeights
        self.colorMatrix = colorMatrix
        self.curve = curve
    }
}

/// The negative → positive model, as scalar reference functions (Double precision).
///
///  1. Transmittance          T_c = max(I_c / base_c, 10⁻⁴)              (I = flat-fielded camera RGB)
///  2. Density                D_c = −log10(T_c)                            (0 at the film base)
///  3. Neutral-lock           e_c = D_c / r_c − o_c                        (see FilmCalibration)
///     B&W                    e_c = Σ w_k e_k  for all c
///  4. Scene-linear           L_c = 10^((e_c − e_ref) / γ_film)            (camera-balanced RGB, white ≈ 1)
///  5. Colour                 P   = M · L                                  (camera → Rec.2020 · white balance)
///  6. Print                  Y_c = PrintCurve(P_c)                        (display-linear Rec.2020)
///
/// Nothing is clipped in the image range: T has a floor at density 4 above the base, beyond what any film
/// can record (colour negatives reach ≈ 3); below it there is only sensor noise, which would otherwise
/// explode into absurd scene values. The print curve approaches paper black/white asymptotically.
public enum NegativeModel {
    public static let transmittanceFloor = 1e-4

    @inline(__always) public static func density(_ camera: SIMD3<Double>, base: SIMD3<Double>) -> SIMD3<Double> {
        let t = simd_max(camera / base, SIMD3(repeating: transmittanceFloor))
        return SIMD3(-log10(t.x), -log10(t.y), -log10(t.z))
    }

    /// Steps 1–3 (and the colour model).
    @inline(__always) public static func equivalentDensity(_ camera: SIMD3<Double>, _ p: ConversionParameters) -> SIMD3<Double> {
        var e = p.calibration.equivalentDensity(density(camera, base: p.filmBase))
        if p.monochrome { e = SIMD3(repeating: simd_dot(e, p.monochromeWeights)) } else { e = p.colourModel * e }
        return e
    }

    /// Steps 1–4: scene-linear light in balanced camera RGB.
    public static func sceneLinearCamera(_ camera: SIMD3<Double>, _ p: ConversionParameters) -> SIMD3<Double> {
        let e = equivalentDensity(camera, p)
        let k = 1 / p.filmGamma
        return SIMD3(pow(10, (e.x - p.referenceDensity) * k), pow(10, (e.y - p.referenceDensity) * k), pow(10, (e.z - p.referenceDensity) * k))
    }

    /// Steps 1–5: scene-linear Rec.2020 (white balanced). This is what 32-bit "scene" export contains.
    public static func sceneLinear(_ camera: SIMD3<Double>, _ p: ConversionParameters) -> SIMD3<Double> {
        let l = sceneLinearCamera(camera, p)
        return p.monochrome ? l : p.colorMatrix * l
    }

    /// Steps 1–6: display-linear Rec.2020.
    public static func positive(_ camera: SIMD3<Double>, _ p: ConversionParameters) -> SIMD3<Double> {
        let s = sceneLinear(camera, p)
        return SIMD3(PrintCurve.apply(s.x, p.curve), PrintCurve.apply(s.y, p.curve), PrintCurve.apply(s.z, p.curve))
    }
}
