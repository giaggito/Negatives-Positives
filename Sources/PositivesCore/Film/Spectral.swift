import Foundation
import simd

/// Spectral basics on a 10 nm grid, 380…780 nm (41 samples): colour-matching functions, illuminants and
/// integration to XYZ. Everything here is Double and computed once.
public enum Spectral {
    public static let count = 41
    public static let wavelengths: [Double] = (0..<41).map { 380 + 10 * Double($0) }

    /// CIE 1931 2° colour matching functions (x̄, ȳ, z̄).
    public static var cmf: [SIMD3<Double>] { FilmLibrary.shared.cmf }

    /// Illuminant spectral power, normalised to a mean of 1 over the grid.
    public static func illuminant(_ name: String) -> [Double] {
        let raw: [Double]
        switch name {
        case "D50": raw = daylight(5003)
        case "D55": raw = daylight(5503)
        case "D65": raw = daylight(6504)
        case "D75": raw = daylight(7504)
        case "T", "A", "3200K": raw = blackbody(3200)
        case "TH-KG3":
            // Tungsten-halogen enlarger lamp (3400 K) behind a Schott KG3 heat-absorbing filter.
            let kg3 = FilmLibrary.shared.kg3
            raw = zip(blackbody(3400), kg3).map { $0 * $1 }
        default:
            if name.hasPrefix("BB"), let t = Double(name.dropFirst(2)) { raw = blackbody(t) } else { raw = daylight(5503) }
        }
        let mean = raw.reduce(0, +) / Double(raw.count)
        return raw.map { $0 / mean }
    }

    /// CIE daylight series from the S0, S1, S2 basis (CIE 15).
    public static func daylight(_ cct: Double) -> [Double] {
        let t = cct                         // correlated colour temperature (D65 = 6504 K)
        let xd: Double
        if t <= 7000 {
            xd = -4.6070e9 / (t * t * t) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063
        } else {
            xd = -2.0064e9 / (t * t * t) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040
        }
        let yd = -3 * xd * xd + 2.87 * xd - 0.275
        let m = 0.0241 + 0.2562 * xd - 0.7341 * yd
        let m1 = (-1.3515 - 1.7703 * xd + 5.9114 * yd) / m
        let m2 = (0.0300 - 31.4424 * xd + 30.0717 * yd) / m
        return FilmLibrary.shared.daylightBasis.map { $0.x + m1 * $0.y + m2 * $0.z }
    }

    /// Planck's law (relative).
    public static func blackbody(_ t: Double) -> [Double] {
        wavelengths.map { wl in
            let l = wl * 1e-9
            return 1 / (pow(l, 5) * (exp(1.4388e-2 / (l * t)) - 1))
        }
    }

    /// XYZ of a spectral power distribution (relative units).
    public static func xyz(_ spd: [Double]) -> SIMD3<Double> {
        var acc = SIMD3<Double>.zero
        for i in 0..<count { acc += spd[i] * cmf[i] }
        return acc
    }

    /// XYZ → linear Rec.2020 with Bradford adaptation from `white` (XYZ) to D65, scaled so `white` → Y = 1.
    public static func toRec2020(adaptingFrom white: SIMD3<Double>) -> simd_double3x3 {
        let d65 = ColorScience.xyz(fromXY: ColorScience.d65)
        let a = ColorScience.adaptation(from: white / white.y, to: d65)
        return ColorScience.rec2020.fromXYZ * a * simd_double3x3(diagonal: SIMD3(repeating: 1 / white.y))
    }
}

/// Reflectance spectra for RGB colours (Jakob & Hanika 2019, "A low-dimensional function space for efficient
/// spectral upsampling"): R(λ) = sigmoid(c₀t² + c₁t + c₂), t = (λ − 380) / 400 — smooth, always within 0…1,
/// the smoothest-looking natural spectrum that has exactly the requested colour under D65.
///
/// The film sees a colour through its own spectral sensitivities, so to expose a virtual film we need a
/// spectrum, not just RGB. Fitting is done once on a grid over Rec.2020 chromaticity; film exposure is
/// linear in the light, so E(rgb) = (r + g + b) · LUT(r / (r+g+b), g / (r+g+b)).
public enum SpectralUpsampling {
    public static let gridSize = 48

