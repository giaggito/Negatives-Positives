import CoreGraphics
import Foundation
import ImageIO
import PositivesCore
import simd

/// `positives-cli make-looks <HaldCLUT folder> <out.lzfse> [--analyze]`: converts the level-12 Hald CLUTs (8-bit
/// sRGB, 144³) of the film looks into the app's tables: the 8-bit quantisation is smoothed away (a light 3D
/// Gaussian on the difference from identity, σ = 1 grid step = 0.7 % of the range) so gradients through a look
/// stay smooth, then the cube is resampled to `FilmLooks.tableSize`³ and stored as 16-bit.
enum MakeLooks {
    struct Cube {
        let n: Int
        var v: [SIMD3<Float>]
        func at(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> { v[(k * n + j) * n + i] }
        func sample(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let x = simd_clamp(c, .zero, .one) * Float(n - 1)
            let i0 = SIMD3<Int>(min(Int(x.x), n - 2), min(Int(x.y), n - 2), min(Int(x.z), n - 2))
            let t = x - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
            var r = SIMD3<Float>.zero
            for c in 0..<8 {
                let o = SIMD3<Int>(c & 1, (c >> 1) & 1, c >> 2)
                let w = (o.x == 1 ? t.x : 1 - t.x) * (o.y == 1 ? t.y : 1 - t.y) * (o.z == 1 ? t.z : 1 - t.z)
                r += w * at(i0.x + o.x, i0.y + o.y, i0.z + o.z)
            }
            return r
        }
    }

