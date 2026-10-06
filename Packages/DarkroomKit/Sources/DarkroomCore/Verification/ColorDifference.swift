import Foundation
import simd

/// CIELAB and CIEDE2000, used by the verification tools and tests.
public enum Lab {
    /// XYZ (D65, Y of white = 1) -> CIELAB.
    public static func lab(fromXYZ v: SIMD3<Double>) -> SIMD3<Double> {
        let w = ColorScience.xyz(fromXY: ColorScience.d65)
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(v.x / w.x), fy = f(v.y / w.y), fz = f(v.z / w.z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    public static func lab(rec2020 v: SIMD3<Double>) -> SIMD3<Double> { lab(fromXYZ: ColorScience.rec2020.toXYZ * v) }

    /// CIEDE2000.
    public static func deltaE2000(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let (L1, a1, b1) = (a.x, a.y, a.z), (L2, a2, b2) = (b.x, b.y, b.z)
        let C1 = hypot(a1, b1), C2 = hypot(a2, b2), Cb = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cb, 7) / (pow(Cb, 7) + pow(25, 7))))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = hypot(a1p, b1), C2p = hypot(a2p, b2)
        func hp(_ x: Double, _ y: Double) -> Double { if x == 0 && y == 0 { return 0 }; let h = atan2(y, x) * 180 / .pi; return h < 0 ? h + 360 : h }
        let h1p = hp(a1p, b1), h2p = hp(a2p, b2)
        let dLp = L2 - L1, dCp = C2p - C1p
        var dhp = 0.0
        if C1p * C2p != 0 { dhp = h2p - h1p; if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 } }
        let dHp = 2 * sqrt(C1p * C2p) * sin(dhp / 2 * .pi / 180)
        let Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2
        var hbp = h1p + h2p
        if C1p * C2p != 0 { if abs(h1p - h2p) > 180 { hbp += h1p + h2p < 360 ? 360 : -360 }; hbp /= 2 }
        let T = 1 - 0.17 * cos((hbp - 30) * .pi / 180) + 0.24 * cos(2 * hbp * .pi / 180)
            + 0.32 * cos((3 * hbp + 6) * .pi / 180) - 0.20 * cos((4 * hbp - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(Cbp, 7) / (pow(Cbp, 7) + pow(25, 7)))
        let Sl = 1 + 0.015 * pow(Lbp - 50, 2) / sqrt(20 + pow(Lbp - 50, 2))
        let Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(2 * dTheta * .pi / 180) * Rc
        return sqrt(pow(dLp / Sl, 2) + pow(dCp / Sc, 2) + pow(dHp / Sh, 2) + Rt * (dCp / Sc) * (dHp / Sh))
    }
}

