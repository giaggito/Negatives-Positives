import Foundation

/// The "paper": maps scene-linear light to display-linear light with a photographic S-curve.
///
/// Photographic paper is characterised by an S-shaped curve of print density against log exposure.
/// We model it directly in the log domain, per channel, pivoting on middle grey:
///
///     x = log2(L / 0.18) + exposure                    (stops relative to middle grey)
///     y = log10(Y)                                     (print log-reflectance, white = 0)
///     y0 = log10(0.18)                                 (middle grey stays middle grey)
///     m  = contrast · log10(2)                          (slope dy/dx at the pivot; contrast 1 = 1:1 log-log)
///
///     x ≥ 0 (shoulder, towards paper white y = 0):
///         y = y0 + a_hi · g(m·x / a_hi ; k_shoulder),     a_hi = −y0
///     x < 0 (toe, towards paper black y = −Dmax):
///         y = y0 − a_lo · g(m·|x| / a_lo ; k_toe),        a_lo = Dmax + y0
///
///     g(t; k) = t / (1 + t^k)^(1/k)
///
/// `g` has slope 1 at the origin and approaches 1 asymptotically, so the curve is C¹ at the pivot,
/// strictly monotonic, never clips and is exactly invertible. A larger `k` keeps the curve straight for
/// longer and then rolls off harder; a smaller `k` gives a long, gentle toe or shoulder.
/// The same function is applied to each channel, so a neutral input always produces a neutral output.
public struct PrintCurve: Codable, Equatable, Sendable {
    /// Print exposure in stops (positive = brighter).
    public var exposure: Double
    /// Mid-tone log-log slope (paper grade). 1 reproduces scene contrast at middle grey.
    public var contrast: Double
    /// Shadow roll-off softness, 0 (hard) … 1 (very soft).
    public var toe: Double
    /// Highlight roll-off softness, 0 (hard) … 1 (very soft).
    public var shoulder: Double
    /// Maximum paper density: deepest black = 10^−Dmax. Must be > 0.745 (i.e. darker than middle grey).
    public var paperDmax: Double

    public init(exposure: Double = 0, contrast: Double = 1.35, toe: Double = 0.5, shoulder: Double = 0.4, paperDmax: Double = 2.4) {
        self.exposure = exposure
        self.contrast = contrast
        self.toe = toe
        self.shoulder = shoulder
        self.paperDmax = paperDmax
    }

    public static let middleGrey = 0.18
    public static let minimumInput = 1e-10

    /// Softness (0…1) -> shape exponent k (4 … 0.8, geometric).
    public static func shapeExponent(softness s: Double) -> Double {
        0.8 * pow(5, 1 - min(max(s, 0), 1))
    }

    /// The resolved numbers the per-pixel function needs (shared verbatim with the GPU).
    public struct Resolved: Equatable, Sendable {
        public var exposure, slope, y0, aHigh, aLow, kShoulder, kToe: Double
    }

    public var resolved: Resolved {
        let y0 = log10(Self.middleGrey)
        let dmax = max(paperDmax, -y0 + 0.05)
        return Resolved(exposure: exposure, slope: max(contrast, 0.05) * log10(2.0), y0: y0,
                        aHigh: -y0, aLow: dmax + y0,
                        kShoulder: Self.shapeExponent(softness: shoulder), kToe: Self.shapeExponent(softness: toe))
    }

    @inline(__always) static func g(_ t: Double, _ k: Double) -> Double { t / pow(1 + pow(t, k), 1 / k) }
    @inline(__always) static func gInverse(_ u: Double, _ k: Double) -> Double { u / pow(1 - pow(u, k), 1 / k) }

    /// Scene-linear -> display-linear for one channel.
    public static func apply(_ l: Double, _ r: Resolved) -> Double {
        let x = log2(max(l, minimumInput) / middleGrey) + r.exposure
        let y: Double
        if x >= 0 {
            y = r.y0 + r.aHigh * g(r.slope * x / r.aHigh, r.kShoulder)
        } else {
            y = r.y0 - r.aLow * g(-r.slope * x / r.aLow, r.kToe)
        }
        return pow(10, y)
    }

    /// Exact inverse of `apply` for outputs strictly between paper black and paper white.
    public static func invert(_ out: Double, _ r: Resolved) -> Double {
        let y = log10(out)
        let x: Double
        if y >= r.y0 {
            x = r.aHigh * gInverse((y - r.y0) / r.aHigh, r.kShoulder) / r.slope
        } else {
            x = -r.aLow * gInverse((r.y0 - y) / r.aLow, r.kToe) / r.slope
        }
        return middleGrey * pow(2, x - r.exposure)
    }

    public func apply(_ l: Double) -> Double { Self.apply(l, resolved) }
}