    @inline(__always) static func sigmoid(_ z: Double) -> Double { 0.5 + z / (2 * (1 + z * z).squareRoot()) }

    public static func reflectance(_ c: SIMD3<Double>) -> [Double] {
        (0..<Spectral.count).map { i in
            let t = Double(i) / Double(Spectral.count - 1)
            return sigmoid(c.x * t * t + c.y * t + c.z)
        }
    }

    /// Fitted coefficients on the chromaticity grid (x = r/s along i, y = g/s along j); nil outside the triangle.
    public static let coefficients: [SIMD3<Double>?] = fitGrid()

    /// Target colour for a grid cell: Rec.2020 (x, y, 1 − x − y), scaled so its largest component is 0.8.
    public static func target(_ i: Int, _ j: Int) -> SIMD3<Double>? {
        let n = Double(gridSize - 1)
        let x = Double(i) / n, y = Double(j) / n
        guard x + y <= 1 + 1e-9 else { return nil }
        let rgb = SIMD3(x, y, max(0, 1 - x - y))
        return rgb * (0.8 / max(rgb.max(), 1e-9))
    }

    static func fitGrid() -> [SIMD3<Double>?] {
        let n = gridSize
        let d65 = Spectral.illuminant("D65")
        let cmf = Spectral.cmf
        let w = (0..<Spectral.count).map { d65[$0] * cmf[$0] }
        let norm = w.reduce(0) { $0 + $1.y }
        let toXYZ = ColorScience.rec2020.toXYZ
        func xyz(_ c: SIMD3<Double>) -> (SIMD3<Double>, simd_double3x3) {
            var v = SIMD3<Double>.zero
            var j = simd_double3x3()
            for k in 0..<Spectral.count {
                let t = Double(k) / Double(Spectral.count - 1)
                let z = c.x * t * t + c.y * t + c.z
                let r = sigmoid(z)
                let dr = 1 / (2 * pow(1 + z * z, 1.5))
                v += r * w[k]
                let g = dr * w[k] / norm
                j.columns.0 += g * t * t; j.columns.1 += g * t; j.columns.2 += g
            }
            return (v / norm, j)
        }
        var out = [SIMD3<Double>?](repeating: nil, count: n * n)
        // Solve from white outwards, each cell starting from an already solved neighbour.
        var order: [(Int, Int)] = []
        for i in 0..<n { for j in 0..<n where target(i, j) != nil { order.append((i, j)) } }
        let c0 = Double(n - 1) / 3
        order.sort { hypot(Double($0.0) - c0, Double($0.1) - c0) < hypot(Double($1.0) - c0, Double($1.1) - c0) }
        for (i, j) in order {
            let tgt = toXYZ * target(i, j)!
            var c = SIMD3<Double>(0, 0, 0)
            for (di, dj) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1)] {
                let a = i + di, b = j + dj
                if a >= 0, b >= 0, a < n, b < n, let s = out[a * n + b] { c = s; break }
            }
            var lambda = 1e-3
            var (v, jac) = xyz(c)
            var err = simd_length_squared(v - tgt)
            for _ in 0..<60 {
                if err < 1e-12 { break }
                // Levenberg–Marquardt step.
                let jt = jac.transpose
                var a = jt * jac
                a.columns.0.x += lambda; a.columns.1.y += lambda; a.columns.2.z += lambda
                guard abs(a.determinant) > 1e-30 else { break }
                let step = a.inverse * (jt * (tgt - v))
                let c2 = c + step
                let (v2, j2) = xyz(c2)
                let e2 = simd_length_squared(v2 - tgt)
                if e2 < err { c = c2; v = v2; jac = j2; err = e2; lambda = max(lambda / 4, 1e-9) } else { lambda *= 8 }
                if lambda > 1e6 { break }
            }
            out[i * n + j] = c
        }
        return out
    }
}
