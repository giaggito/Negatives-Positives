import Foundation
import simd

/// Colorimetry used by the pipeline. Everything here is closed-form and runs in Double;
/// the GPU only ever receives the resulting matrices.
///
/// Conventions
/// - "Working space" is linear Rec.2020 with a D65 white, unbounded (no clipping anywhere).
/// - Matrices act on column vectors: `rgbOut = M * rgbIn`.
public enum ColorScience {

    // MARK: - Chromaticity helpers

    /// XYZ (Y = 1) of a chromaticity `xy`.
    public static func xyz(fromXY xy: SIMD2<Double>) -> SIMD3<Double> {
        SIMD3(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
    }

    public static func xy(fromXYZ v: SIMD3<Double>) -> SIMD2<Double> {
        let s = v.x + v.y + v.z
        return SIMD2(v.x / s, v.y / s)
    }

    /// CIE 1960 UCS (u, v) -> CIE 1931 (x, y).
    public static func xy(fromUV uv: SIMD2<Double>) -> SIMD2<Double> {
        let d = 2 * uv.x - 8 * uv.y + 4
        return SIMD2(3 * uv.x / d, 2 * uv.y / d)
    }

    /// CIE 1931 (x, y) -> CIE 1960 UCS (u, v).
    public static func uv(fromXY xy: SIMD2<Double>) -> SIMD2<Double> {
        let d = -2 * xy.x + 12 * xy.y + 3
        return SIMD2(4 * xy.x / d, 6 * xy.y / d)
    }

    // MARK: - RGB spaces

    public struct RGBSpace: Sendable {
        public let red, green, blue, white: SIMD2<Double>
        /// Linear RGB -> XYZ (white maps to Y = 1).
        public var toXYZ: simd_double3x3 {
            let r = ColorScience.xyz(fromXY: red), g = ColorScience.xyz(fromXY: green), b = ColorScience.xyz(fromXY: blue)
            let p = simd_double3x3(columns: (r, g, b))
            let s = p.inverse * ColorScience.xyz(fromXY: white)
            return simd_double3x3(columns: (r * s.x, g * s.y, b * s.z))
        }
        public var fromXYZ: simd_double3x3 { toXYZ.inverse }
    }

    public static let d65 = SIMD2<Double>(0.3127, 0.3290)
    public static let d50 = SIMD2<Double>(0.3457, 0.3585)

    public static let rec2020 = RGBSpace(red: [0.708, 0.292], green: [0.170, 0.797], blue: [0.131, 0.046], white: d65)
    public static let sRGB = RGBSpace(red: [0.64, 0.33], green: [0.30, 0.60], blue: [0.15, 0.06], white: d65)
    public static let displayP3 = RGBSpace(red: [0.680, 0.320], green: [0.265, 0.690], blue: [0.150, 0.060], white: d65)
    public static let adobeRGB = RGBSpace(red: [0.64, 0.33], green: [0.21, 0.71], blue: [0.15, 0.06], white: d65)
    public static let proPhoto = RGBSpace(red: [0.7347, 0.2653], green: [0.1596, 0.8404], blue: [0.0366, 0.0001], white: d50)

    /// Linear sRGB -> linear Rec.2020 (both D65).
    public static var sRGBToRec2020: simd_double3x3 { rec2020.fromXYZ * sRGB.toXYZ }

    // MARK: - Chromatic adaptation (Bradford, as used by ICC)

    public static let bradford = simd_double3x3(rows: [
        SIMD3(0.8951, 0.2664, -0.1614),
        SIMD3(-0.7502, 1.7135, 0.0367),
        SIMD3(0.0389, -0.0685, 1.0296),
    ])

    /// von Kries adaptation in Bradford cone space that maps `source` white to `destination` white (XYZ).
    public static func adaptation(from source: SIMD3<Double>, to destination: SIMD3<Double>) -> simd_double3x3 {
        let s = bradford * source, d = bradford * destination
        return bradford.inverse * simd_double3x3(diagonal: d / s) * bradford
    }

    // MARK: - Planckian locus (Krystek 1985 rational approximation, 1000–15000 K, in CIE 1960 uv)

    public static func planckianUV(kelvin t: Double) -> SIMD2<Double> {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        return SIMD2(u, v)
    }

    /// Unit normal to the Planckian locus at `t`, pointing towards green (+Duv).
    static func planckianNormal(kelvin t: Double) -> SIMD2<Double> {
        let h = 1.0
        let d = planckianUV(kelvin: t + h) - planckianUV(kelvin: t - h)
        // The locus runs right-to-left (u decreases) as T grows; rotate the tangent so +normal has larger v.
        var n = simd_normalize(SIMD2(-d.y, d.x))
        if n.y < 0 { n = -n }
        return n
    }
}

/// Positive-domain white balance with photo-editor semantics.
///
/// `temperature` (K) and `tint` describe the colour of the light the picture appears to have been lit by.
/// The correction adapts that light to D65, so — as in Lightroom — raising the temperature warms the
/// image and raising the tint makes it more magenta. At the reference (6504 K, tint 0) the matrix is
/// exactly the identity.
///
/// Source white chromaticity (CIE 1960 uv):
///     uv_src = uv(D65) + [uv_planck(T) − uv_planck(6504)] + (tint / 3000) · n̂(T)
/// i.e. it moves along the Planckian locus for temperature and along its normal for tint (Duv = tint/3000,
/// so ±150 ≈ ±0.05 Duv). The matrix is the Bradford adaptation from that white to D65, expressed in Rec.2020.
public struct WhiteBalance: Codable, Equatable, Sendable {
    public static let referenceTemperature = 6504.0
    public static let temperatureRange = 2000.0...15000.0
    public static let tintRange = -150.0...150.0

