import CoreGraphics
import Foundation
import simd
import Testing
@testable import PositivesCore

@Suite("Output and presets")
struct OutputTests {
    static func ramp(_ w: Int, _ h: Int) -> LinearImage {
        var img = LinearImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w { img[x, y] = SIMD3(Float(x) / Float(w), Float(y) / Float(h), 0.3) } }
        return img
    }

    @Test("Resampling keeps flat colour exactly and the average brightness, shrinking or enlarging")
    func resample() {
        var flat = LinearImage(width: 90, height: 60)
        for y in 0..<60 { for x in 0..<90 { flat[x, y] = SIMD3(0.18, 0.4, 0.05) } }
        for (w, h) in [(30, 20), (47, 31), (200, 133)] {
            let r = Resample.lanczos3(flat, width: w, height: h)
            #expect(r.width == w && r.height == h)
            for y in 0..<h { for x in 0..<w { #expect(simd_length(r[x, y] - SIMD3(0.18, 0.4, 0.05)) < 1e-5) } }
        }
        let ramp = Self.ramp(120, 80)
        let small = Resample.lanczos3(ramp, width: 40, height: 27)
        func mean(_ i: LinearImage) -> SIMD3<Float> {
            var s = SIMD3<Float>.zero
            for y in 0..<i.height { for x in 0..<i.width { s += i[x, y] } }
            return s / Float(i.width * i.height)
        }
        #expect(simd_length(mean(small) - mean(ramp)) < 0.01)
    }

    @Test("Output sizes: long edge and print size keep the aspect ratio")
    func sizes() {
        var o = OutputSettings()
        #expect(o.pixelSize(width: 6240, height: 4160) == (6240, 4160))
        o.size = .longEdge; o.longEdge = 2048
        #expect(o.pixelSize(width: 6240, height: 4160) == (2048, 1365))
        #expect(o.pixelSize(width: 4160, height: 6240) == (1365, 2048))
        o.size = .print; o.printLongCM = 30; o.dpi = 300
        #expect(o.pixelSize(width: 6240, height: 4160).width == 3543)
    }

    @Test("Sharpening leaves flat areas alone and adds edge contrast without colour fringes")
    func sharpening() {
        var img = LinearImage(width: 40, height: 10)
        for y in 0..<10 { for x in 0..<40 { img[x, y] = x < 20 ? SIMD3(0.05, 0.04, 0.03) : SIMD3(0.5, 0.4, 0.3) } }
        let s = OutputFinish.sharpen(img, sigma: 1, amount: 0.8)
        #expect(simd_length(s[3, 5] - img[3, 5]) < 1e-5)
        #expect(simd_length(s[36, 5] - img[36, 5]) < 1e-5)
        #expect(ToneMath.lum(s[20, 5]) > ToneMath.lum(img[20, 5]))   // bright side of the edge gets brighter
        #expect(ToneMath.lum(s[19, 5]) < ToneMath.lum(img[19, 5]))   // dark side darker
        // Lightness only: the colour ratios stay.
        let a = s[20, 5], b = img[20, 5]
        #expect(abs(a.x / a.y - b.x / b.y) < 1e-4)
    }

    @Test("Output sharpening sharpens the picture but lays the grain back untouched")
    func grainNotSharpened() {
        var clean = LinearImage(width: 40, height: 10)
        for y in 0..<10 { for x in 0..<40 { clean[x, y] = x < 20 ? SIMD3(repeating: 0.1) : SIMD3(repeating: 0.4) } }
        var grainy = clean
        var st: UInt32 = 7
        for y in 0..<10 { for x in 0..<40 {
            st = st &* 1664525 &+ 1013904223
            grainy[x, y] *= 1 + 0.1 * (Float(st >> 8) / Float(1 << 24) - 0.5)
        } }
        var o = OutputSettings(); o.sharpening = .screen; o.strength = 2
        let out = OutputFinish.apply(grainy, o, grainFree: clean)
        let sharpClean = OutputFinish.sharpen(clean, sigma: 0.7, amount: 0.45 * 1.5)
        for y in 0..<10 { for x in 0..<40 {
            let ratio = grainy[x, y] / clean[x, y], got = out[x, y] / sharpClean[x, y]
            #expect(simd_length(ratio - got) < 1e-4, "grain at \(x),\(y) unchanged")
        } }
    }

    @Test("A preset brings its look but keeps the photo's crop, white balance, exposure, masks and layers")
    func presetApply() {
        var photo = EditState()
        photo.geometry = FrameGeometry(quarterTurns: 1, crop: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        photo.whiteBalance = WhiteBalance(temperature: 4800, tint: 3)
        photo.light.exposure = 0.7
        photo.light.contrast = 30
        photo.masks = [LocalAdjustment(name: "M", components: [MaskComponent(kind: .radial)])]
        photo.layers = [PhotoLayer(path: "/a.jpg")]
        let p = PresetStore.builtIn.first { $0.name == "HP5 Red Filter" }!
        let e = photo.applying(p)
        #expect(e.film.stock == "ilford_hp5_plus" && e.film.bwFilter == .red)
        #expect(e.geometry == photo.geometry && e.whiteBalance == photo.whiteBalance && e.light.exposure == 0.7)
        #expect(e.masks == photo.masks && e.layers == photo.layers)
        #expect(e.light.contrast == 10, "the preset's own contrast replaces the photo's")
    }

    @Test("A film preset changes only film, grain, recipe and Color Chrome; an everything preset keeps only the crop")
    func presetScopes() {
        var source = EditState()
        source.film.stock = "kodak_trix_400"; source.film.bwFilter = .yellow; source.grain.amount = 90; source.recipe.shadow = 1
        source.light.contrast = 40; source.whiteBalance = WhiteBalance(temperature: 6000, tint: 0)
        source.geometry.quarterTurns = 3
        var photo = EditState()
        photo.light.contrast = -20; photo.color.saturation = 15; photo.geometry.quarterTurns = 1
        let film = photo.applying(Preset(name: "F", look: source, scope: .film))
        #expect(film.film == source.film && film.grain == source.grain && film.recipe == source.recipe)
        #expect(film.light.contrast == -20 && film.color.saturation == 15 && film.whiteBalance == nil && film.geometry.quarterTurns == 1)
        let all = photo.applying(Preset(name: "A", look: source, scope: .everything))
        #expect(all.light.contrast == 40 && all.whiteBalance == source.whiteBalance && all.geometry.quarterTurns == 1)
    }

    @Test("Built-in presets use films that exist and keep their ids across launches")
    func builtIns() {
        for p in PresetStore.builtIn {
            if let s = p.look.film.stock { #expect(FilmLooks.shared.look(s) != nil, "\(p.name): \(s)") }
            #expect(p.id == PresetStore.stableID(p.name))
        }
        #expect(Set(PresetStore.builtIn.map(\.id)).count == PresetStore.builtIn.count)
    }

    @Test("User presets are saved and read back")
    func store() throws {
        let url = TestFiles.dir.appendingPathComponent("presets-\(UUID().uuidString).json")
        let s = PresetStore(url: url)
        var look = EditState()
        look.film.stock = "kodak_portra_400"; look.geometry.quarterTurns = 1
        let p = s.add(name: "Mine", look: look)
        #expect(p.look.geometry == FrameGeometry(), "presets never carry a crop or rotation")
        let back = PresetStore(url: url)
        #expect(back.user.map(\.name) == ["Mine"] && back.user[0].look.film.stock == "kodak_portra_400")
        back.remove(p.id)
        #expect(PresetStore(url: url).user.isEmpty)
    }

    @Test("Credits name every bundled licence file")
    func credits() {
        for f in Set(Credits.items.compactMap(\.file)) { #expect(Credits.licenceText(f) != nil, "\(f).txt") }
    }
}
