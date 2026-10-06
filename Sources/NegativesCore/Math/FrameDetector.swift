import CoreGraphics
import Foundation
import simd

/// Finds the exposed picture on a scan, whatever surrounds it: a light table or bare panel (brighter than the
/// film), the film's rebate and sprocket holes (the base), or an opaque holder / mask (far denser than any
/// image). Only the picture may decide exposure and colour — a black holder taken for "the brightest sky"
/// would print every frame almost black.
///
/// The surround is grown from the scan's border through flat areas that are not picture-like:
///  - brighter than the film base, or at the base (clear film, rebate, holes, panel);
///  - colour film: without the film's orange tint (a holder or panel is neutral; every part of a colour
///    negative, from its thinnest to its densest, keeps the orange mask's colour direction);
///  - denser than a picture can be relative to the brightest light in the scan (an opaque holder, a mask, or
///    a film edge fogged during loading).
/// The picture is the largest rectangle that the remaining pixels fill (row / column profiles).
public enum FrameDetector {
    public struct Result: Codable, Equatable, Sendable {
        /// Picture rectangle, normalised to the sensor (0…1).
        public var rect: CGRect
        /// Share of the rectangle covered by picture pixels (1 = clean).
        public var fill: Double
    }

    /// Colour direction of the film base: (log10 R/G, log10 B/G) of balanced camera RGB.
    @inline(__always) static func chroma(_ v: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(log10(max(v.x, 1e-9) / max(v.y, 1e-9)), log10(max(v.z, 1e-9) / max(v.y, 1e-9)))
    }

    /// How much of the base's colour a sample keeps (1 = the base's tint, 0 = neutral). Nil when the base
    /// has no usable tint (black & white film, or a scan already neutralised on the base).
    @inline(__always) static func tint(_ v: SIMD3<Double>, baseChroma cb: SIMD2<Double>) -> Double? {
        let n = simd_length_squared(cb)
        guard n > 0.15 * 0.15 else { return nil }
        return simd_dot(chroma(v), cb) / n
    }

    /// Whether a sample can be part of the picture (for the frame statistics): not brighter than the base, not
    /// beyond any negative's density, and — for colour film — tinted like the film.
    public static func isFilm(_ v: SIMD3<Double>, base: SIMD3<Double>, colorFilm: Bool) -> Bool {
        guard all(v .> 0) else { return false }
        let d = NegativeModel.density(v, base: base)
        let m = (d.x + d.y + d.z) / 3
        guard m > -0.03, m < 3.2 else { return false }
        if colorFilm, let t = tint(v, baseChroma: chroma(base)), t < 0.3 { return false }
        return true
    }

