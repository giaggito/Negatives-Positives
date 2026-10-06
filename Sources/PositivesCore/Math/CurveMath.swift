import Foundation
import simd

/// Tone curves through user points: monotone cubic Hermite interpolation (Fritsch–Carlson). The curve goes
/// exactly through every point, is smooth (C¹), and never overshoots between points — no ripples, no
/// surprise reversals. Outside the first / last point it is flat; beyond 0…1 (light brighter than white
/// or out-of-gamut values) it continues parallel to the identity so nothing is clipped.
public enum CurveMath {
    /// Entries of the baked lookup table the GPU (and the CPU reference) interpolate linearly.
    public static let lutSize = 4096

    public static func isIdentity(_ pts: [CurvePoint]) -> Bool {
        pts.allSatisfy { abs($0.x - $0.y) < 1e-9 } && pts.count >= 2
    }

    /// Points sorted by x, duplicates removed, clamped to 0…1.
    public static func normalized(_ pts: [CurvePoint]) -> [CurvePoint] {
        var p = pts.map { CurvePoint(min(max($0.x, 0), 1), min(max($0.y, 0), 1)) }.sorted { $0.x < $1.x }
        var out: [CurvePoint] = []
        for q in p where out.last.map({ q.x - $0.x > 1e-4 }) ?? true { out.append(q) }
        p = out
        if p.isEmpty { return ToneCurves.identity }
        if p.count == 1 { return [CurvePoint(0, p[0].y - p[0].x), p[0]] }
        return p
    }

    /// Hermite tangents per Fritsch–Carlson.
    static func tangents(_ p: [CurvePoint]) -> [Double] {
        let n = p.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / (p[i + 1].x - p[i].x) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        return m
    }

    /// Evaluates the curve at x (any real number; see type documentation for x outside 0…1).
    public static func evaluate(_ pts: [CurvePoint], _ x: Double) -> Double {
        let p = normalized(pts)
        return evaluate(p, tangents(p), x)
    }

    static func evaluate(_ p: [CurvePoint], _ m: [Double], _ x: Double) -> Double {
        if x < 0 { return evaluate(p, m, 0) + x }
        if x > 1 { return evaluate(p, m, 1) + (x - 1) }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        var i = 0
        while i < p.count - 2 && x > p[i + 1].x { i += 1 }
        let h = p[i + 1].x - p[i].x
        let t = (x - p[i].x) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p[i].y + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * p[i + 1].y + (t3 - t2) * h * m[i + 1]
    }

    /// The four curves baked into one table: entry k is the curve at x = k / (lutSize − 1), as (master, R, G, B).
    public static func bake(_ c: ToneCurves) -> [SIMD4<Float>] {
        let curves = [c.master, c.red, c.green, c.blue].map { normalized($0) }
        let tans = curves.map { tangents($0) }
        return (0..<lutSize).map { k in
            let x = Double(k) / Double(lutSize - 1)
            return SIMD4(Float(evaluate(curves[0], tans[0], x)), Float(evaluate(curves[1], tans[1], x)),
                         Float(evaluate(curves[2], tans[2], x)), Float(evaluate(curves[3], tans[3], x)))
        }
    }

    /// The same for a single-channel table (a mask's curve).
    @inline(__always) public static func lookup1(_ lut: [Float], _ x: Float) -> Float {
        let n = Float(lutSize - 1)
        if x < 0 { return lut[0] + x }
        if x > 1 { return lut[lutSize - 1] + (x - 1) }
        let f = x * n
        let i = min(Int(f), lutSize - 2)
        let t = f - Float(i)
        return lut[i] + (lut[i + 1] - lut[i]) * t
    }

    /// Linear interpolation in a baked table, channel `c`, with the identity-parallel extension outside 0…1.
    @inline(__always) public static func lookup(_ lut: [SIMD4<Float>], _ x: Float, channel c: Int) -> Float {
        let n = Float(lutSize - 1)
        if x < 0 { return lut[0][c] + x }
        if x > 1 { return lut[lutSize - 1][c] + (x - 1) }
        let f = x * n
        let i = min(Int(f), lutSize - 2)
        let t = f - Float(i)
        return lut[i][c] + (lut[i + 1][c] - lut[i][c]) * t
    }
}
