import Foundation
import simd

/// A plausible colour-negative film + scanning model used to manufacture negatives from known scenes.
///
///   film exposure      E_c   = camera-balanced scene RGB × exposure     (idealised: layer = camera channel)
///   image density      D_c   = γ_c · softplus_w(log10 E_c − log10 E_min)   (straight line when w = 0)
///   total density      D_tot = mask_c + fog_c + D_c                     (orange mask: high in G and B)
///   scan               I_c   = panel_c · 10^(−D_tot)
public struct SyntheticFilm: Sendable {
    public var gamma: SIMD3<Double> = [0.52, 0.60, 0.70]
    public var mask: SIMD3<Double> = [0.22, 0.62, 0.95]
    public var fog: SIMD3<Double> = [0.05, 0.06, 0.08]
    /// Exposure below which the film records nothing (toe region starts around here).
    public var logEMin = log10(0.18) - 2.2
    /// Toe width in log10 exposure (0 = ideal straight line).
    public var toeWidth: SIMD3<Double> = [0, 0, 0]
    /// Light reaching the camera through clear film (camera-balanced units, below clipping).
    public var panel: SIMD3<Double> = [0.85, 0.80, 0.82]

    public func density(exposure e: SIMD3<Double>) -> SIMD3<Double> {
        var d = SIMD3<Double>()
        for c in 0..<3 {
            let x = log10(max(e[c], 1e-12)) - logEMin
            let w = toeWidth[c]
            let soft = w > 0 ? w * log10(1 + pow(10, x / w)) : max(x, 0)
            d[c] = gamma[c] * soft
        }
        return d
    }

    public func scan(exposure e: SIMD3<Double>) -> SIMD3<Double> {
        let d = mask + fog + density(exposure: e)
        return panel * SIMD3(pow(10, -d.x), pow(10, -d.y), pow(10, -d.z))
    }

    public init() {}

    /// Unexposed film (rebate).
    public var rebate: SIMD3<Double> { scan(exposure: SIMD3(repeating: 1e-12)) }
}