    public static func detect(_ proxy: AnalysisProxy, base: SIMD3<Double>, colorFilm: Bool) -> Result? {
        // Work at ≤ 400 px on the long side: plenty for a rectangle, robust to grain and dust.
        let src = proxy.image
        let f = max(1, max(src.width, src.height) / 400)
        let img = src.downsampled(by: f)
        let w = img.width, h = img.height
        guard w > 16, h > 16 else { return nil }
        let n = w * h
        var vals = [SIMD3<Double>](repeating: .zero, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let sensor = SIMD2((Double(x) + 0.5) * Double(proxy.sourceWidth) / Double(w), (Double(y) + 0.5) * Double(proxy.sourceHeight) / Double(h))
                vals[y * w + x] = proxy.sample(sensor: sensor)
            }
        }
        let cb = chroma(base)
        let brightest = vals.map { $0.x + $0.y + $0.z }.sorted()[max(0, n - 1 - n / 200)]
        var dens = [Double](repeating: 0, count: n), absD = [Double](repeating: 0, count: n), tints = [Double?](repeating: nil, count: n)
        for i in 0..<n {
            let v = vals[i]
            let d = NegativeModel.density(v, base: base)
            dens[i] = (d.x + d.y + d.z) / 3
            absD[i] = -log10(max(v.x + v.y + v.z, 1e-9) / max(brightest, 1e-9))
            tints[i] = colorFilm ? tint(v, baseChroma: cb) : nil
        }
        // Flatness: local density change (a holder, panel or rebate is flat; their edges are sharp).
        var grad = [Double](repeating: 0, count: n)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                grad[i] = max(abs(dens[i + 1] - dens[i - 1]), abs(dens[i + w] - dens[i - w])) / 2
            }
        }
        let useTint = colorFilm && simd_length(cb) > 0.15
        // Clear film (rebate, unexposed base): at the base — or, when the base was taken from a brighter light
        // table, at the thinnest film actually present (the rebate and the deepest shadows share that density;
        // the shape rules below tell them apart).
        let filmDens = dens.filter { $0 > 0.02 }.sorted()
        let clear = max(0.06, filmDens.isEmpty ? 0 : filmDens[filmDens.count / 33] + 0.05)
        func surroundLike(_ i: Int) -> Bool {
            if grad[i] > 0.06 { return false }
            if dens[i] < clear { return true }                             // base or brighter
            if absD[i] > 2.3 { return true }                                 // holder, mask or fogged edge: beyond any picture
            if useTint, let t = tints[i] { return t < 0.3 }                  // untinted: holder / panel
            return false
        }
        // Surround-like areas form flat patches (connected components). A patch is surround when it touches the
        // border, or lies within a few pixels of surround — across the sharp edge between a holder and the film's
        // rebate, or between the rebate and its sprocket holes.
        var label = [Int](repeating: -1, count: n)
        var comps: [[Int]] = []
        for i0 in 0..<n where label[i0] < 0 && surroundLike(i0) {
            var stack = [i0], members: [Int] = []
            label[i0] = comps.count
            while let i = stack.popLast() {
                members.append(i)
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let j = yy * w + xx
                    if label[j] < 0, surroundLike(j), abs(dens[j] - dens[i]) < 0.12 { label[j] = comps.count; stack.append(j) }
                }
            }
            comps.append(members)
        }
        var surround = [Bool](repeating: false, count: n)
        var isSurround = [Bool](repeating: false, count: comps.count)
        for (c, m) in comps.enumerated() where m.contains(where: { let x = $0 % w, y = $0 / w; return x == 0 || y == 0 || x == w - 1 || y == h - 1 }) {
            isSurround[c] = true
            for i in m { surround[i] = true }
        }
        // Shape: the rebate is a long thin band along the picture, or a ring around it; a patch lying entirely in
        // the outer margin of the scan is also surround. Flat areas inside a photo (deep shadows) are blobs.
        for (c, m) in comps.enumerated() where !isSurround[c] && m.count >= 8 {
            var bx0 = w, bx1 = 0, by0 = h, by1 = 0
            for i in m { let x = i % w, y = i / w; bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y) }
            let bw = Double(bx1 - bx0 + 1), bh = Double(by1 - by0 + 1)
            let fillRatio = Double(m.count) / (bw * bh)
            let band = (bw >= 0.4 * Double(w) && bh <= 0.2 * Double(h)) || (bh >= 0.4 * Double(h) && bw <= 0.2 * Double(w))
            let ring = bw >= 0.5 * Double(w) && bh >= 0.5 * Double(h) && fillRatio < 0.3
            let margin = Double(bx1) < 0.12 * Double(w) || Double(bx0) > 0.88 * Double(w) || Double(by1) < 0.12 * Double(h) || Double(by0) > 0.88 * Double(h)
            if band || ring || margin {
                isSurround[c] = true
                for i in m { surround[i] = true }
            }
        }
        let reach = max(2, w / 150)
        for _ in 0..<8 {
            var near = [Bool](repeating: false, count: n)
            for i in 0..<n where surround[i] {
                let x = i % w, y = i / w
                for yy in max(0, y - reach)...min(h - 1, y + reach) { for xx in max(0, x - reach)...min(w - 1, x + reach) { near[yy * w + xx] = true } }
            }
            var grew = false
            for (c, m) in comps.enumerated() where !isSurround[c] && m.count >= 4 && m.contains(where: { near[$0] }) {
                isSurround[c] = true; grew = true
                for i in m { surround[i] = true }
            }
            if !grew { break }
        }
        // The picture: the rectangle where non-surround pixels dominate (profiles refined twice).
        var x0 = 0, x1 = w, y0 = 0, y1 = h
        func run(_ p: [Double]) -> (Int, Int)? {
            guard let mx = p.max(), mx > 0.2 else { return nil }
            var best = (0, 0), start: Int?
            for (k, v) in (p + [0]).enumerated() {
                if v >= 0.5 * mx { if start == nil { start = k } } else if let s = start {
                    if k - s > best.1 - best.0 { best = (s, k) }
                    start = nil
                }
            }
            return best.1 > best.0 ? best : nil
        }
        for _ in 0..<3 {
            var rows = [Double](repeating: 0, count: h), cols = [Double](repeating: 0, count: w)
            for y in y0..<y1 { for x in x0..<x1 where !surround[y * w + x] { rows[y] += 1; cols[x] += 1 } }
            rows = rows.map { $0 / Double(x1 - x0) }
            cols = cols.map { $0 / Double(y1 - y0) }
            guard let r = run(rows), let c = run(cols) else { return nil }
            (y0, y1, x0, x1) = (r.0, r.1, c.0, c.1)
        }
        var inside = 0
        for y in y0..<y1 { for x in x0..<x1 where !surround[y * w + x] { inside += 1 } }
        let area = (x1 - x0) * (y1 - y0)
        guard area >= n / 8 else { return nil }
        return Result(rect: CGRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h),
                                   width: Double(x1 - x0) / Double(w), height: Double(y1 - y0) / Double(h)),
                      fill: Double(inside) / Double(area))
    }
}
