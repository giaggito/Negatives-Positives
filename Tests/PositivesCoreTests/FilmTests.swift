import CoreGraphics
import Foundation
import simd
import Testing
@testable import PositivesCore

@Suite("Film simulation", .serialized)
struct FilmTests {
    let engine = try! RenderEngine(context: MetalContext.shared!)

    @Test("Every stock prints middle grey neutral at 18 %", arguments: FilmLibrary.shared.films.map(\.id))
    func middleGreyIsNeutral(_ id: String) throws {
        var s = FilmSettings(); s.stock = id
        let f = try #require(PreparedFilm.prepare(s))
        let o = f.renderPixel(SIMD3(repeating: 0.184))
        let lab = ToneMath.oklab(o)
        #expect(abs(ToneMath.lum(o) - 0.184) < 0.004, "\(id): middle grey prints at \(ToneMath.lum(o))")
        // Negatives are balanced in printing; slides keep their own colour balance (part of their look).
        let cast = simd_length(SIMD2(lab.y, lab.z))
        #expect(cast < (f.isPositive ? 0.03 : 0.01), "\(id): middle grey has a cast of \(cast)")
        // Monotonic grey ramp over the film's useful range.
        var prev: Float = -1
        for ev in stride(from: -6.0, through: 4.0, by: 0.25) {
            let y = ToneMath.lum(f.renderPixel(SIMD3(repeating: Float(0.184 * pow(2, ev)))))
            #expect(y >= prev - 1e-4, "\(id): grey ramp reverses at \(ev) EV")
            prev = y
        }
    }

    @Test("GPU film path matches the CPU reference", arguments: ["kodak_portra_400", "fujifilm_velvia_100", "ilford_hp5_plus", "kodak_vision3_500t"])
    func gpuMatchesCPU(_ id: String) throws {
        let src = TestFiles.syntheticRaw()
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        e.film.stock = id
        e.film.halation = 0
        e.grain.softness = 0
        let full = engine.outputSize(e.geometry)
        let r = try engine.render(e, view: ViewRequest(region: CGRect(origin: .zero, size: full), scale: 1, exact: true))
        let gpu = try PipelineTests().download(r, engine: engine)
        let p = DevelopParameters.resolve(e, source: src)
        var worst = 0.0
        for y in 0..<gpu.height {
            for x in 0..<gpu.width {
                let cpu = Develop.pixel(src.image[x, y], p, local: LocalValues(base: 0, mid: 0, fine: 0, dark: 0))
                for k in 0..<3 {
                    let a = Double(gpu[x, y][k]), b = Double(cpu[k])
                    worst = max(worst, abs(OutputColorSpace.sRGB.encode(max(0, a)) - OutputColorSpace.sRGB.encode(max(0, b))) * 65535)
                }
            }
        }
        #expect(worst < 4, "\(id): worst difference \(worst) of a 16-bit code")
    }

