import CoreGraphics
import Foundation
import NegativesBench
import NegativesCore
import PositivesCore
import simd

setvbuf(stdout, nil, _IOLBF, 0)

let stocks = ["fujifilm_c200", "kodak_gold_200", "kodak_portra_400", "kodak_ektar_100", "kodak_ultramax_400", "fujifilm_xtra_400",
              "fujifilm_pro_400h", "kodak_portra_160", "kodak_portra_800"]

func fmt(_ v: Double, _ p: Int = 3) -> String { String(format: "%+.\(p)f", v) }

/// The neutral path: base-normalised camera densities of greys from −3 to +5 stops around middle grey.
func loci() {
    for stock in stocks {
        for cam in Camera.all {
            for light in Light.all {
                guard let sim = ScanSimulator(stock: stock, camera: cam, light: light) else { continue }
                var line = "\(stock.padding(toLength: 19, withPad: " ", startingAt: 0)) \(cam.name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(light.name.padding(toLength: 8, withPad: " ", startingAt: 0))"
                for ev in stride(from: -3.0, through: 5.0, by: 1.0) {
                    let v = sim.cameraValue(scene: SIMD3(repeating: 0.184), ev: Float(ev))
                    let d = NegativeModel.density(v, base: sim.baseValue)
                    line += String(format: "  %+.0f:G%.2f R%+.2f B%+.2f", ev, d.y, d.x - d.y, d.z - d.y)
                }
                print(line)
            }
        }
    }
}

/// Scene radiance (linear Rec.2020, normal exposure) from a photo, at most `maxSize` px wide.
func loadScene(_ url: URL, maxSize: Int = 1400) -> LinearImage? {
    guard let s = try? SourceLoader.load(url: url) else { return nil }
    let m = simd_float3x3(s.inputMatrix(whiteBalance: nil)) * Float(pow(2, s.baselineExposure))
    var img = s.image.downsampled(by: max(1, s.image.width / maxSize))
    for y in 0..<img.height {
        for x in 0..<img.width {
            var v = img[x, y]
            if s.kind == .display { v = ToneMath.shoulderInverse(v) }
            img[x, y] = simd_max(m * v, .zero)
        }
    }
    return img
}

