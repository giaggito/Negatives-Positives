import CoreGraphics
import Foundation
import simd
import Testing
import UniformTypeIdentifiers
@testable import PositivesCore

@Suite("Render pipeline", .serialized)
struct PipelineTests {
    let engine = try! RenderEngine(context: MetalContext.shared!)

    /// Edits covering every per-pixel feature (local features need the maps; tested separately).
    static let pointEdits: [(String, (inout EditState) -> Void)] = [
        ("neutral", { _ in }),
        ("exposure", { $0.light.exposure = 1.3 }),
        ("contrast+whites+blacks", { $0.light.contrast = 60; $0.light.whites = -40; $0.light.blacks = 35 }),
        ("white balance", { $0.whiteBalance = WhiteBalance(temperature: 3800, tint: -20) }),
        ("vibrance+saturation", { $0.color.vibrance = 70; $0.color.saturation = -30 }),
        ("flat profile", { $0.profile = .flat; $0.light.exposure = -0.7 }),
        ("linear profile", { $0.profile = .linear }),
        ("master curve", { $0.curves.master = [CurvePoint(0, 0.05), CurvePoint(0.3, 0.22), CurvePoint(0.7, 0.8), CurvePoint(1, 0.97)] }),
        ("RGB curves", { $0.curves.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.58), CurvePoint(1, 1)]; $0.curves.blue = [CurvePoint(0, 0.06), CurvePoint(1, 0.9)] }),
        ("colour mixer", { $0.mixer.hue[0] = 40; $0.mixer.saturation[3] = -60; $0.mixer.luminance[5] = -50; $0.mixer.saturation[1] = 30 }),
        ("targeted colours", { e in
            var t = TargetedColor(hue: 40, chroma: 0.12, lightness: 0.6); t.hueShift = 30; t.saturation = 40; t.luminance = -20
            var u = TargetedColor(hue: 250, chroma: 0.1, lightness: 0.5); u.isolate = 80; u.width = 40
            e.targeted = [t, u]
        }),
        ("colour grading", { e in
            e.grading.shadows.hue = 220; e.grading.shadows.saturation = 40; e.grading.highlights.hue = 60; e.grading.highlights.saturation = 35
            e.grading.midtones.luminance = 20; e.grading.global.hue = 30; e.grading.global.saturation = 10; e.grading.balance = -30
        }),
    ]

    @Test("GPU develop matches the CPU reference", arguments: pointEdits.indices)
    func gpuMatchesCPU(_ i: Int) throws {
        let src = TestFiles.syntheticRaw()
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        Self.pointEdits[i].1(&e)
        let full = engine.outputSize(e.geometry)
        let r = try engine.render(e, view: ViewRequest(region: CGRect(origin: .zero, size: full), scale: 1, exact: true))
        let gpu = try download(r)
        let p = DevelopParameters.resolve(e, source: src)
        var worst = 0.0
        for y in 0..<gpu.height {
            for x in 0..<gpu.width {
                let cpu = Develop.pixel(src.image[x, y], p, local: LocalValues(base: 0, mid: 0, fine: 0, dark: 0))
                let g = gpu[x, y]
                // Compare as 16-bit sRGB codes (the finest output the app writes); out-of-range values relatively.
                for k in 0..<3 {
                    let a = Double(g[k]), b = Double(cpu[k])
                    let err = (b < 0 || b > 1) ? abs(a - b) / max(abs(b), 1) * 65535
                                               : abs(OutputColorSpace.sRGB.encode(a) - OutputColorSpace.sRGB.encode(b)) * 65535
                    worst = max(worst, err)
                }
            }
        }
        // Float32 with the GPU's hardware transcendentals (≈1e-6 relative): within ~1 code of 16-bit output,
        // 256 times finer than an 8-bit step.
        #expect(worst < 1.5, "\(Self.pointEdits[i].0): worst difference \(worst) of a 16-bit code")
    }

    @Test("Identity: an untouched file exports bit-for-bit identical", arguments: [
        ("png8-srgb.png", 8, UTType.png, ExportFormat.png8, OutputColorSpace.sRGB, CGColorSpace.sRGB),
        ("tiff16-srgb.tif", 16, UTType.tiff, ExportFormat.tiff16, OutputColorSpace.sRGB, CGColorSpace.sRGB),
        ("tiff16-prophoto.tif", 16, UTType.tiff, ExportFormat.tiff16, OutputColorSpace.proPhoto, CGColorSpace.rommrgb),
        ("tiff16-adobe.tif", 16, UTType.tiff, ExportFormat.tiff16, OutputColorSpace.adobeRGB, CGColorSpace.adobeRGB1998),
        ("png8-p3.png", 8, UTType.png, ExportFormat.png8, OutputColorSpace.displayP3, CGColorSpace.displayP3),
    ])
    func identity(_ name: String, _ bits: Int, _ type: UTType, _ format: ExportFormat, _ space: OutputColorSpace, _ cs: CFString) throws {
        let input = TestFiles.writeTestImage(name: name, bits: bits, type: type, space: CGColorSpace(name: cs)!)
        let src = try SourceLoader.load(url: input)
        try engine.setSource(src)
        let out = TestFiles.dir.appendingPathComponent("out-" + name)
        try? FileManager.default.removeItem(at: out)
        let img = try engine.renderFull(.initial(for: src))
        try Exporter.write(img, to: out, options: ExportOptions(format: format, space: space, includeMetadata: false), software: "test")
        let a = TestFiles.samples(input), b = TestFiles.samples(out)
        #expect(a.bits == b.bits && a.width == b.width && a.height == b.height)
        if bits == 16 && (space == .proPhoto || space == .adobeRGB) {
            // Pure power-law spaces are infinitely steep at black: a channel within ~100 codes of 0 beside bright
            // ones picks up float32 rounding (~1e-7 of the pixel) through the Rec.2020 working space, which the
            // curve magnifies to up to ~20 codes (3e-4 of full scale, < 1/10 of an 8-bit step). Everything else
            // must be identical.
            var bad = 0
            for (i, (x, y)) in zip(a.values, b.values).enumerated() where x != y {
                let pixel = a.values[(i / 3) * 3..<(i / 3) * 3 + 3]
                if !(abs(x - y) <= 24 && x < 128 && x * 50 < pixel.max()!) { bad += 1 }
            }
            #expect(bad == 0, "\(name): \(bad) samples differ beyond float32 precision at black")
        } else {
            let diffs = zip(a.values, b.values).filter { $0 != $1 }.count
            #expect(diffs == 0, "\(name): \(diffs) of \(a.values.count) samples differ")
        }
    }

    @Test("Preview equals export: the exact preview is the export, area-averaged")
    func previewEqualsExport() throws {
        let src = TestFiles.syntheticRaw(width: 240, height: 160)
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        e.light.exposure = 0.4; e.light.shadows = 40; e.light.highlights = -50
        e.presence.clarity = 45; e.presence.texture = 30; e.presence.dehaze = 20; e.color.vibrance = 25
        let full = try engine.renderFull(e)
        // 100 %: identical pixels.
        let r1 = try engine.render(e, view: ViewRequest(region: CGRect(x: 40, y: 30, width: 120, height: 80), scale: 1, exact: true))
        let a = try download(r1)
        var worst: Float = 0
        for y in 0..<a.height { for x in 0..<a.width { worst = max(worst, simd_length(a[x, y] - full[x + 40, y + 30])) } }
        #expect(worst == 0, "100% view differs from export by \(worst)")
        // 1/3 scale: equals the export's exact area average.
        let s = 1.0 / 3
        let r2 = try engine.render(e, view: ViewRequest(region: CGRect(x: 0, y: 0, width: 240, height: 160), scale: s, exact: true))
        let b = try download(r2)
        worst = 0
        for y in 0..<min(b.height, 160 / 3) {
            for x in 0..<min(b.width, 240 / 3) {
                var acc = SIMD3<Float>.zero
                for dy in 0..<3 { for dx in 0..<3 { acc += full[x * 3 + dx, y * 3 + dy] } }
                worst = max(worst, simd_length(b[x, y] - acc / 9) / max(1e-3, simd_length(acc / 9)))
            }
        }
        #expect(worst < 1e-5, "scaled exact preview differs from the downsampled export by \(worst)")
    }

    @Test("Local adjustments do what they say")
    func localAdjustments() throws {
        let src = TestFiles.syntheticRaw(width: 240, height: 160)
        try engine.setSource(src)
        let base = EditState.initial(for: src)
        let full = engine.outputSize(base.geometry)
        func meanLum(_ e: EditState, dark: Bool) throws -> Float {
            let img = try download(try engine.render(e, view: ViewRequest(region: CGRect(origin: .zero, size: full), scale: 1, exact: true)))
            var s: Float = 0, n: Float = 0
            for y in 0..<img.height { for x in (dark ? 0..<img.width / 2 : img.width / 2..<img.width) { s += ToneMath.lum(img[x, y]); n += 1 } }
            return s / n
        }
        var lifted = base; lifted.light.shadows = 80
        #expect(try meanLum(lifted, dark: true) > meanLum(base, dark: true) * 1.2)
        var recovered = base; recovered.light.highlights = -80
        #expect(try meanLum(recovered, dark: false) < meanLum(base, dark: false))
    }

    func download(_ r: RenderedView, engine: RenderEngine? = nil) throws -> LinearImage {
        // Rendered textures are GPU-only: copy into a shared texture first.
        let ctx = (engine ?? self.engine).context
        let t = try ctx.makeTexture(width: r.texture.width, height: r.texture.height)
        try ctx.run { enc in
            ctx.encodeDownsample(enc, src: r.texture, dst: t)
        }
        return ctx.download(t)
    }
}