    @Test("Grain is deterministic, keeps the mean and grows with density as shot noise does")
    func grainStatistics() throws {
        // A flat grey picture through Portra 400 with grain.
        let w = 256, h = 256
        var img = LinearImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w { img[x, y] = SIMD3(repeating: x < w / 2 ? 0.05 : 0.6) } }
        let src = SourceImage(url: TestFiles.dir.appendingPathComponent("flat.tif"), kind: .raw, image: img,
                              cameraToRec2020: matrix_identity_double3x3, asShotWhiteBalance: .neutral, defaultOrientation: (0, false),
                              baselineExposure: 0, isProxy: false, fullSize: (w, h), bitsPerComponent: 16, cameraDescription: "flat")
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        e.film.stock = "kodak_portra_400"
        e.grain.amount = 100
        e.grain.softness = 0
        let a = try engine.renderFull(e), b = try engine.renderFull(e)
        #expect(a.pixels == b.pixels, "same edit must give the same grain")
        var noGrain = e; noGrain.grain.amount = 0
        let c = try engine.renderFull(noGrain)
        func stats(_ im: LinearImage, _ xs: Range<Int>) -> (Double, Double) {
            var s = 0.0, s2 = 0.0, n = 0.0
            for y in 0..<h { for x in xs { let v = Double(ToneMath.lum(im[x, y])); s += v; s2 += v * v; n += 1 } }
            return (s / n, (s2 / n - (s / n) * (s / n)).squareRoot())
        }
        let (mDark, _) = stats(c, 0..<w / 2), (mLight, _) = stats(c, w / 2..<w)
        let (gDark, sDark) = stats(a, 0..<w / 2), (gLight, sLight) = stats(a, w / 2..<w)
        #expect(abs(gDark - mDark) / mDark < 0.05 && abs(gLight - mLight) / mLight < 0.05, "grain shifts the mean")
        #expect(sDark > 0 && sLight > 0)
        print("grain σ: shadows \(sDark / gDark) relative, highlights \(sLight / gLight) relative")
        var seeded = e; seeded.grain.seed = 2
        let d = try engine.renderFull(seeded)
        #expect(d.pixels != a.pixels, "a new seed gives a new pattern")
    }

    @Test("Preview at 100 % equals the export with film, grain, halation, bloom and vignette")
    func previewEqualsExportWithFilm() throws {
        let src = TestFiles.syntheticRaw(width: 240, height: 160)
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        e.film.stock = "kodak_vision3_500t"
        e.grain.amount = 120
        e.effects.bloom.amount = 40
        e.effects.vignette.amount = -40
        let full = try engine.renderFull(e)
        let r1 = try engine.render(e, view: ViewRequest(region: CGRect(x: 40, y: 30, width: 120, height: 80), scale: 1, exact: true))
        let v = try PipelineTests().download(r1, engine: engine)
        var worst: Float = 0
        for y in 0..<v.height { for x in 0..<v.width { worst = max(worst, simd_length(v[x, y] - full[x + 40, y + 30])) } }
        #expect(worst < 1e-5, "100% view differs from export by \(worst)")
    }
}

@Suite("Film looks")
struct FilmLookTests {
    @Test("Every look and lab variant has its table, and greys stay in order through it")
    func tablesLoadAndRampsAreMonotonic() throws {
        let pr = try #require(ToneMath.printCurve(for: .standard)).resolved
        for l in FilmLooks.shared.looks where !l.isSpectral {
            for v in l.availableVariants {
                let t = try #require(FilmLooks.shared.table(l, variant: v), "\(l.id) variant \(v) has no table")
                #expect(t.size == FilmLooks.tableSize)
                let r = LookRender(key: l.id, table: t, grainCurve: 0)
                var prev: Float = -1
                for ev in stride(from: -7.0, through: 5.0, by: 0.25) {
                    let o = r.apply(SIMD3(repeating: ToneMath.printCurve(Float(0.184 * pow(2, ev)), pr)))
                    let y = ToneMath.lum(o)
                    #expect(y >= prev - 2e-3, "\(l.id) \(v): grey ramp reverses at \(ev) EV")
                    prev = y
                    if l.isBlackAndWhite {
                        let lab = ToneMath.oklab(o)
                        #expect(simd_length(SIMD2(lab.y, lab.z)) < 0.004, "\(l.id): black & white look has colour")
                    }
                }
            }
        }
    }