    public var temperature: Double
    public var tint: Double

    public init(temperature: Double = WhiteBalance.referenceTemperature, tint: Double = 0) {
        self.temperature = temperature
        self.tint = tint
    }

    public static let neutral = WhiteBalance()

    public var sourceWhiteUV: SIMD2<Double> {
        let t = min(max(temperature, Self.temperatureRange.lowerBound), Self.temperatureRange.upperBound)
        return ColorScience.uv(fromXY: ColorScience.d65)
            + ColorScience.planckianUV(kelvin: t) - ColorScience.planckianUV(kelvin: Self.referenceTemperature)
            + (tint / 3000) * ColorScience.planckianNormal(kelvin: t)
    }

    /// Rec.2020-linear -> Rec.2020-linear correction matrix.
    public var matrix: simd_double3x3 {
        if self == .neutral { return matrix_identity_double3x3 }
        let src = ColorScience.xyz(fromXY: ColorScience.xy(fromUV: sourceWhiteUV))
        let dst = ColorScience.xyz(fromXY: ColorScience.d65)
        let s = ColorScience.rec2020
        return s.fromXYZ * ColorScience.adaptation(from: src, to: dst) * s.toXYZ
    }

    /// Eyedropper: the white balance that renders `rgb` (scene-linear Rec.2020, before white balance) neutral.
    /// Solved with Newton iterations on (mired, tint) so the result is expressed in slider units.
    public static func neutralizing(_ rgb: SIMD3<Double>) -> WhiteBalance? {
        let xyz = ColorScience.rec2020.toXYZ * rgb
        guard xyz.y > 0, xyz.x + xyz.y + xyz.z > 0 else { return nil }
        let target = ColorScience.uv(fromXY: ColorScience.xy(fromXYZ: xyz))
        var mired = 1e6 / referenceTemperature, tint = 0.0
        func uv(_ m: Double, _ t: Double) -> SIMD2<Double> { WhiteBalance(temperature: 1e6 / m, tint: t).sourceWhiteUV }
        for _ in 0..<50 {
            let f = uv(mired, tint) - target
            if simd_length(f) < 1e-10 { break }
            let jm = (uv(mired + 0.01, tint) - uv(mired - 0.01, tint)) / 0.02
            let jt = (uv(mired, tint + 0.01) - uv(mired, tint - 0.01)) / 0.02
            let j = simd_double2x2(columns: (jm, jt))
            guard abs(j.determinant) > 1e-18 else { return nil }
            let step = j.inverse * f
            mired -= step.x
            tint -= step.y
            mired = min(max(mired, 1e6 / temperatureRange.upperBound), 1e6 / temperatureRange.lowerBound)
        }
        return WhiteBalance(temperature: 1e6 / mired, tint: min(max(tint, tintRange.lowerBound), tintRange.upperBound))
    }
}

extension simd_float3x3 {
    public init(_ d: simd_double3x3) {
        self.init(columns: (SIMD3<Float>(d.columns.0), SIMD3<Float>(d.columns.1), SIMD3<Float>(d.columns.2)))
    }
}
