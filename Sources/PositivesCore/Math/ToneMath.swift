import Foundation
import simd

/// The per-pixel formulas of the editor, in Float, exactly as the GPU evaluates them (`Kernels.swift`
/// mirrors every function here line by line; tests compare the two). Documented here so the maths lives
/// in one readable place.
///
/// Domains
/// - scene-linear: linear Rec.2020 light, after white balance and exposure, unbounded (> 1 is fine).
/// - display-linear: linear Rec.2020 after the tone profile; 0…1 is the displayable range.
/// - perceptual: p = sign(y)·|y|^(1/2.2) of a display-linear value, where "contrast", "whites" and
///   "blacks" are defined (so the controls feel even across the tonal range).
public enum ToneMath {
    /// Rec.2020 luminance weights.
    public static let luminance = SIMD3<Float>(0.2627, 0.6780, 0.0593)
    public static let middleGrey: Float = 0.18

    @inline(__always) public static func lum(_ c: SIMD3<Float>) -> Float { simd_dot(c, luminance) }

    /// Linear sRGB <-> linear Rec.2020 (both D65).
    public static let srgbToRec2020 = simd_float3x3(rows: [SIMD3(0.6274040, 0.3292820, 0.0433136),
                                                           SIMD3(0.0690970, 0.9195400, 0.0113612),
                                                           SIMD3(0.0163916, 0.0880132, 0.8955950)])
    public static let rec2020ToSRGB = srgbToRec2020.inverse
    /// The sRGB transfer function (0…1).
    @inline(__always) public static func srgbEncode(_ x: Float) -> Float { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    @inline(__always) public static func srgbDecode(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }

    // MARK: - Display shoulder (profile "Original", display-referred files)

    /// Knee of the shoulder: values below are untouched.
    public static let knee: Float = 0.5

    /// Maps [0, ∞) onto [0, 1): identity below the knee, then an exponential roll-off with matching slope:
    ///     S(x) = x                                       x ≤ k
    ///     S(x) = 1 − (1 − k) · exp(−(x − k) / (1 − k))    x > k
    /// A display-referred file is first taken through S⁻¹ ("un-rendered") so exposure, highlights … can push
    /// values beyond 1 and S rolls them back smoothly instead of clipping. With no adjustment S(S⁻¹(y)) = y.
    @inline(__always) public static func shoulder(_ x: Float) -> Float {
        x <= knee ? x : 1 - (1 - knee) * exp(-(x - knee) / (1 - knee))
    }

    /// Exact inverse of `shoulder` on [0, 1]; 1.0 maps to the largest finite value (2⁻²⁴ below 1).
    @inline(__always) public static func shoulderInverse(_ y: Float) -> Float {
        y <= knee ? y : knee - (1 - knee) * log(max((1 - y) / (1 - knee), 5.96e-8))
    }

    public static func shoulderInverse(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(shoulderInverse(c.x), shoulderInverse(c.y), shoulderInverse(c.z))
    }

    // MARK: - Print curve profiles (RAF)

    /// The print-curve shapes behind the RAF profiles (see `PrintCurve` for the formula).
    public static func printCurve(for profile: ToneProfile) -> PrintCurve? {
        switch profile {
        case .standard: return PrintCurve(exposure: 0, contrast: 1.32, toe: 0.36, shoulder: 0.3, paperDmax: 3.6)
        case .flat: return PrintCurve(exposure: 0, contrast: 0.95, toe: 0.6, shoulder: 0.55, paperDmax: 3.6)
        case .linear, .original: return nil
        }
    }

    /// Print curve in Float with an odd extension for negative (out-of-gamut) components.
    @inline(__always) public static func printCurve(_ v: Float, _ r: PrintCurve.Resolved) -> Float {
        let a = abs(v)
        let x = log2(max(a, 1e-10) / middleGrey) + Float(r.exposure)
        let y: Float
        let slope = Float(r.slope), y0 = Float(r.y0), aH = Float(r.aHigh), aL = Float(r.aLow)
        if x >= 0 {
            y = y0 + aH * g(slope * x / aH, Float(r.kShoulder))
        } else {
            y = y0 - aL * g(-slope * x / aL, Float(r.kToe))
        }
        let out = Float(pow(10.0, Double(y)))
        return v < 0 ? -out : out
    }

    @inline(__always) static func g(_ t: Float, _ k: Float) -> Float { t / pow(1 + pow(t, k), 1 / k) }

    // MARK: - Perceptual controls

    public static let gammaP: Float = 2.2
    @inline(__always) public static func toPerceptual(_ y: Float) -> Float { y < 0 ? -pow(-y, 1 / gammaP) : pow(y, 1 / gammaP) }
    @inline(__always) public static func fromPerceptual(_ p: Float) -> Float { p < 0 ? -pow(-p, gammaP) : pow(p, gammaP) }
    /// Middle grey in perceptual units (pivot of the contrast curve).
    public static var pivot: Float { pow(middleGrey, 1 / gammaP) }

    /// Contrast c ∈ [−1, 1]: an S-curve through 0, the pivot and 1, slope k = 2^(0.9c) at the pivot.
    ///     p ≤ p0: p0 · (p / p0)^k
    ///     p > p0: 1 − (1 − p0) · ((1 − p) / (1 − p0))^k
    /// Values outside [0, 1] (out-of-range light) pass through unchanged.
    @inline(__always) public static func contrast(_ p: Float, k: Float) -> Float {
        let p0 = pivot
        if p <= 0 || p >= 1 { return p }
        return p <= p0 ? p0 * pow(p / p0, k) : 1 - (1 - p0) * pow((1 - p) / (1 - p0), k)
    }

    /// Whites w and blacks b ∈ [−1, 1] move the ends of the tonal range:
    ///     p' = p + 0.2 · w · p⁴ + 0.2 · b · (1 − p)⁴     (on 0 ≤ p ≤ 1; monotonic for |w|, |b| ≤ 1)
    @inline(__always) public static func whitesBlacks(_ p: Float, whites w: Float, blacks b: Float) -> Float {
        let q = min(max(p, 0), 1)
        let q2 = q * q, r = 1 - q, r2 = r * r
        return p + 0.2 * w * q2 * q2 + 0.2 * b * r2 * r2
    }

    /// Fujifilm-style highlight / shadow tone (−2 soft … +4 hard): a bump in the upper half of the perceptual
    /// range (raised for positive highlight) and in the lower half (lowered for positive shadow); black, the
    /// middle of the range and white stay put.
    @inline(__always) public static func recipeTone(_ p: Float, highlight h: Float, shadow s: Float) -> Float {
        guard p > 0, p < 1 else { return p }
        if p > 0.5 {
            let t = (p - 0.5) * 2
            return p + 0.035 * h * 4 * t * (1 - t)
        }
        let t = p * 2
        return p - 0.035 * s * 4 * t * (1 - t)
    }

    /// Dynamic range (DR200 / DR400): gain that compresses scene highlights above +1.5 EV by the factor
    /// (1 − d) in stops, smoothly (softplus knee), so one / two more stops of highlights fit; middle grey and
    /// everything below are left alone.
    @inline(__always) public static func dynamicRange(_ y: Float, _ d: Float) -> Float {
        let x = log2(max(y, 1e-6) / middleGrey)
        let z = 3 * (x - 1.5)
        let sp = (z > 20 ? z : log(1 + exp(z))) / 3
        return exp2(-d * sp)
    }

    /// Tone of the picture handed to a film look's table, in perceptual units: the tables were made for
    /// camera-like renderings, whose shadows are deeper and upper tones brighter than Positives' neutral
    /// rendering. Fitted (monotone spline) to the tone percentiles of X-E4 RAFs against the camera's JPEGs;
    /// middle tones unchanged.
    public static let lookInputPoints = [CurvePoint(0, 0), CurvePoint(0.078, 0.035), CurvePoint(0.13, 0.07), CurvePoint(0.27, 0.27),
                                         CurvePoint(0.62, 0.66), CurvePoint(0.79, 0.81), CurvePoint(1, 1)]
    public static let lookInputTable: [Float] = (0...256).map { Float(CurveMath.evaluate(lookInputPoints, Double($0) / 256)) }

    @inline(__always) public static func lookInput(_ q: Float) -> Float {
        if q <= 0 { return q }
        if q >= 1 { return q }
        let f = q * 256
        let i = min(Int(f), 255)
        let t = f - Float(i)
        return lookInputTable[i] + (lookInputTable[i + 1] - lookInputTable[i]) * t
    }

    /// The same on a display-linear colour (per channel, perceptual units).
    public static func lookInput(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(fromPerceptual(lookInput(toPerceptual(c.x))), fromPerceptual(lookInput(toPerceptual(c.y))), fromPerceptual(lookInput(toPerceptual(c.z))))
    }

    // MARK: - Local tone (shadows / highlights / clarity / texture)

    /// Exposure change in stops given to a pixel whose local (edge-aware smoothed) brightness is B stops
    /// from middle grey. Smooth logistic weights select the dark and the bright parts of the picture:
    ///     Δ = 2.0 · S · w_s(B) + 1.6 · H · w_h(B)
    ///     w_s(B) = 1 / (1 + exp(1.2 · (B + 1.4))),   w_h(B) = 1 / (1 + exp(−1.2 · (B − 1.0)))
    /// Because Δ depends on the local base, not the pixel, fine detail inside a region keeps its contrast.
    @inline(__always) public static func shadowsHighlights(base b: Float, shadows s: Float, highlights h: Float) -> Float {
        let ws = 1 / (1 + exp(1.2 * (b + 1.4)))
        let wh = 1 / (1 + exp(-1.2 * (b - 1.0)))
        return 2.0 * s * ws + 1.6 * h * wh
    }

    /// Local contrast added (stops) for a detail d (pixel − smoothed, in stops), gain g, bounded to ±2 stops
    /// so extreme edges can never explode: 2 · tanh(g · d / 2).
    @inline(__always) public static func detailBoost(_ d: Float, gain: Float) -> Float {
        2 * tanh(gain * d / 2)
    }

    /// Clarity weight: full in the mid-tones, 40 % at the extremes, from the local base B.
    @inline(__always) public static func clarityWeight(base b: Float) -> Float {
        let t = b / 3
        return 0.4 + 0.6 / (1 + t * t * t * t)
    }

    // MARK: - OKLab (Ottosson 2020), from linear Rec.2020

    /// Linear Rec.2020 -> LMS (OKLab M1 composed with Rec.2020 -> XYZ).
    public static let toLMS: simd_float3x3 = {
        let m1 = simd_double3x3(rows: [
            SIMD3(0.8189330101, 0.3618667424, -0.1288597137),
            SIMD3(0.0329845436, 0.9293118715, 0.0361456387),
            SIMD3(0.0482003018, 0.2643662691, 0.6338517070),
        ])
        // Normalised so D65 white has LMS = (1, 1, 1), i.e. is exactly neutral (a = b = 0).
        let m = m1 * ColorScience.rec2020.toXYZ
        let w = m * SIMD3<Double>(1, 1, 1)
        return simd_float3x3(simd_double3x3(diagonal: 1 / w) * m)
    }()
    public static let fromLMS: simd_float3x3 = toLMS.inverse
    public static let lmsToLab = simd_float3x3(rows: [
        SIMD3(0.2104542553, 0.7936177850, -0.0040720468),
        SIMD3(1.9779984951, -2.4285922050, 0.4505937099),
        SIMD3(0.0259040371, 0.7827717662, -0.8086757660),
    ])
    public static let labToLMS: simd_float3x3 = lmsToLab.inverse

    @inline(__always) static func cbrtSigned(_ x: Float) -> Float { x < 0 ? -pow(-x, 1 / 3) : pow(x, 1 / 3) }

    public static func oklab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let l = toLMS * rgb
        return lmsToLab * SIMD3(cbrtSigned(l.x), cbrtSigned(l.y), cbrtSigned(l.z))
    }