    @Test("The stored tables reproduce the source tables (12-bit, predictive coding round trip)")
    func encodingRoundTrip() throws {
        let n = 9
        var values: [SIMD4<Float>] = []
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let c = SIMD3<Float>(Float(i), Float(j), Float(k)) / Float(n - 1)
            values.append(SIMD4(simd_clamp(c * c * 0.9 + 0.05 * SIMD3(c.y, c.z, c.x), .zero, .one), 1))
        } } }
        let data = FilmLooks.encode([("test", FilmLooks.Table(size: n, values: values))])
        let back = try #require(FilmLooks.decode(data)["test"])
        for (a, b) in zip(values, back.values) { #expect(simd_reduce_max(simd_abs(a - b)) <= 0.5 / 4095 + 1e-6) }
    }

    @Test("GPU matches the CPU reference through film looks and Color Chrome",
          arguments: ["kodak_portra_400", "kodak_kodachrome_64", "kodak_trix_400", "polaroid_690"])
    func gpuMatchesCPU(_ id: String) throws {
        let engine = try RenderEngine(context: MetalContext.shared!)
        let src = TestFiles.syntheticRaw()
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        e.film.stock = id
        e.film.halation = 0
        e.film.warmth = 30
        e.grain.softness = 0
        e.color.colorChrome = 100
        e.color.colorChromeBlue = 50
        let full = engine.outputSize(e.geometry)
        let r = try engine.render(e, view: ViewRequest(region: CGRect(origin: .zero, size: full), scale: 1, exact: true))
        let gpu = try PipelineTests().download(r, engine: engine)
        let p = DevelopParameters.resolve(e, source: src)
        #expect(p.look != nil)
        var worst = 0.0
        for y in 0..<gpu.height {
            for x in 0..<gpu.width {
                let cpu = Develop.pixel(src.image[x, y], p, local: LocalValues(base: 0, mid: 0, fine: 0, dark: 0))
                for k in 0..<3 {
                    worst = max(worst, abs(OutputColorSpace.sRGB.encode(max(0, Double(gpu[x, y][k]))) - OutputColorSpace.sRGB.encode(max(0, Double(cpu[k])))) * 65535)
                }
            }
        }
        #expect(worst < 6, "\(id): worst difference \(worst) of a 16-bit code")
    }

    @Test("Color Chrome deepens saturated colours and blues, leaves greys alone")
    func colorChrome() {
        let grey = ToneMath.oklab(SIMD3(repeating: 0.2))
        #expect(simd_length(ColorMath.colorChrome(grey, 1, 1) - grey) < 1e-6)
        let red = ToneMath.oklab(SIMD3(0.6, 0.05, 0.03))
        let r2 = ColorMath.colorChrome(red, 1, 0)
        #expect(r2.x < red.x * 0.95 && r2.x > red.x * 0.8)
        #expect(simd_length(SIMD2(r2.y, r2.z)) > simd_length(SIMD2(red.y, red.z)))
        let sky = ToneMath.oklab(SIMD3(0.12, 0.3, 0.75))
        #expect(ColorMath.colorChrome(sky, 0, 1).x < sky.x * 0.95)
        #expect(abs(ColorMath.colorChrome(red, 0, 1).x - red.x) < 0.01, "Blue only touches blues")
    }

    @Test("Edits saved before film looks and Color Chrome existed still open")
    func oldEditsDecode() throws {
        let json = #"{"formatVersion":2,"color":{"vibrance":12,"saturation":-5},"film":{"stock":"kodak_portra_400","intensity":80},"grain":{"amount":100}}"#
        let e = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(e.color.vibrance == 12 && e.color.colorChrome == 0 && e.film.variant == 0 && e.film.intensity == 80)
        #expect(FilmLooks.shared.look("kodak_portra_800_push1")?.id == "kodak_portra_800")
    }
}

@Suite("Archive")
struct ArchiveTests {
    @Test("Saving, finding, updating and removing photos in the archive")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("archive-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("photo.jpg")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: photo)
        let a = Archive(directory: dir.appendingPathComponent("Archive"))
        var e = EditState()
        e.light.exposure = 0.5
        e.film.stock = "kodak_gold_200"
        let first = try a.save(e, for: photo, thumbnail: nil)
        #expect(a.entry(for: photo)?.edit == e)
        e.light.exposure = 1
        let second = try a.save(e, for: photo, thumbnail: nil)
        #expect(second.id == first.id && a.entries.count == 1)
        // A fresh instance reads the same archive back.
        let b = Archive(directory: dir.appendingPathComponent("Archive"))
        #expect(b.entry(for: photo)?.edit.light.exposure == 1)
        #expect(b.resolve(b.entries[0]) == photo.standardizedFileURL)
        b.remove(first.id)
        #expect(b.entries.isEmpty && Archive(directory: dir.appendingPathComponent("Archive")).entries.isEmpty)
    }
}

