import CoreGraphics
import Foundation
import ImageIO
import NegativesCore
import simd

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
negatives-cli — convert film-negative RAW scans to positives

USAGE
  negatives-cli convert <RAW / TIFF / JPEG files or folders…> [options]
  negatives-cli info <file>
  negatives-cli demo <positive JPEG> [out dir]   (simulate a negative from a photo and convert it back)

Several files (or a folder) are treated as one roll: the film base is measured once and the
colour calibration is pooled across all frames.

FILM BASE / CALIBRATION
  --base x,y,w,h        Rebate rectangle (normalised 0…1, sensor coordinates) for the film base.
                        Omit for automatic estimation.
  --base-frame FILE     Frame to measure the film base on (default: first frame).
  --flat FILE           Bare light-panel shot for flat-field correction.
  --bw                  Black & white film / mode.
  --gamma G             Average film gamma (default 0.6).

FRAME
  --rotate N            Quarter turns clockwise (0–3).      --flip-h / --flip-v
  --straighten DEG      Fine rotation in degrees.            --crop x,y,w,h (normalised)

LOOK
  --exposure EV  --contrast C  --toe S  --shoulder S  --black DMAX
  --temp K  --tint T    Positive white balance (default 6504 / 0 = neutral).
  --no-auto-exposure    Keep the roll's exposure relationships exactly.

OUTPUT
  --out DIR             Default: <roll folder>/Positives
  --format tiff16|tiff32|jpeg   (default tiff16)
  --space srgb|p3|adobe|prophoto|rec2020   (default prophoto for TIFF, srgb for JPEG)
  --scene               Write scene-linear data (before the print curve); implies tiff32.
  --fast                1-pass demosaic (faster, slightly less fine detail).
  --save                Write JSON sidecars (Roll.negatives.json, <frame>.negatives.json).
  --audit               Print per-stage precision/range audit.
