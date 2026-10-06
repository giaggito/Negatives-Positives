import Foundation
import simd

/// Colour adjustments in OKLab (L, a, b), in Float, exactly as the GPU evaluates them (Kernels.swift mirrors
/// these). OKLab is perceptually even: equal steps of hue and chroma look equally large everywhere, and
/// changing chroma does not change perceived lightness — so "more saturation" never also means "darker".
public enum ColorMath {

    @inline(__always) static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Angle wrapped to (−π, π].
    @inline(__always) static func wrap(_ a: Float) -> Float {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x <= -.pi { x += 2 * .pi }
        return x
    }

    // MARK: - Colour mixer (8 ranges)

    /// Centres of the eight ranges, OKLab hue in radians (0…2π, increasing): the sRGB primaries and
    /// secondaries plus orange and purple, so "Red" means the red people expect.
    public static let mixerCentres: [Float] = {
        let srgb: [SIMD3<Double>] = [[1, 0, 0], [1, 0.5, 0], [1, 1, 0], [0, 1, 0], [0, 1, 1], [0, 0, 1], [0.5, 0, 1], [1, 0, 1]]
        let m = simd_float3x3(ColorScience.sRGBToRec2020)
        return srgb.map { e in
            let lin = SIMD3<Float>(Float(OutputColorSpace.sRGB.decode(e.x)), Float(OutputColorSpace.sRGB.decode(e.y)), Float(OutputColorSpace.sRGB.decode(e.z)))
            let lab = ToneMath.oklab(m * lin)
            var h = atan2(lab.z, lab.y)
            if h < 0 { h += 2 * .pi }
            return h
        }
    }()

    /// The two ranges a hue falls between and their weights (raised-cosine crossfade: smooth, sums to 1).
    @inline(__always) public static func mixerWeights(hue h0: Float) -> (Int, Int, Float) {
        var h = h0
        if h < 0 { h += 2 * .pi }
        let c = mixerCentres
        var i = 7
        for k in 0..<7 where h >= c[k] && h < c[k + 1] { i = k }
        let j = (i + 1) % 8
        var span = c[j] - c[i]
        var d = h - c[i]
        if span <= 0 { span += 2 * .pi }
        if d < 0 { d += 2 * .pi }
        let t = min(max(d / span, 0), 1)
        let wi = cos(t * .pi / 2) * cos(t * .pi / 2)
        return (i, j, wi)
    }

    /// Mixer adjustments per range: (hue shift in radians, saturation −1…1, luminance −1…1).
    public static func applyMixer(_ lab: SIMD3<Float>, _ ranges: [SIMD3<Float>]) -> SIMD3<Float> {
        var c = simd_length(SIMD2(lab.y, lab.z))
        guard c > 1e-6 else { return lab }
        var h = atan2(lab.z, lab.y)
        let (i, j, wi) = mixerWeights(hue: h)
        let adj = ranges[i] * wi + ranges[j] * (1 - wi)
        let cw = smoothstep(0, 0.06, c)                 // greys are left alone
        h += adj.x * cw
        c *= max(0, 1 + adj.y)
        let l = lab.x * (1 + 0.3 * adj.z * cw)
        return SIMD3(l, c * cos(h), c * sin(h))
    }

    // MARK: - Targeted colours

    public struct Target: Equatable, Sendable {
        /// Picked hue (radians), chroma; fully selected within `core`, fading out until `edge` (radians).
        public var hue: Float, chroma: Float, core: Float, edge: Float
        /// Hue shift (radians), saturation and luminance (−1…1), isolate (0…1).
        public var hueShift: Float, saturation: Float, luminance: Float, isolate: Float

        public init(_ t: TargetedColor) {
            hue = Float(t.hue * .pi / 180)
            chroma = Float(max(t.chroma, 0.02))
            let w = Float(t.width * .pi / 180), s = Float(t.softness / 100)
            core = w * (1 - 0.8 * s)
            edge = w * (1 + s) + 1e-4
            hueShift = Float(t.hueShift / 100 * 30 * .pi / 180)
            saturation = Float(t.saturation / 100)
            luminance = Float(t.luminance / 100)
            isolate = Float(t.isolate / 100)
        }
    }

    /// How much a colour belongs to a picked range (0…1): close in hue, and not much greyer than the pick.
    @inline(__always) public static func targetWeight(_ lab: SIMD3<Float>, _ t: Target) -> Float {
        let c = simd_length(SIMD2(lab.y, lab.z))
        let d = abs(wrap(atan2(lab.z, lab.y) - t.hue))
        let wh = 1 - smoothstep(t.core, t.edge, d)
        let wc = smoothstep(0.15 * t.chroma, 0.5 * t.chroma, c)
        return wh * wc
    }

    public static func applyTargets(_ lab0: SIMD3<Float>, _ targets: [Target]) -> SIMD3<Float> {
        var lab = lab0
        var selected: Float = 0, isolate: Float = 0
        for t in targets {
            let w = targetWeight(lab0, t)
            if t.isolate > 0 { selected = max(selected, w); isolate = max(isolate, t.isolate) }
            guard w > 0, t.hueShift != 0 || t.saturation != 0 || t.luminance != 0 else { continue }
            var c = simd_length(SIMD2(lab.y, lab.z))
            var h = atan2(lab.z, lab.y)
            h += t.hueShift * w
            c *= max(0, 1 + t.saturation * w)
            lab = SIMD3(lab.x * (1 + 0.3 * t.luminance * w), c * cos(h), c * sin(h))
        }
        if isolate > 0 {
            let k = 1 - isolate * (1 - selected)
            lab.y *= k; lab.z *= k
        }
        return lab
    }

