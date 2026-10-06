import Foundation
import simd

/// The lens corrections a DNG carries for its developer (DNG 1.4 specification, "Opcode List Processing"),
/// from OpcodeList3 — applied after demosaicing, on the camera's active area. Fixed-lens cameras and phones
/// (Leica Q, Ricoh GR, many DNGs from Adobe's converter) rely on them: without, corners are dark and lines bend.
///
/// - WarpRectilinear (opcode 1): radial and tangential distortion. With Δ = (p − c)/m (m = the largest distance
///   from the optical centre c to a corner), r² = |Δ|²:
///   source = c + m·( Δ·(k0 + k1 r² + k2 r⁴ + k3 r⁶) + tangential(t0, t1) ).
/// - FixVignetteRadial (opcode 3): gain 1 + k0 r² + k1 r⁴ + k2 r⁶ + k3 r⁸ + k4 r¹⁰.
/// Other opcodes are skipped (marked optional by cameras, or not used after demosaicing).
public struct DNGOpcodes: Sendable {
    public struct Warp: Sendable { public var planes: [[Double]]; public var center: SIMD2<Double> }   // per plane: kr0…kr3, kt0, kt1
    public struct Vignette: Sendable { public var k: [Double]; public var center: SIMD2<Double> }
    public enum Op: Sendable { case warp(Warp), vignette(Vignette) }
    public var ops: [Op]

    public var isEmpty: Bool { ops.isEmpty }
    public var warps: [Warp] { ops.compactMap { if case .warp(let w) = $0 { return w } else { return nil } } }
    public var vignettes: [Vignette] { ops.compactMap { if case .vignette(let v) = $0 { return v } else { return nil } } }

    /// Parses an opcode list (big-endian, as stored in the file).
    public init(_ data: Data) {
        var ops: [Op] = []
        let b = [UInt8](data)
        var i = 0
        func u32() -> UInt32? {
            guard i + 4 <= b.count else { return nil }
            defer { i += 4 }
            return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
        }
        func f64() -> Double? {
            guard i + 8 <= b.count else { return nil }
            var v: UInt64 = 0
            for k in 0..<8 { v = v << 8 | UInt64(b[i + k]) }
            i += 8
            return Double(bitPattern: v)
        }
        guard let count = u32() else { self.ops = []; return }
        for _ in 0..<min(count, 64) {
            guard let id = u32(), u32() != nil, u32() != nil, let size = u32() else { break }
            let end = i + Int(size)
            guard end <= b.count else { break }
            switch id {
            case 1:
                if let n = u32(), n >= 1, n <= 4 {
                    var planes: [[Double]] = []
                    for _ in 0..<n { planes.append((0..<6).compactMap { _ in f64() }) }
                    if let cx = f64(), let cy = f64(), planes.allSatisfy({ $0.count == 6 }) {
                        ops.append(.warp(Warp(planes: planes, center: [cx, cy])))
                    }
                }
            case 3:
                let k = (0..<5).compactMap { _ in f64() }
                if k.count == 5, let cx = f64(), let cy = f64() { ops.append(.vignette(Vignette(k: k, center: [cx, cy]))) }
            default:
                break
            }
            i = end
        }
        self.ops = ops
    }

    /// Optical centre (px) and normalising distance for an active area of `w` × `h`.
    static func geometry(_ c: SIMD2<Double>, _ w: Int, _ h: Int) -> (SIMD2<Double>, Double) {
        let center = c * SIMD2(Double(w), Double(h))
        let corners: [SIMD2<Double>] = [[0, 0], [Double(w), 0], [0, Double(h)], [Double(w), Double(h)]]
        return (center, corners.map { simd_length($0 - center) }.max() ?? 1)
    }

    /// Applies the distortion corrections (Catmull-Rom resampling; values outside the frame are clamped).
    public static func applyWarps(_ warps: [Warp], to img: inout LinearImage) {
        for wp in warps {
            let w = img.width, h = img.height
            let (c, m) = geometry(wp.center, w, h)
            let src = img
            var out = [Float](repeating: 1, count: w * h * 4)
            func cubic(_ t: Double) -> SIMD4<Double> {
                let t2 = t * t, t3 = t2 * t
                return SIMD4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
            }
            src.pixels.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBufferPointer { o in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            let d = (SIMD2(Double(x) + 0.5, Double(y) + 0.5) - c) / m
                            let r2 = simd_length_squared(d)
                            for ch in 0..<3 {
                                let k = wp.planes[min(ch, wp.planes.count - 1)]
                                let f = k[0] + r2 * (k[1] + r2 * (k[2] + r2 * k[3]))
                                let t = SIMD2(k[4] * 2 * d.x * d.y + k[5] * (r2 + 2 * d.x * d.x),
                                              k[5] * 2 * d.x * d.y + k[4] * (r2 + 2 * d.y * d.y))
                                let p = c + m * (d * f + t) - 0.5
                                let x0 = Int(floor(p.x)), y0 = Int(floor(p.y))
                                let wx = cubic(p.x - Double(x0)), wy = cubic(p.y - Double(y0))
                                var acc = 0.0
                                for j in 0..<4 {
                                    let yy = min(max(y0 - 1 + j, 0), h - 1)
                                    var row = 0.0
                                    for i in 0..<4 {
                                        let xx = min(max(x0 - 1 + i, 0), w - 1)
                                        row += wx[i] * Double(s[(yy * w + xx) * 4 + ch])
                                    }
                                    acc += wy[j] * row
                                }
                                o[(y * w + x) * 4 + ch] = Float(max(acc, 0))
                            }
                        }
                    }
                }
            }
            img = LinearImage(width: w, height: h, pixels: out)
        }
    }

    /// Applies the vignetting corrections to `img`, which is the region at `origin` of an active area of
    /// `full` size (after a crop).
    public static func applyVignettes(_ vigs: [Vignette], to img: inout LinearImage, origin: (x: Int, y: Int), full: (w: Int, h: Int)) {
        for v in vigs {
            let (c, m) = geometry(v.center, full.w, full.h)
            let w = img.width, h = img.height
            img.pixels.withUnsafeMutableBufferPointer { p in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let d = (SIMD2(Double(x + origin.x) + 0.5, Double(y + origin.y) + 0.5) - c) / m
                        let r2 = simd_length_squared(d)
                        let g = Float(1 + r2 * (v.k[0] + r2 * (v.k[1] + r2 * (v.k[2] + r2 * (v.k[3] + r2 * v.k[4])))))
                        let i = (y * w + x) * 4
                        p[i] *= g; p[i + 1] *= g; p[i + 2] *= g
                    }
                }
            }
        }
    }
}
