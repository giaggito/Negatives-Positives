import Foundation

/// Debug checks that a pipeline stage holds full-precision float data: no NaN/Inf, no hidden quantisation
/// to 8 bits, and a record of how many values fall outside 0…1 (which is allowed — nothing is clipped —
/// but worth knowing).
public struct StageAudit: CustomStringConvertible, Sendable {
    public var name: String
    public var count: Int
    public var nonFinite: Int
    public var minimum: SIMD3<Float>
    public var maximum: SIMD3<Float>
    public var belowZero: Double
    public var aboveOne: Double
    /// Fraction of in-range values that sit exactly on the 8-bit lattice k/255. Float data from a
    /// lossless pipeline sits there only by coincidence (≈ 0.1% with a 1e-5 tolerance).
    public var on8BitLattice: Double
    /// Distinct values among the sampled green channel. A quantised stage has at most a few hundred.
    public var distinctLevels: Int

    public var looksQuantizedTo8Bit: Bool { on8BitLattice > 0.5 || distinctLevels <= 256 }

    public var description: String {
        String(format: "%-14@ n=%d nonFinite=%d min=(%.4g %.4g %.4g) max=(%.4g %.4g %.4g) <0: %.3f%% >1: %.3f%% 8-bit lattice: %.2f%% levels: %d%@",
               name as NSString, count, nonFinite, minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z,
               belowZero * 100, aboveOne * 100, on8BitLattice * 100, distinctLevels,
               looksQuantizedTo8Bit ? "  ⚠︎ QUANTISED?" : "")
    }

    public static func audit(_ img: LinearImage, name: String, sampleStride: Int = 7) -> StageAudit {
        var nonFinite = 0, below = 0, above = 0, lattice = 0, inRange = 0, n = 0
        var mn = SIMD3<Float>(repeating: .infinity), mx = SIMD3<Float>(repeating: -.infinity)
        var levels = Set<Float>()
        var i = 0
        let total = img.width * img.height
        while i < total {
            let v = SIMD3(img.pixels[i * 4], img.pixels[i * 4 + 1], img.pixels[i * 4 + 2])
            for k in 0..<3 {
                let c = v[k]
                guard c.isFinite else { nonFinite += 1; continue }
                n += 1
                mn[k] = min(mn[k], c); mx[k] = max(mx[k], c)
                if c < 0 { below += 1 } else if c > 1 { above += 1 } else if c > 0 && c < 1 {
                    inRange += 1
                    let s = c * 255
                    if abs(s - s.rounded()) < 1e-3 { lattice += 1 }
                }
            }
            if levels.count < 100_000 { levels.insert(v.y) }
            i += sampleStride
        }
        return StageAudit(name: name, count: n, nonFinite: nonFinite, minimum: mn, maximum: mx,
                          belowZero: Double(below) / Double(max(n, 1)), aboveOne: Double(above) / Double(max(n, 1)),
                          on8BitLattice: Double(lattice) / Double(max(inRange, 1)), distinctLevels: levels.count)
    }
}