    // MARK: - Colour grading

    public struct Grading: Equatable, Sendable {
        /// Per zone: (a offset, b offset, L offset) at full weight; zone centres and transition half-width.
        public var shadows: SIMD3<Float>, midtones: SIMD3<Float>, highlights: SIMD3<Float>, global: SIMD3<Float>
        public var shadowCentre: Float, highlightCentre: Float, halfWidth: Float

        public init(_ g: ColorGrading) {
            func w(_ x: ColorGrading.Wheel) -> SIMD3<Float> {
                let a = Float(x.hue * .pi / 180), s = Float(x.saturation / 100) * 0.06
                return SIMD3(s * cos(a), s * sin(a), Float(x.luminance / 100) * 0.1)
            }
            shadows = w(g.shadows); midtones = w(g.midtones); highlights = w(g.highlights); global = w(g.global)
            let b = Float(g.balance / 100)
            shadowCentre = 0.42 + 0.15 * b
            highlightCentre = 0.70 + 0.15 * b
            halfWidth = 0.06 + 0.2 * Float(g.blending / 100)
        }
    }

    /// Tints and lifts by tonal zone (OKLab lightness), plus the global wheel. Tints fade out towards pure
    /// black so the deepest blacks stay black.
    /// Fujifilm-style Color Chrome effects in OKLab: saturated colours (any hue) and blues get deeper,
    /// richer tones — darker, a little more chroma — so they keep their gradation instead of glowing.
    /// `strength` and `blue` are 0…1 (Fujifilm's "weak" ≈ 0.5, "strong" = 1).
    public static func colorChrome(_ lab: SIMD3<Float>, _ strength: Float, _ blue: Float) -> SIMD3<Float> {
        var l = lab
        let c = simd_length(SIMD2(l.y, l.z))
        guard c > 1e-5 else { return l }
        var dark: Float = 0, boost: Float = 0
        if strength > 0 {
            let w = smooth(0.07, 0.2, c) * smooth(0.12, 0.35, l.x)
            dark += 0.14 * strength * w; boost += 0.06 * strength * w
        }
        if blue > 0 {
            let h = atan2(l.z, l.y)
            let dh = atan2(sin(h - blueHue), cos(h - blueHue))
            let wh = max(0, cos(dh * 1.6))
            let w = wh * wh * smooth(0.025, 0.1, c) * smooth(0.12, 0.35, l.x)
            dark += 0.18 * blue * w; boost += 0.1 * blue * w
        }
        l.x *= 1 - dark
        let g = 1 + boost
        l.y *= g; l.z *= g
        return l
    }
    /// OKLab hue of a clear blue sky / sRGB blue region (−1.85 rad ≈ 254°).
    static let blueHue: Float = -1.85
    @inline(__always) static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    public static func applyGrading(_ lab: SIMD3<Float>, _ g: Grading) -> SIMD3<Float> {
        let l = lab.x
        let ws = 1 - smoothstep(g.shadowCentre - g.halfWidth, g.shadowCentre + g.halfWidth, l)
        let wh = smoothstep(g.highlightCentre - g.halfWidth, g.highlightCentre + g.halfWidth, l)
        let wm = max(0, 1 - ws - wh)
        let o = g.shadows * ws + g.midtones * wm + g.highlights * wh + g.global
        let fade = min(1, max(l, 0) / 0.15)
        return SIMD3(l + o.z, lab.y + o.x * fade, lab.z + o.y * fade)
    }

    /// Hue (degrees, 0…360), chroma and lightness of a linear Rec.2020 colour, for picking.
    public static func lch(_ rgb: SIMD3<Float>) -> (hue: Double, chroma: Double, lightness: Double) {
        let lab = ToneMath.oklab(rgb)
        var h = Double(atan2(lab.z, lab.y)) * 180 / .pi
        if h < 0 { h += 360 }
        return (h, Double(simd_length(SIMD2(lab.y, lab.z))), Double(lab.x))
    }

    /// sRGB-ish display colour for UI swatches of an OKLCh colour (hue degrees).
    public static func swatch(hue: Double, chroma: Double = 0.13, lightness: Double = 0.72) -> SIMD3<Double> {
        let h = hue * .pi / 180
        let lin = ToneMath.fromOklab(SIMD3(Float(lightness), Float(chroma * cos(h)), Float(chroma * sin(h))))
        let s = simd_float3x3(OutputColorSpace.sRGB.fromRec2020) * lin
        return SIMD3(OutputColorSpace.sRGB.encode(Double(max(0, min(1, s.x)))),
                     OutputColorSpace.sRGB.encode(Double(max(0, min(1, s.y)))),
                     OutputColorSpace.sRGB.encode(Double(max(0, min(1, s.z)))))
    }
}