    public static func fromOklab(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l = labToLMS * lab
        return fromLMS * (l * l * l)
    }

    /// Keeps the lightness and chroma of `after` but restores the hue of `before` (hue-preserving tone curves).
    public static func preserveHue(before: SIMD3<Float>, after: SIMD3<Float>) -> SIMD3<Float> {
        let a = oklab(before), b = oklab(after)
        let ca = simd_length(SIMD2(a.y, a.z)), cb = simd_length(SIMD2(b.y, b.z))
        guard ca > 1e-5 else { return after }
        let dir = SIMD2(a.y, a.z) / ca
        return fromOklab(SIMD3(b.x, dir.x * cb, dir.y * cb))
    }

    // MARK: - Saturation / vibrance (OKLab chroma)

    /// Chroma multiplier. Vibrance favours muted colours and spares skin hues; saturation is uniform.
    @inline(__always) public static func chromaGain(chroma c: Float, hue h: Float, saturation s: Float, vibrance v: Float) -> Float {
        var f: Float = 1
        if v > 0 {
            let t = min(max(c / 0.22, 0), 1), muted = 1 - t * t * (3 - 2 * t)
            let dh = (h - 0.87) / 0.45                                   // skin ≈ 50° in OKLab
            let skin = exp(-dh * dh)
            f += v * muted * (1 - 0.45 * skin)
        } else if v < 0 {
            let t = min(max(c / 0.2, 0), 1)
            f += v * (0.5 + 0.5 * t * t * (3 - 2 * t))
        }
        return max(0, f * (1 + s))
    }
}
