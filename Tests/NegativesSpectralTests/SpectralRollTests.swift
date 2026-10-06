import CoreGraphics
import Foundation
import NegativesBench
import NegativesCore
import PositivesCore
import simd
import Testing

/// Negatives against physically simulated scans of real colour stocks (spectral data from spektrafilm via
/// PositivesCore): different cameras, lights, film exposures and framings, fully automatic. The scene is
/// synthetic and known, so neutrality and exposure can be measured.
@Suite("Spectral scans of real stocks", .serialized)
struct SpectralRollTests {
    /// A small outdoor-like scene: sky gradient, textured ground, a ColorChecker-like row of colours and a
    /// grey ramp (linear Rec.2020, middle grey 0.184).
    static let scene = landscapeScene

    /// Grey-ramp neutrality (OKLab chroma ×100) of a scene-linear conversion.
    static func rampCast(_ out: LinearImage, picture r: CGRect) -> Double {
        var acc = SIMD2<Double>.zero, n = 0.0
        let h = scene.height
        for y in (h * 3 / 5 + 4)..<(h * 7 / 10 - 4) {
            for x in stride(from: 20, to: scene.width - 20, by: 3) {
                let o = ToneMath.oklab(simd_max(out[x + Int(r.minX), y + Int(r.minY)], .zero))
                acc += SIMD2(Double(o.y), Double(o.z)); n += 1
            }
        }
        return simd_length(acc / n) * 100
    }

    @Test("Automatic conversion stays neutral and evenly exposed", arguments: [
        ("fujifilm_c200", 0, 0, Framing.holder), ("fujifilm_c200", 1, 2, Framing.strip), ("kodak_gold_200", 0, 1, Framing.tight),
        ("kodak_portra_400", 2, 0, Framing.stripHolder), ("fujifilm_xtra_400", 1, 1, Framing.holder),
    ])
    func roll(_ stock: String, _ camera: Int, _ light: Int, _ framing: Framing) throws {
        let sim = try #require(ScanSimulator(stock: stock, camera: Camera.all[camera], light: Light.all[light]))
        let evs: [Float] = [-1, 0, 2]
        let scans = evs.enumerated().map { sim.scan(scene: Self.scene, ev: $1, framing: framing, brightness: $0 == 1 ? 0.5 : 0.85, seed: UInt64($0 + 1)) }
        let outs = try convertRoll(scans.map(\.0), stage: .sceneLinear)
        try #require(outs.count == 3)
        var exposures: [Double] = []
        for (i, o) in outs.enumerated() {
            let s = score(o, scene: Self.scene, picture: scans[i].1)
            let ramp = Self.rampCast(o, picture: scans[i].1)
            exposures.append(s.exposure)
            // A hard scene on purpose: 40 % blue sky, little neutral content, some scans without any film edge
            // (no measured base). Real photos do better (bench: median cast 0.8); these bounds catch regressions.
            #expect(ramp < 6, "\(stock) film \(evs[i]) EV: grey ramp chroma \(ramp)")
            #expect(s.cast < 7, "\(stock) film \(evs[i]) EV: neutral cast \(s.cast)")
            #expect(abs(s.exposure) < 1.5, "\(stock) film \(evs[i]) EV: exposure error \(s.exposure)")
        }
        // Under- and overexposed frames print alike (a lab's per-frame exposure).
        #expect(exposures.max()! - exposures.min()! < 0.8, "\(stock): exposures \(exposures)")
    }
}
