import Foundation
import simd

/// A mask's adjustments resolved for rendering. Each value is applied in proportion to the mask's weight w
/// at a pixel, at the stage where the global control of the same name acts:
///   white balance  c ← mix(c, L·c, w)                     (L = the white-balance change as a Rec.2020 matrix)
///   dehaze, shadows, highlights, clarity, contrast        added to the global amount, × w
///   exposure       c ← c · 2^(w·EV)
///   curve          q ← mix(q, curve(q), w)                (perceptual units, after the global curve)
///   saturation     chroma × (1 + w·s);  colour cast: OKLab (a, b) += w·cast
///   grain          grain amplitude × max(0, 1 + w·g)
public struct LocalRender: Equatable, Sendable {
    public var whiteBalance: simd_float3x3?
    public var exposureStops: Float = 0
    public var dehaze: Float = 0
    public var shadows: Float = 0, highlights: Float = 0
    /// Clarity gain (same scale as `DevelopParameters.clarityGain`).
    public var clarityGain: Float = 0
    /// Added to the global contrast, in the same −1…1 units.
    public var contrast: Float = 0
    public var saturation: Float = 0
    public var cast = SIMD2<Float>.zero
    /// Master curve table (`CurveMath.lutSize` entries) or nil.
    public var curve: [Float]?
    public var grain: Float = 0

    public init() {}

    public var hasTone: Bool { shadows != 0 || highlights != 0 || clarityGain != 0 }
    public var hasColour: Bool { saturation != 0 || cast != .zero }
    public var hasShape: Bool { contrast != 0 || curve != nil }

    /// - Parameter globalMatrix: the photo's input matrix (white balance included); `withWhiteBalance` makes
    ///   the same matrix for another white balance.
    public static func resolve(_ s: LocalSettings, globalWhiteBalance wb: WhiteBalance,
                               withWhiteBalance: (WhiteBalance) -> simd_double3x3, globalMatrix: simd_double3x3) -> LocalRender {
        var r = LocalRender()
        if s.temperature != 0 || s.tint != 0 {
            // ±100 = ±50 mired / ±60 tint units around the photo's own white balance.
            let mired = 1e6 / wb.temperature - s.temperature * 0.5
            let t = min(max(1e6 / max(mired, 50), WhiteBalance.temperatureRange.lowerBound), WhiteBalance.temperatureRange.upperBound)
            let m2 = withWhiteBalance(WhiteBalance(temperature: t, tint: wb.tint + s.tint * 0.6))
            r.whiteBalance = simd_float3x3(m2 * globalMatrix.inverse)
        }
        r.exposureStops = Float(s.exposure)
        r.dehaze = Float(s.dehaze / 100)
        r.shadows = Float(s.shadows / 100)
        r.highlights = Float(s.highlights / 100)
        let c = Float(s.clarity / 100)
        r.clarityGain = c >= 0 ? 0.9 * c : 0.85 * c
        r.contrast = Float(s.contrast / 100)
        r.saturation = Float(s.saturation / 100)
        if s.colorAmount > 0 {
            let h = s.colorHue * .pi / 180
            r.cast = SIMD2(Float(cos(h)), Float(sin(h))) * Float(s.colorAmount / 100 * 0.08)
        }
        if !s.curveIsIdentity {
            var curves = ToneCurves()
            curves.master = s.curve
            r.curve = CurveMath.bake(curves).map(\.x)
        }
        r.grain = Float(s.grain / 100)
        return r
    }
}

/// How masks select pixels (the CPU reference of the `mask_eval` kernel).
public enum MaskMath {
    /// What a mask may look at for one pixel: where it is on the sensor (normalised by the long side) and
    /// the pixel's colour as the default rendering shows it (OKLab), plus samplers for brush / detected masks.
    public struct Pixel {
        public var sensor: SIMD2<Double>
        public var lab: SIMD3<Float>
        public var bitmap: (MaskComponent) -> Float
        public init(sensor: SIMD2<Double>, lab: SIMD3<Float>, bitmap: @escaping (MaskComponent) -> Float = { _ in 0 }) {
            self.sensor = sensor; self.lab = lab; self.bitmap = bitmap
        }
    }

    @inline(__always) static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x >= b ? 1 : 0 }
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The colour range of a colour mask, as a targeted-colour range.
    public static func colorTarget(_ c: MaskComponent) -> ColorMath.Target {
        var t = TargetedColor(hue: c.hue, chroma: c.chroma, lightness: c.lightness)
        t.width = c.range
        t.softness = 60
        return ColorMath.Target(t)
    }

    public static func component(_ c: MaskComponent, _ px: Pixel) -> Float {
        var v: Double
        switch c.kind {
        case .linear:
            let a = SIMD2(c.start.x, c.start.y), b = SIMD2(c.end.x, c.end.y)
            let d = b - a
            let t = simd_dot(px.sensor - a, d) / max(simd_length_squared(d), 1e-12)
            v = 1 - smooth(0, 1, t)
        case .radial:
            let p = px.sensor - SIMD2(c.center.x, c.center.y)
            let an = c.angle * .pi / 180
            let q = SIMD2(p.x * cos(an) + p.y * sin(an), -p.x * sin(an) + p.y * cos(an))
            let r = simd_length(SIMD2(q.x / max(c.radiusX, 1e-6), q.y / max(c.radiusY, 1e-6)))
            let inner = min(1 - c.feather / 100, 0.995)
            v = 1 - smooth(inner, 1, r)
        case .luminance:
            let l = Double(px.lab.x) * 100, s = max(c.smoothness, 0.5)
            v = smooth(c.low - s, c.low, l) * (1 - smooth(c.high, c.high + s, l))
        case .color:
            v = Double(ColorMath.targetWeight(px.lab, colorTarget(c)))
        case .brush, .subject, .people, .sky:
            v = Double(px.bitmap(c))
        }
        if c.invert { v = 1 - v }
        return Float(v)
    }

    /// The mask's weight at a pixel: parts combined in order (add = union, subtract, intersect), then inverted
    /// if asked.
    public static func weight(_ m: LocalAdjustment, _ px: Pixel) -> Float {
        var w: Float = 0
        for c in m.components {
            let v = component(c, px)
            switch c.mode {
            case .add: w = max(w, v)
            case .subtract: w *= 1 - v
            case .intersect: w *= v
            }
        }
        return m.invert ? 1 - w : w
    }
}
