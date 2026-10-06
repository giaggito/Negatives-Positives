import CoreGraphics
import Foundation
import NegativesCore
import PositivesCore
import simd

public struct Score {
    public var exposure: Double, cast: Double, colour: Double, castVec: SIMD2<Double>
}

/// Compares a scene-linear conversion with the scene inside the picture (inset 5 %).
public func score(_ out: LinearImage, scene: LinearImage, picture r: CGRect) -> Score {
    var logs: [Double] = []
    let x0 = Int(r.minX), y0 = Int(r.minY)
    let ins = scene.width / 20
    for y in stride(from: ins, to: scene.height - ins, by: 2) {
        for x in stride(from: ins, to: scene.width - ins, by: 2) {
            let sv = scene[x, y], ov = out[x + x0, y + y0]
            let ys = ToneMath.lum(sv), yo = ToneMath.lum(ov)
            if ys > 0.01, ys < 1, yo > 1e-5 { logs.append(log2(Double(yo / ys))) }
        }
    }
    let ev = logs.isEmpty ? 0 : logs.sorted()[logs.count / 2]
    let k = Float(pow(2, -ev))
    var castAcc = SIMD2<Double>.zero, castN = 0.0, colAcc = 0.0, colN = 0.0
    for y in stride(from: ins, to: scene.height - ins, by: 2) {
        for x in stride(from: ins, to: scene.width - ins, by: 2) {
            let sv = scene[x, y], ov = out[x + x0, y + y0] * k
            let ys = ToneMath.lum(sv)
            guard ys > 0.01, ys < 1 else { continue }
            let ls = ToneMath.oklab(sv), lo = ToneMath.oklab(simd_max(ov, .zero))
            colAcc += Double(simd_length(lo - ls)) * 100; colN += 1
            if simd_length(SIMD2(ls.y, ls.z)) < 0.02 {
                castAcc += SIMD2(Double(lo.y - ls.y), Double(lo.z - ls.z)) * 100; castN += 1
            }
        }
    }
    let cv = castN > 0 ? castAcc / castN : .zero
    return Score(exposure: ev, cast: simd_length(cv), colour: colN > 0 ? colAcc / colN : 0, castVec: cv)
}

/// Converts a roll of synthetic scans with the real Negatives analysis and pipeline.
public func convertRoll(_ raws: [RawImage], stage: OutputStage) throws -> [LinearImage] {
    var roll = RollSettings()
    let proxies = raws.map { AnalysisProxy(raw: $0, flat: nil) }
    guard Processor.measureFilmBase(proxies[0], file: "f0", rect: nil, roll: &roll) else { return [] }
    var settings = raws.map { _ in FrameSettings() }
    for i in raws.indices { Processor.measureAnchors(proxies[i], roll: roll, settings: &settings[i]) }
    Processor.analyzeRoll(&roll, frames: settings)
    if ProcessInfo.processInfo.environment["BENCH_ONLY"] != nil {
        print("  base \(roll.filmBase!)  path \(roll.calibration?.neutral?.map { String(format: "(%.2f %+.3f %+.3f)", $0.x, $0.y, $0.z) }.joined(separator: " ") ?? "-")")
        for (i, st) in settings.enumerated() {
            print("  frame \(i): picture \(st.stats?.picture.map { String(format: "%.2f,%.2f %.2fx%.2f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-")")
            for n in st.stats?.neutrals ?? [] { print(String(format: "     band %d g %.2f  %+.3f %+.3f  w %.2f", n.band, n.g, n.dr, n.db, n.weight)) }
            if let s = st.stats { print("     path: " + Estimators.framePath(s).map { String(format: "(%.2f %+.3f %+.3f)", $0.g, $0.dr, $0.db) }.joined(separator: " ")) }
        }
    }
    let proc = try Processor()
    return try raws.indices.map { i in
        var img = try proc.render(DecodedFrame(url: URL(fileURLWithPath: "/tmp/f\(i)"), raw: raws[i]), roll: roll, settings: settings[i], stage: stage)
        if stage == .sceneLinear {
            // The frame's exposure is applied in the print step; include it in the scene-linear comparison.
            let p = try ConversionParameters.resolve(roll: roll, frame: settings[i], cameraToRec2020: raws[i].cameraToRec2020)
            let k = Float(pow(2, p.curve.exposure))
            for j in 0..<img.pixels.count where j % 4 != 3 { img.pixels[j] *= k }
        }
        return img
    }
}


/// The spectral tests' synthetic landscape (sky, colours, grey ramp, ground).
public let landscapeScene: LinearImage = {
    let w = 360, h = 240
    var img = LinearImage(width: w, height: h)
    var s: UInt32 = 12345
    func rnd() -> Float { s = s &* 1664525 &+ 1013904223; return Float(s >> 8) / Float(1 << 24) }
    let patches: [SIMD3<Float>] = [[0.45, 0.32, 0.27], [0.75, 0.58, 0.50], [0.38, 0.48, 0.61], [0.35, 0.42, 0.27], [0.84, 0.48, 0.17],
                                   [0.76, 0.33, 0.38], [0.62, 0.74, 0.25], [0.17, 0.24, 0.58], [0.93, 0.78, 0.12], [0.0, 0.52, 0.65]]
    let toLinear = simd_float3x3(ColorScience.sRGBToRec2020)
    for y in 0..<h {
        for x in 0..<w {
            var v: SIMD3<Float>
            if y < h * 2 / 5 {
                let t = Float(y) / Float(h * 2 / 5)
                v = SIMD3(0.35, 0.5, 0.85) * (1.6 - 0.6 * t)                      // sky
            } else if y < h * 3 / 5 {
                let i = x * patches.count / w
                let p = patches[i]
                v = toLinear * SIMD3(pow(p.x, 2.2), pow(p.y, 2.2), pow(p.z, 2.2))   // colours
            } else if y < h * 7 / 10 {
                v = SIMD3(repeating: 0.02 * pow(45, Float(x) / Float(w - 1)))       // grey ramp 0.02 … 0.9
            } else {
                let n = 0.6 + 0.8 * rnd()
                v = SIMD3(0.10, 0.12, 0.05) * n + SIMD3(0.05, 0.04, 0.03) * rnd()  // ground
            }
            img[x, y] = v
        }
    }
    return img
}()