"""

struct Options {
    var inputs: [URL] = []
    var baseRect: CGRect?
    var baseFrame: URL?
    var flat: URL?
    var bw = false
    var gamma: Double?
    var geometry = FrameGeometry()
    var exposure: Double?
    var contrast: Double?
    var toe: Double?
    var shoulder: Double?
    var black: Double?
    var temp: Double?
    var tint: Double?
    var autoExposure = true
    var out: URL?
    var format = ExportFormat.tiff16
    var space: OutputColorSpace?
    var scene = false
    var fast = false
    var save = false
    var audit = false
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func parseRect(_ s: String) -> CGRect {
    let v = s.split(separator: ",").compactMap { Double($0) }
    guard v.count == 4 else { fail("Expected x,y,w,h but got \(s)") }
    return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    func next() -> String {
        i += 1
        guard i < args.count else { fail("Missing value for \(args[i - 1])") }
        return args[i]
    }
    func num() -> Double {
        let s = next()
        guard let d = Double(s) else { fail("Not a number: \(s)") }
        return d
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--base": o.baseRect = parseRect(next())
        case "--base-frame": o.baseFrame = URL(fileURLWithPath: next())
        case "--flat": o.flat = URL(fileURLWithPath: next())
        case "--bw": o.bw = true
        case "--gamma": o.gamma = num()
        case "--rotate": o.geometry.quarterTurns = Int(num())
        case "--flip-h": o.geometry.flipHorizontal = true
        case "--flip-v": o.geometry.flipVertical = true
        case "--straighten": o.geometry.straighten = num()
        case "--crop": o.geometry.crop = parseRect(next())
        case "--exposure": o.exposure = num()
        case "--contrast": o.contrast = num()
        case "--toe": o.toe = num()
        case "--shoulder": o.shoulder = num()
        case "--black": o.black = num()
        case "--temp": o.temp = num()
        case "--tint": o.tint = num()
        case "--no-auto-exposure": o.autoExposure = false
        case "--out": o.out = URL(fileURLWithPath: next())
        case "--format":
            guard let f = ExportFormat(rawValue: next()) else { fail("Unknown format") }
            o.format = f
        case "--space":
            let s = next().lowercased()
            let map: [String: OutputColorSpace] = ["srgb": .sRGB, "p3": .displayP3, "adobe": .adobeRGB, "prophoto": .proPhoto, "rec2020": .rec2020]
            guard let sp = map[s] else { fail("Unknown colour space \(s)") }
            o.space = sp
        case "--scene": o.scene = true
        case "--fast": o.fast = true
        case "--save": o.save = true
        case "--audit": o.audit = true
        default:
            if a.hasPrefix("--") { fail("Unknown option \(a)\n\n\(usage)") }
            o.inputs.append(URL(fileURLWithPath: a))
        }
        i += 1
    }
    return o
}

func rawFiles(_ inputs: [URL]) -> [URL] {
    for u in inputs where !FileManager.default.fileExists(atPath: u.path) { fail("Not found: \(u.path)") }
    return ScanFiles.collect(inputs)
}

func fmt(_ v: SIMD3<Double>, _ p: Int = 4) -> String {
    "(" + [v.x, v.y, v.z].map { String(format: "%.\(p)f", $0) }.joined(separator: ", ") + ")"
}

func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let t = Date()
    let r = try body()
    print(String(format: "  %@ %.2fs", label, Date().timeIntervalSince(t)))
    return r
}

// MARK: - Commands

func info(_ url: URL) throws {
    let raw = try RawDecoder.decodeAny(url: url, quality: .half)
    print("\(url.lastPathComponent): \(raw.cameraMake) \(raw.cameraModel)  \(raw.image.width * 2)×\(raw.image.height * 2)  ISO \(Int(raw.isoSpeed))  1/\(Int((1 / max(raw.shutter, 1e-6)).rounded()))s")
    print("  fixed multipliers \(fmt(raw.multipliers))   clip levels \(fmt(raw.clipLevel))")
    print("  camera → linear sRGB matrix rows:")
    for r in 0..<3 { print("    " + fmt(SIMD3(raw.cameraToSRGB[0][r], raw.cameraToSRGB[1][r], raw.cameraToSRGB[2][r]))) }
    let proxy = AnalysisProxy(image: raw.image.downsampled(by: 2), sourceWidth: raw.image.width * 2, sourceHeight: raw.image.height * 2,
                              clipLevel: raw.clipLevel, flat: nil)
    for mono in [false, true] {
        var roll = RollSettings()
        roll.monochrome = mono
        if Processor.measureFilmBase(proxy, file: url.lastPathComponent, rect: nil, roll: &roll), let b = roll.filmBase {
            print("  auto film base (\(mono ? "B&W" : "colour")): \(fmt(b))  clipped tiles \(String(format: "%.1f%%", (roll.filmBaseClipped ?? 0) * 100))")
        }
    }
    let px = raw.image.pixels
    var mx = SIMD3<Float>(repeating: 0)
    for i in stride(from: 0, to: px.count, by: 4) { mx = simd_max(mx, SIMD3(px[i], px[i + 1], px[i + 2])) }
    print("  brightest pixel \(fmt(SIMD3<Double>(mx)))  (\(any(SIMD3<Double>(mx) .>= raw.clipLevel * 0.98) ? "⚠︎ sensor clipping present" : "no clipping"))")
}

func convert(_ o: Options) throws {
    let files = rawFiles(o.inputs)
    guard !files.isEmpty else { fail("No RAW or image files given") }
    let folder = files[0].deletingLastPathComponent()
    let outDir = o.out ?? folder.appendingPathComponent("Positives")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    print("Roll: \(files.count) frame(s) from \(folder.path)")

    // Flat field
    var flat: FlatField?
    if let f = o.flat {
        flat = try time("flat field \(f.lastPathComponent)") { FlatField(panel: try RawDecoder.decodeAny(url: f, quality: .half)) }
    }
    let processor = try Processor(flat: flat)

    var roll = RollSettings()
    roll.monochrome = o.bw
    if let g = o.gamma { roll.filmGamma = g }
    roll.flatFieldFile = o.flat?.lastPathComponent

    // Pass 1: fast analysis on half-size proxies.
    print("Analysing…")
    var proxies: [URL: AnalysisProxy] = [:]
    for f in files { proxies[f] = try AnalysisProxy.load(f, flat: flat) }
    let baseFile = o.baseFrame ?? files[0]
    let baseProxy = try proxies[baseFile] ?? AnalysisProxy.load(baseFile, flat: flat)
    guard Processor.measureFilmBase(baseProxy, file: baseFile.lastPathComponent, rect: o.baseRect, roll: &roll), let base = roll.filmBase else {
        fail("Could not measure the film base. Use --base x,y,w,h on a rebate area.")
    }
    print("  film base \(fmt(base)) from \(baseFile.lastPathComponent) \(o.baseRect == nil ? "(automatic)" : "(rectangle)")")
    if let c = roll.filmBaseClipped, c > 0.01, o.baseRect != nil {
        print(String(format: "  ⚠︎ %.1f%% of the film-base samples are clipped: the scan is overexposed, lower the camera exposure.", c * 100))
    }

    var settings: [URL: FrameSettings] = [:]
    for f in files {
        var s = FrameSettings()
        s.geometry = o.geometry
        s.autoExposureEnabled = o.autoExposure
        if let v = o.exposure { s.exposure = v }
        if let v = o.contrast { s.curve.contrast = v }
        if let v = o.toe { s.curve.toe = v }
        if let v = o.shoulder { s.curve.shoulder = v }
        if let v = o.black { s.curve.paperDmax = v }
        if let v = o.temp { s.whiteBalance.temperature = v }
        if let v = o.tint { s.whiteBalance.tint = v }
        Processor.measureAnchors(proxies[f]!, roll: roll, settings: &s)
        if let st = s.stats {
            print("  \(f.lastPathComponent): picture \(st.picture.map { String(format: "%.2f,%.2f %.2f×%.2f", $0.minX, $0.minY, $0.width, $0.height) } ?? "whole scan")  average D \(fmt(st.average, 3))  range \(String(format: "%.2f", st.range))")
        } else {
            print("  \(f.lastPathComponent): ⚠︎ not enough image content to measure (check crop / film base)")
        }
        settings[f] = s
    }
    Processor.analyzeRoll(&roll, frames: Array(settings.values))
    if let c = roll.calibration {
        print("  roll calibration: gamma ratio R/G \(String(format: "%.3f", c.gammaRatio.x))  B/G \(String(format: "%.3f", c.gammaRatio.z))   offsets R \(String(format: "%+.3f", c.offset.x))  B \(String(format: "%+.3f", c.offset.z))")
    }
    proxies.removeAll()

    if o.save {
        try Sidecar.save(roll, to: Sidecar.rollURL(in: folder))
        for (f, s) in settings { try Sidecar.save(s, to: Sidecar.frameURL(for: f)) }
        print("  sidecars written")
    }

    // Pass 2: full-resolution render + export.
    let format: ExportFormat = o.scene ? .tiff32 : o.format
    let space = o.space ?? (format == .jpeg ? .sRGB : .proPhoto)
    print("Rendering (\(o.fast ? "1-pass" : "3-pass") demosaic) → \(format.rawValue), \(space.displayName)")
    for f in files {
        let s = settings[f]!
        let frame = try time("decode \(f.lastPathComponent)") { try DecodedFrame.decode(f, quality: o.fast ? .fast : .best) }
        let img = try time("convert") {
            try processor.render(frame, roll: roll, settings: s, stage: o.scene ? .sceneLinear : .positive,
                                 audit: o.audit ? { print("    audit " + $0.description) } : nil)
        }
        let out = outDir.appendingPathComponent(f.deletingPathExtension().lastPathComponent + (o.scene ? "-scene" : "") + "." + format.fileExtension)
        let report = try time("write \(out.lastPathComponent)") { try Exporter.write(img, to: out, format: format, space: space) }
        if report.clippedFraction > 0.0005 {
            print(String(format: "    note: %.2f%% of values were outside %@ and were clipped (use --space prophoto/rec2020 or --format tiff32 to keep them)",
                         report.clippedFraction * 100, space.displayName))
        }
    }
    print("Done → \(outDir.path)")
}

/// Self-check on real image content: turns a positive photo into a simulated colour negative (orange mask,
/// different layer gammas, film toe, rebate border with sprocket holes), converts it back fully
/// automatically, and reports the colour error against the original.
func demo(_ url: URL, outDir: URL) throws {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("Cannot read \(url.path)")
    }
    let w = cg.width / 2, h = cg.height / 2
    var lin = [Float](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    lin.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    let camToSRGB = simd_double3x3(rows: [[1.2384, 0.0315, -0.2699], [-0.1470, 1.5570, -0.4100], [0.0037, -0.3954, 1.3916]])
    let toCamera = camToSRGB.inverse
    var film = SyntheticFilm()
    film.toeWidth = [0.3, 0.35, 0.4]
    film.logEMin = log10(0.18) - 1.9

    let border = h / 12
    let W = w + 2 * border, H = h + 2 * border
    var scan = LinearImage(width: W, height: H, fill: SIMD3<Float>(film.rebate))
    for y in 0..<H where y < border / 2 || y >= H - border / 2 {
        for x in 0..<W where (x / (border / 2)) % 3 == 1 { scan[x, y] = SIMD3<Float>(film.panel) }  // sprocket holes
    }
    var truth = [SIMD3<Double>](repeating: .zero, count: w * h)
    scan.pixels.withUnsafeMutableBufferPointer { dst in
        truth.withUnsafeMutableBufferPointer { tr in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let srgb = SIMD3<Double>(Double(lin[i]), Double(lin[i + 1]), Double(lin[i + 2]))
                    tr[y * w + x] = ColorScience.sRGBToRec2020 * srgb
                    let cam = simd_max(toCamera * srgb, SIMD3(repeating: 1e-5))
                    let v = film.scan(exposure: cam)
                    let o = ((y + border) * W + x + border) * 4
                    dst[o] = Float(v.x); dst[o + 1] = Float(v.y); dst[o + 2] = Float(v.z)
                }
            }
        }
    }
    let raw = RawImage(image: scan, cameraMake: "Simulated", cameraModel: "negative", multipliers: [1, 1, 1], clipLevel: [1, 1, 1],
                       cameraToSRGB: camToSRGB, isoSpeed: 100, shutter: 1)
    let frame = DecodedFrame(url: url, raw: raw)
    let proxy = AnalysisProxy(raw: raw, flat: nil)
    var roll = RollSettings()
    guard Processor.measureFilmBase(proxy, file: url.lastPathComponent, rect: nil, roll: &roll), let base = roll.filmBase else { fail("base") }
    print("  auto film base \(fmt(base))  (true \(fmt(film.rebate)))")
    var settings = FrameSettings()
    settings.geometry.crop = CGRect(x: Double(border) / Double(W), y: Double(border) / Double(H), width: Double(w) / Double(W), height: Double(h) / Double(H))
    Processor.measureAnchors(proxy, roll: roll, settings: &settings)
    Processor.analyzeRoll(&roll, frames: [settings])
    if let c = roll.calibration {
        print(String(format: "  calibration gamma ratios R/G %.3f B/G %.3f (true %.3f %.3f)", c.gammaRatio.x, c.gammaRatio.z,
                     film.gamma.x / film.gamma.y, film.gamma.z / film.gamma.y))
    }
    let processor = try Processor()
    let scene = try processor.render(frame, roll: roll, settings: settings, stage: .sceneLinear)
    let positive = try processor.render(frame, roll: roll, settings: settings)

    // Colour error on scene-linear values, one global exposure scale (median luminance ratio).
    var ratios: [Double] = []
    for i in stride(from: 0, to: w * h, by: 97) where truth[i].y > 0.01 { ratios.append(truth[i].y / Double(scene.pixels[i * 4 + 1])) }
    let k = Statistics.median(ratios)
    var errs: [Double] = []
    for i in stride(from: 0, to: w * h, by: 31) {
        let t = truth[i]
        guard t.min() > 0.002 else { continue }
        let r = SIMD3<Double>(Double(scene.pixels[i * 4]), Double(scene.pixels[i * 4 + 1]), Double(scene.pixels[i * 4 + 2])) * k
        errs.append(Lab.deltaE2000(Lab.lab(rec2020: t), Lab.lab(rec2020: r)))
    }
    errs.sort()
    print(String(format: "  ΔE00 vs original: median %.2f   mean %.2f   95th pct %.2f", Statistics.percentile(sorted: errs, 0.5),
                 errs.reduce(0, +) / Double(errs.count), Statistics.percentile(sorted: errs, 0.95)))

    let name = url.deletingPathExtension().lastPathComponent
    // The simulated negative as a camera would see it (displayed raw, no processing).
    var negView = scan
    for i in stride(from: 0, to: negView.pixels.count, by: 4) {
        let v = SIMD3<Double>(Double(negView.pixels[i]), Double(negView.pixels[i + 1]), Double(negView.pixels[i + 2]))
        let s = ColorScience.sRGBToRec2020 * (camToSRGB * v)
        negView.pixels[i] = Float(s.x); negView.pixels[i + 1] = Float(s.y); negView.pixels[i + 2] = Float(s.z)
    }
    try Exporter.write(negView, to: outDir.appendingPathComponent(name + "-negative.jpg"), format: .jpeg, space: .sRGB)
    try Exporter.write(positive, to: outDir.appendingPathComponent(name + "-positive.jpg"), format: .jpeg, space: .sRGB)
    print("  wrote \(name)-negative.jpg and \(name)-positive.jpg to \(outDir.path)")
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()
do {
    switch cmd {
    case "info":
        guard let f = args.first else { fail("info needs a file") }
        try info(URL(fileURLWithPath: f))
    case "convert":
        try convert(parse(args))
    case "demo":
        guard let f = args.first else { fail("demo needs a JPEG/TIFF positive") }
        let out = args.count > 1 ? URL(fileURLWithPath: args[1]) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try demo(URL(fileURLWithPath: f), outDir: out)
    case "-h", "--help", "help":
        print(usage)
    default:
        fail("Unknown command \(cmd)\n\n\(usage)")
    }
} catch {
    fail("Error: \(error)")
}