func run(_ sceneURLs: [URL], sheet: URL?) throws {
    let scenes = sceneURLs.compactMap { loadScene($0) }
    print("\(scenes.count) scenes")
    var all: [(String, Score)] = []
    var rng = 7
    var sheetImgs: [LinearImage] = []
    for stock in stocks {
        for cam in Camera.all {
            for light in Light.all {
                guard let sim = ScanSimulator(stock: stock, camera: cam, light: light) else { continue }
                rng = (rng * 1103515245 + 12345) & 0x7fffffff
                if let only = ProcessInfo.processInfo.environment["BENCH_ONLY"], only != "\(stock) \(cam.name) \(light.name)" { continue }
                let framing = Framing.allCases[rng % Framing.allCases.count]
                let evs: [Float] = [-1, 0, 2]
                var raws: [RawImage] = [], rects: [CGRect] = [], used: [LinearImage] = []
                for f in 0..<3 {
                    let scene = scenes[(rng / 7 + f) % scenes.count]
                    let (raw, rect) = sim.scan(scene: scene, ev: evs[f], framing: framing, brightness: f == 1 ? 0.5 : 0.85, seed: UInt64(rng + f))
                    raws.append(raw); rects.append(rect); used.append(scene)
                }
                let outs = try convertRoll(raws, stage: .sceneLinear)
                guard outs.count == 3 else { print("\(stock) \(cam.name) \(light.name): failed"); continue }
                var line = "\(stock.padding(toLength: 19, withPad: " ", startingAt: 0)) \(cam.name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(light.name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(framing.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0))"
                for f in 0..<3 {
                    let s = score(outs[f], scene: used[f], picture: rects[f])
                    all.append(("\(stock) \(cam.name) \(light.name) \(framing.rawValue)", s))
                    line += String(format: "  ev %+.2f cast %4.1f (%+.1f %+.1f) dE %4.1f", s.exposure, s.cast, s.castVec.x, s.castVec.y, s.colour)
                }
                print(line)
                if sheet != nil, sheetImgs.count < 24 {
                    let pos = try convertRoll(raws, stage: .positive)
                    sheetImgs.append(contentsOf: pos.prefix(1))
                }
            }
        }
    }
    let casts = all.map(\.1.cast).sorted(), evs = all.map { abs($0.1.exposure) }.sorted()
    print(String(format: "\nFRAMES %d   cast median %.1f p90 %.1f max %.1f   |exposure| median %.2f p90 %.2f max %.2f   colour dE median %.1f",
                 all.count, casts[casts.count / 2], casts[casts.count * 9 / 10], casts.last!, evs[evs.count / 2], evs[evs.count * 9 / 10], evs.last!,
                 all.map(\.1.colour).sorted()[all.count / 2]))
    if let sheet, !sheetImgs.isEmpty {
        // Contact sheet: 4 columns of the first frame of rolls, each scaled to 400 px wide.
        let cw = 400, cols = 4
        let cells = sheetImgs.map { img -> LinearImage in
            let f = max(1, img.width / cw)
            return img.downsampled(by: f)
        }
        let ch = cells.map(\.height).max()!
        let rows = (cells.count + cols - 1) / cols
        var out = LinearImage(width: cols * cw, height: rows * ch)
        for (n, c) in cells.enumerated() {
            let ox = (n % cols) * cw, oy = (n / cols) * ch
            for y in 0..<min(c.height, ch) { for x in 0..<min(c.width, cw) { out[ox + x, oy + y] = c[x, y] } }
        }
        try Exporter.write(out, to: sheet, format: .jpeg, space: .sRGB)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "loci": loci()
case "diag":
    // Estimated roll path vs the true neutral path, on the synthetic landscape.
    let sim = ScanSimulator(stock: args[1], camera: Camera.all[Int(args[2])!], light: Light.all[Int(args[3])!])!
    let scans = [Float(-1), 0, 2].enumerated().map { sim.scan(scene: landscapeScene, ev: $1, framing: .tight, brightness: $0 == 1 ? 0.5 : 0.85, seed: UInt64($0 + 1)) }
    var roll = RollSettings()
    let proxies = scans.map { AnalysisProxy(raw: $0.0, flat: nil) }
    _ = Processor.measureFilmBase(proxies[0], file: "f0", rect: nil, roll: &roll)
    var settings = scans.map { _ in FrameSettings() }
    for i in scans.indices { Processor.measureAnchors(proxies[i], roll: roll, settings: &settings[i]) }
    Processor.analyzeRoll(&roll, frames: settings)
    print("estimated base \(roll.filmBase!)  true base \(sim.baseValue * 0.85 / sim.open.max())")
    print("estimated path: " + (roll.calibration?.neutral ?? []).map { String(format: "(%.2f %+.3f %+.3f)", $0.x, $0.y, $0.z) }.joined(separator: " "))
    var truth = "true path:      "
    for ev in stride(from: -4.0, through: 5.0, by: 1.0) {
        let v = sim.cameraValue(scene: SIMD3(repeating: 0.184), ev: Float(ev))
        let d = NegativeModel.density(v, base: sim.baseValue)
        truth += String(format: "(%.2f %+.3f %+.3f) ", d.y, d.x - d.y, d.z - d.y)
    }
    print(truth)
    for (i, st) in settings.enumerated() {
        print("frame \(i) path: " + Estimators.framePath(st.stats!).map { String(format: "(%.2f %+.3f %+.3f)", $0.g, $0.dr, $0.db) }.joined(separator: " "))
    }
case "fitcolor":
    // Fits the colour model N (equivalent-density space, neutral-preserving: e' = ē + N(e − ē)) that best brings
    // conversions back to the scene, over every stock, camera and light.
    let scenes = args.dropFirst().compactMap { loadScene(URL(fileURLWithPath: $0), maxSize: 700) }
    var ata = simd_double3x3(), atb = simd_double3x3()
    var samples: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>, simd_double3x3, Double, Double, Double)] = []
    for stock in stocks {
        for cam in Camera.all {
            for light in Light.all {
                guard let sim = ScanSimulator(stock: stock, camera: cam, light: light) else { continue }
                for (si, scene) in scenes.enumerated() {
                    let (raw, rect) = sim.scan(scene: scene, ev: 0, framing: .tight, seed: UInt64(si + 1))
                    var roll = RollSettings()
                    let proxy = AnalysisProxy(raw: raw, flat: nil)
                    guard Processor.measureFilmBase(proxy, file: "f", rect: nil, roll: &roll) else { continue }
                    var fs = FrameSettings()
                    Processor.measureAnchors(proxy, roll: roll, settings: &fs)
                    Processor.analyzeRoll(&roll, frames: [fs])
                    guard let p = try? ConversionParameters.resolve(roll: roll, frame: fs, cameraToRec2020: raw.cameraToRec2020) else { continue }
                    let mi = p.colorMatrix.inverse
                    let X = pow(2, p.curve.exposure)
                    for y in stride(from: 10, to: scene.height - 10, by: 7) {
                        for x in stride(from: 10, to: scene.width - 10, by: 7) {
                            let sv = SIMD3<Double>(scene[x, y])
                            let ys = Double(ToneMath.lum(SIMD3<Float>(sv)))
                            guard ys > 0.01, ys < 0.9 else { continue }
                            let lt = mi * (sv / X)
                            guard all(lt .> 1e-4) else { continue }
                            let cam = SIMD3<Double>(raw.image[x + Int(rect.minX), y + Int(rect.minY)])
                            let e = NegativeModel.equivalentDensity(cam, p)
                            let et = SIMD3<Double>(p.referenceDensity + p.filmGamma * log10(lt.x), p.referenceDensity + p.filmGamma * log10(lt.y),
                                                   p.referenceDensity + p.filmGamma * log10(lt.z))
                            let m = (e.x + e.y + e.z) / 3
                            let a = e - m, b = et - m
                            ata += simd_double3x3(columns: (a * a.x, a * a.y, a * a.z))
                            atb += simd_double3x3(columns: (b * a.x, b * a.y, b * a.z))
                            samples.append((a, b, sv, p.colorMatrix, p.referenceDensity, p.filmGamma, X))
                        }
                    }
                }
            }
        }
        print("  \(stock) done, \(samples.count) samples")
    }
    // (e − ē) always sums to zero, so N is fixed only up to that direction: take the form that also keeps ē.
    let third = SIMD3<Double>(repeating: 1.0 / 3)
    let J = simd_double3x3(columns: (third, third, third))
    let P = matrix_identity_double3x3 - J
    // Applied to e itself: N·e = ē + P·M·(e − ē).
    let N = P * (atb * (ata + simd_double3x3(diagonal: SIMD3(repeating: 1e-6 * ata[0][0]))).inverse) * P + J
    print("N rows:")
    for r in 0..<3 { print(String(format: "  %+.4f %+.4f %+.4f", N[0][r], N[1][r], N[2][r])) }
    // Error before / after (OKLab ×100 against the scene, exposure-matched).
    func err(_ M: simd_double3x3) -> Double {
        var acc = 0.0
        for smp in samples {
            let (a, b, sv, cm, _, g, X) = smp
            _ = b
            let e = M * a
            let l = cm * SIMD3(pow(10, e.x / g), pow(10, e.y / g), pow(10, e.z / g))
            // Compare chroma only (OKLab a, b), normalising lightness to the scene's.
            let lo = ToneMath.oklab(SIMD3<Float>(simd_max(l, .zero))), ls = ToneMath.oklab(SIMD3<Float>(sv / X))
            acc += Double(simd_length(SIMD2(lo.y, lo.z) / max(lo.x, 1e-3) * ls.x - SIMD2(ls.y, ls.z))) * 100
        }
        return acc / Double(samples.count)
    }
    print(String(format: "chroma error: identity %.2f  fitted %.2f", err(matrix_identity_double3x3), err(N)))