    static func loadHald(_ url: URL) throws -> Cube {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "make-looks", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot read \(url.lastPathComponent)"])
        }
        let w = img.width, h = img.height
        // Level L: an L³ × L³ image holding an L² cube.
        let level = Int((Double(w)).squareRoot().squareRoot().squareRoot().rounded() == 0 ? 0 : (pow(Double(w), 1.0 / 3).rounded()))
        precondition(w == h && level * level * level == w, "\(url.lastPathComponent): not a Hald CLUT (\(w)×\(h))")
        let grey = img.colorSpace?.numberOfComponents == 1
        // Read the stored pixel values as they are (no colour management).
        let data = img.dataProvider!.data! as Data
        let bpp = img.bitsPerPixel / 8, bpr = img.bytesPerRow, bpc = img.bitsPerComponent
        let alphaFirst = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(img.alphaInfo)
        let little = img.bitmapInfo.contains(.byteOrder16Little)
        func w16(_ p: UnsafeRawBufferPointer, _ o: Int) -> Float {
            let x = p.loadUnaligned(fromByteOffset: o, as: UInt16.self)
            return Float(little ? UInt16(littleEndian: x) : UInt16(bigEndian: x))
        }
        let n = level * level
        var v = [SIMD3<Float>](repeating: .zero, count: n * n * n)
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    let o = y * bpr + x * bpp + (alphaFirst ? bpc / 8 : 0)
                    let c: SIMD3<Float>
                    if grey {
                        let g = bpc == 16 ? w16(p, o) / 65535 : Float(p[o]) / 255
                        c = SIMD3(repeating: g)
                    } else if bpc == 16 {
                        c = SIMD3(w16(p, o), w16(p, o + 2), w16(p, o + 4)) / 65535
                    } else {
                        c = SIMD3(Float(p[o]), Float(p[o + 1]), Float(p[o + 2])) / 255
                    }
                    v[y * w + x] = c
                }
            }
        }
        return Cube(n: n, v: v)
    }

    static func identity(_ n: Int, _ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        SIMD3(Float(i), Float(j), Float(k)) / Float(n - 1)
    }

    /// Gaussian smoothing of (cube − identity) along the three axes, edges replicated.
    static func smooth(_ c: Cube, sigma: Float) -> Cube {
        let n = c.n
        var r = [SIMD3<Float>](repeating: .zero, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n { r[(k * n + j) * n + i] = c.at(i, j, k) - identity(n, i, j, k) } } }
        let rad = Int(ceil(3 * sigma))
        var w = (-rad...rad).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let s = w.reduce(0, +); w = w.map { $0 / s }
        for axis in 0..<3 {
            let out = UnsafeMutableBufferPointer<SIMD3<Float>>.allocate(capacity: r.count)
            defer { out.deallocate() }
            let rr = r
            let stride = axis == 0 ? 1 : (axis == 1 ? n : n * n)
            DispatchQueue.concurrentPerform(iterations: n * n) { line in
                let a = line % n, b = line / n
                let base: Int
                switch axis {
                case 0: base = (b * n + a) * n
                case 1: base = b * n * n + a
                default: base = b * n + a
                }
                for t in 0..<n {
                    var acc = SIMD3<Float>.zero
                    for (q, wq) in w.enumerated() {
                        let u = min(max(t + q - rad, 0), n - 1)
                        acc += wq * rr[base + u * stride]
                    }
                    out[base + t * stride] = acc
                }
            }
            r = Array(out)
        }
        var v = r
        for k in 0..<n { for j in 0..<n { for i in 0..<n { v[(k * n + j) * n + i] = simd_clamp(r[(k * n + j) * n + i] + identity(n, i, j, k), .zero, .one) } } }
        return Cube(n: n, v: v)
    }

    static func resample(_ c: Cube, to m: Int) -> Cube {
        var v = [SIMD3<Float>](repeating: .zero, count: m * m * m)
        for k in 0..<m { for j in 0..<m { for i in 0..<m { v[(k * m + j) * m + i] = c.sample(identity(m, i, j, k)) } } }
        return Cube(n: m, v: v)
    }

    static func run(dir: URL, out: URL, analyze: Bool) throws {
        let id = try loadHald(dir.appendingPathComponent("Hald_CLUT_Identity_12.tif"))
        var worstId: Float = 0
        for k in 0..<144 { for j in 0..<144 { for i in 0..<144 { worstId = max(worstId, simd_reduce_max(simd_abs(id.at(i, j, k) - identity(144, i, j, k)))) } } }
        print(String(format: "identity check: worst %.4f (should be ≤ 1/255 = 0.0039)", worstId))
        let files = Array(Set(FilmLooks.shared.looks.flatMap { $0.variants.values })).sorted()
        var tables: [(String, FilmLooks.Table)] = []
        for f in files {
            let raw = try loadHald(dir.appendingPathComponent(f + ".png"))
            let sm = smooth(raw, sigma: Float(raw.n - 1) / 143)
            let m = FilmLooks.tableSize
            let small = resample(sm, to: m)
            if analyze {
                var rng = SystemRandomNumberGenerator()
                for size in [33, 48, 65] {
                    let s2 = size == m ? small : resample(sm, to: size)
                    var worst: Float = 0, sum: Float = 0
                    for _ in 0..<20000 {
                        let c = SIMD3<Float>(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng))
                        let e = simd_reduce_max(simd_abs(s2.sample(c) - sm.sample(c))) * 255
                        worst = max(worst, e); sum += e
                    }
                    print(String(format: "  %@ %d³: worst %.2f, mean %.3f (8-bit codes)", f, size, worst, sum / 20000))
                }
                var dev: Float = 0
                for _ in 0..<20000 {
                    let c = SIMD3<Float>(Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng), Float.random(in: 0...1, using: &rng))
                    dev = max(dev, simd_reduce_max(simd_abs(sm.sample(c) - raw.sample(c))) * 255)
                }
                print(String(format: "  %@ smoothing changes it by at most %.2f codes", f, dev))
            }
            tables.append((f, FilmLooks.Table(size: m, values: small.v.map { SIMD4($0, 1) })))
            print("converted \(f)")
        }
        let packed = try (FilmLooks.encode(tables) as NSData).compressed(using: .lzfse) as Data
        try packed.write(to: out)
        print(String(format: "wrote %d tables, %.1f MB", tables.count, Double(packed.count) / 1e6))
    }
}