@Suite("Recipe and filters")
struct RecipeTests {
    @Test("GPU matches the CPU reference with a full recipe and a black & white filter", arguments: [("kodak_trix_400", BWFilter.red), ("fujifilm_pro_400h", BWFilter.none), ("", BWFilter.none)])
    func gpuMatchesCPU(_ id: String, _ filter: BWFilter) throws {
        let engine = try RenderEngine(context: MetalContext.shared!)
        let src = TestFiles.syntheticRaw()
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        e.film.stock = id.isEmpty ? nil : id
        e.film.halation = 0
        e.film.bwFilter = filter
        e.grain.softness = 0
        e.recipe.dynamicRange = 400; e.recipe.highlight = 2.5; e.recipe.shadow = -1.5; e.recipe.color = 2
        e.recipe.redShift = 3; e.recipe.blueShift = -4
        e.color.colorChrome = 100; e.color.colorChromeBlue = 50
        let full = engine.outputSize(e.geometry)
        let r = try engine.render(e, view: ViewRequest(region: CGRect(origin: .zero, size: full), scale: 1, exact: true))
        let gpu = try PipelineTests().download(r, engine: engine)
        let p = DevelopParameters.resolve(e, source: src)
        var worst = 0.0
        for y in 0..<gpu.height {
            for x in 0..<gpu.width {
                let cpu = Develop.pixel(src.image[x, y], p, local: LocalValues(base: 0, mid: 0, fine: 0, dark: 0))
                for k in 0..<3 {
                    worst = max(worst, abs(OutputColorSpace.sRGB.encode(max(0, Double(gpu[x, y][k]))) - OutputColorSpace.sRGB.encode(max(0, Double(cpu[k])))) * 65535)
                }
            }
        }
        #expect(worst < 6, "\(id) \(filter): worst difference \(worst) of a 16-bit code")
    }

    @Test("Highlight / shadow tone and dynamic range keep black, middle and white; filters keep grey")
    func toneShapes() {
        for h: Float in [-2, 4] {
            #expect(ToneMath.recipeTone(0.5, highlight: h, shadow: h) == 0.5)
            #expect(ToneMath.recipeTone(1, highlight: h, shadow: h) == 1)
            #expect(ToneMath.recipeTone(0, highlight: h, shadow: h) == 0)
        }
        #expect(ToneMath.recipeTone(0.75, highlight: 4, shadow: 0) > 0.75)
        #expect(ToneMath.recipeTone(0.25, highlight: 0, shadow: 4) < 0.25)
        #expect(abs(ToneMath.dynamicRange(0.184, 0.65) - 1) < 0.003, "middle grey untouched")
        #expect(ToneMath.dynamicRange(0.184 * 32, 0.65) < 0.3, "highlights pulled down")
        for f in BWFilter.allCases {
            let g = f.matrix * SIMD3<Float>(repeating: 0.18)
            #expect(abs(ToneMath.lum(g) - 0.18) < 1e-4, "\(f): grey keeps its luminance")
        }
        let sky = SIMD3<Float>(0.04, 0.16, 0.85)
        #expect(ToneMath.lum(BWFilter.red.matrix * sky) < 0.3 * ToneMath.lum(sky), "a red filter darkens a deep blue sky by ~2 stops")
        #expect(ToneMath.lum(BWFilter.blue.matrix * sky) > ToneMath.lum(sky))
    }
}

@Suite("Organic grain", .serialized)
struct OrganicGrainTests {
    @Test("Boolean grain: the 100 % preview equals the export, and the same edit gives the same grains")
    func previewEqualsExport() throws {
        let engine = try RenderEngine(context: MetalContext.shared!)
        // 4000 px across a 35 mm frame = 9 µm per pixel: grains (~6 µm) are drawn individually.
        let src = TestFiles.syntheticRaw(width: 4000, height: 2667)
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        e.film.stock = "kodak_portra_400"
        e.grain.amount = 100
        e.film.halation = 0
        let p = DevelopParameters.resolve(e, source: src)
        #expect(p.grain!.field(renderPixelMicrons: engine.micronsPerPixel(p)).boolean)
        let full = try engine.renderFull(e)
        let region = CGRect(x: 1200, y: 900, width: 300, height: 200)
        let r = try engine.render(e, view: ViewRequest(region: region, scale: 1, exact: true))
        let v = try PipelineTests().download(r, engine: engine)
        // The view's outer pixels see blurs (film softness) clamped at its edge; the app always renders a
        // margin around what is shown, so compare inside it.
        var worst: Float = 0, edge: Float = 0
        for y in 0..<v.height {
            for x in 0..<v.width {
                let d = simd_length(v[x, y] - full[x + 1200, y + 900])
                if x >= 8, y >= 8, x < v.width - 8, y < v.height - 8 { worst = max(worst, d) } else { edge = max(edge, d) }
            }
        }
        print("grain preview vs export: inside \(worst), edge \(edge)")
        #expect(worst < 1e-5, "preview differs from export by \(worst)")
        let again = try engine.renderFull(e)
        #expect(again.pixels == full.pixels)
    }
}