case "exposure":
    // One scene, one stock, film exposures −2…+3 EV: each as its own roll, then all as one roll.
    let scene = loadScene(URL(fileURLWithPath: args[1]))!
    let sim = ScanSimulator(stock: args.count > 2 ? args[2] : "fujifilm_c200", camera: Camera.all[0], light: Light.all[0])!
    let evs: [Float] = [-2, -1, 0, 1, 2, 3]
    let scans = evs.map { sim.scan(scene: scene, ev: $0, framing: .tight) }
    for (n, sc) in scans.enumerated() {
        let out = try! convertRoll([sc.0], stage: .sceneLinear)
        let s = score(out[0], scene: scene, picture: sc.1)
        print(String(format: "single  film %+.0f EV: exposure error %+.2f, cast %.1f", evs[n], s.exposure, s.cast))
    }
    let outs = try! convertRoll(scans.map(\.0), stage: .sceneLinear)
    for (n, o) in outs.enumerated() {
        let s = score(o, scene: scene, picture: scans[n].1)
        print(String(format: "roll    film %+.0f EV: exposure error %+.2f, cast %.1f", evs[n], s.exposure, s.cast))
    }
case "scenes":
    // Statistics of each scene as the camera exposed it (log2 relative to middle grey 0.184).
    for f in args.dropFirst() {
        guard let img = loadScene(URL(fileURLWithPath: f)) else { continue }
        var ys: [Double] = [], wsum = 0.0, lsum = 0.0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let v = max(Double(ToneMath.lum(img[x, y])), 1e-4)
                ys.append(v)
                let dx = Double(x) / Double(img.width) - 0.5, dy = Double(y) / Double(img.height) - 0.5
                let w = exp(-(dx * dx + dy * dy) / (2 * 0.35 * 0.35))
                wsum += w; lsum += w * log2(v / 0.184)
            }
        }
        ys.sort()
        func p(_ q: Double) -> Double { log2(ys[Int(Double(ys.count - 1) * q)] / 0.184) }
        print(String(format: "%@  centre-log-avg %+.2f  median %+.2f  p75 %+.2f  p90 %+.2f  p97 %+.2f  p99.5 %+.2f",
                     (f as NSString).lastPathComponent, lsum / wsum, p(0.5), p(0.75), p(0.9), p(0.97), p(0.995)))
    }
case "run":
    var sheet: URL?
    var files = Array(args.dropFirst())
    if let i = files.firstIndex(of: "--sheet"), i + 1 < files.count { sheet = URL(fileURLWithPath: files[i + 1]); files.removeSubrange(i...(i + 1)) }
    do { try run(files.map { URL(fileURLWithPath: $0) }, sheet: sheet) } catch { print("error: \(error)") }
default: print("negatives-bench loci | run <scene photos…> [--sheet out.jpg]")
}
