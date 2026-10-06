import Foundation
import simd

/// Rebuilds clipped channels of a demosaiced, linear, balanced camera-RGB image.
///
/// Why: each raw channel saturates at a different level once white-balanced (`clipLevel`). Where only
/// green has clipped, red and blue keep rising and bright neutrals turn magenta; where everything has
/// clipped the result is a flat, often tinted, plateau.
///
/// Method ("inpaint opposed", segmented, in the spirit of darktable's highlight reconstruction):
/// 1. Clipped areas are found on a 4×4-pixel block grid and split into connected segments.
/// 2. For each segment, the colour of the light is estimated from the bright, unclipped pixels in a
///    ring around it (chromaticity r = v / (v_r + v_g + v_b), weighted towards the brightest pixels).
///    With too few ring pixels the camera's as-shot neutral is used instead.
/// 3. In clipped pixels, each clipped channel is re-estimated from the unclipped channels of the same
///    pixel through the segment's ratios: est_c = mean_j (r_c / r_j) · v_j. If every channel is clipped
///    the segment colour is scaled to cover all of them. Values are only ever raised, never lowered, and
///    blended in smoothly over the last 10 % below the clip level so there is no visible seam.
public enum HighlightReconstruction {
    static let block = 4

    /// Returns the number of pixels that were modified.
    @discardableResult
    public static func apply(to img: inout LinearImage, clipLevel: SIMD3<Double>, neutral: SIMD3<Double>) -> Int {
        let w = img.width, h = img.height, B = block
        let bw = (w + B - 1) / B, bh = (h + B - 1) / B
        let thr = SIMD3<Float>(clipLevel * 0.985)

        // 1. Clipped blocks.
        var clipped = [Bool](repeating: false, count: bw * bh)
        img.pixels.withUnsafeBufferPointer { px in
            clipped.withUnsafeMutableBufferPointer { cb in
                DispatchQueue.concurrentPerform(iterations: bh) { by in
                    for bx in 0..<bw {
                        var any = false
                        for y in (by * B)..<min(h, by * B + B) where !any {
                            for x in (bx * B)..<min(w, bx * B + B) {
                                let i = (y * w + x) * 4
                                if px[i] >= thr.x || px[i + 1] >= thr.y || px[i + 2] >= thr.z { any = true; break }
                            }
                        }
                        cb[by * bw + bx] = any
                    }
                }
            }
        }
        guard clipped.contains(true) else { return 0 }

        // 2. Connected segments (8-connectivity) with union-find.
        var parent = [Int32](repeating: -1, count: bw * bh)
        func find(_ a: Int) -> Int {
            var r = a
            while parent[r] != Int32(r) { r = Int(parent[r]) }
            var c = a
            while parent[c] != Int32(r) { let n = Int(parent[c]); parent[c] = Int32(r); c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = Int32(min(ra, rb)) }
        }
        for by in 0..<bh {
            for bx in 0..<bw where clipped[by * bw + bx] {
                let i = by * bw + bx
                parent[i] = Int32(i)
                for (dx, dy) in [(-1, 0), (-1, -1), (0, -1), (1, -1)] {
                    let nx = bx + dx, ny = by + dy
                    if nx >= 0, ny >= 0, nx < bw, clipped[ny * bw + nx] { union(i, ny * bw + nx) }
                }
            }
        }
        var label = [Int32](repeating: -1, count: bw * bh)
        var labelOfRoot = [Int: Int32]()
        for i in 0..<(bw * bh) where clipped[i] {
            let r = find(i)
            if let l = labelOfRoot[r] { label[i] = l } else { let l = Int32(labelOfRoot.count); labelOfRoot[r] = l; label[i] = l }
        }
        let segments = labelOfRoot.count

        // Ring: unclipped blocks within 2 blocks of a segment take that segment's label (multi-source BFS).
        var ring = [Int32](repeating: -1, count: bw * bh)
        var dist = [UInt8](repeating: 255, count: bw * bh)
        var queue = [Int]()
        queue.reserveCapacity(bw * bh / 8)
        for i in 0..<(bw * bh) where clipped[i] { dist[i] = 0; queue.append(i) }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let d = dist[i]
            if d >= 2 { continue }
            let bx = i % bw, by = i / bw
            let l = clipped[i] ? label[i] : ring[i]
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = bx + dx, ny = by + dy
                    guard nx >= 0, ny >= 0, nx < bw, ny < bh else { continue }
                    let j = ny * bw + nx
                    if dist[j] == 255 { dist[j] = d + 1; ring[j] = l; queue.append(j) }
                }
            }
        }

        // 3. Light colour per segment from bright unclipped ring pixels, weighted by brightness².
        var sums = [SIMD3<Double>](repeating: .zero, count: segments)
        var weights = [Double](repeating: 0, count: segments)
        var counts = [Int](repeating: 0, count: segments)
        let thrD = SIMD3<Double>(thr)
        img.pixels.withUnsafeBufferPointer { px in
            for by in 0..<bh {
                for bx in 0..<bw {
                    let bi = by * bw + bx
                    let l = ring[bi]
                    guard l >= 0, !clipped[bi] else { continue }
                    for y in (by * B)..<min(h, by * B + B) {
                        for x in (bx * B)..<min(w, bx * B + B) {
                            let i = (y * w + x) * 4
                            let v = SIMD3<Double>(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
                            let rel = v / thrD
                            guard rel.max() < 0.95, rel.min() > 0.02, rel.max() > 0.25 else { continue }
                            let s = v.sum()
                            let wgt = rel.max() * rel.max()
                            sums[Int(l)] += wgt * v / s
                            weights[Int(l)] += wgt
                            counts[Int(l)] += 1
                        }
                    }
                }
            }
        }
        let n0 = neutral / neutral.sum()
        let ratios: [SIMD3<Float>] = (0..<segments).map { k in
            guard counts[k] >= 24, weights[k] > 0 else { return SIMD3<Float>(n0) }
            return SIMD3<Float>(sums[k] / weights[k])
        }

        // 4. Rebuild clipped channels.
        var changedRows = [Int](repeating: 0, count: h)
        img.pixels.withUnsafeMutableBufferPointer { px in
            changedRows.withUnsafeMutableBufferPointer { cr in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let by = y / B
                    var changed = 0
                    for x in 0..<w {
                        let l = label[by * bw + x / B]
                        guard l >= 0 else { continue }
                        let i = (y * w + x) * 4
                        let v = SIMD3<Float>(px[i], px[i + 1], px[i + 2])
                        // Blend weight per channel: 0 below 90 % of the clip level, 1 at the clip level.
                        let t = simd_clamp((v / thr - 0.9) / 0.1, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                        let wgt = t * t * (3 - 2 * t)
                        guard wgt.max() > 0 else { continue }
                        let r = ratios[Int(l)]
                        var est = SIMD3<Float>.zero
                        var n: Float = 0
                        for j in 0..<3 where v[j] < thr[j] { est += v[j] / max(r[j], 1e-6) * r; n += 1 }
                        if n > 0 {
                            est /= n
                        } else {
                            var s: Float = 0
                            for j in 0..<3 { s = max(s, v[j] / max(r[j], 1e-6)) }
                            est = r * s
                        }
                        let out = v + wgt * simd_max(est - v, .zero)
                        if out != v {
                            px[i] = out.x; px[i + 1] = out.y; px[i + 2] = out.z
                            changed += 1
                        }
                    }
                    cr[y] = changed
                }
            }
        }
        return changedRows.reduce(0, +)
    }
}
