import CoreGraphics
import Foundation
import simd
import Testing
@testable import PositivesCore

@Suite("Masks", .serialized)
struct MaskTests {
    let engine = try! RenderEngine(context: MetalContext.shared!)

    /// A rotated, cropped edit with four masks of every analytic kind.
    func maskedEdit(_ src: SourceImage) -> EditState {
        var e = EditState.initial(for: src)
        e.geometry.quarterTurns = 1
        e.geometry.crop = CGRect(x: 0.125, y: 0.0625, width: 0.75, height: 0.875)
        e.light.exposure = 0.3
        var lin = MaskComponent(kind: .linear)
        lin.start = MaskPoint(0.1, 0.1); lin.end = MaskPoint(0.7, 0.5)
        var rad = MaskComponent(kind: .radial)
        rad.center = MaskPoint(0.5, 0.35); rad.radiusX = 0.2; rad.radiusY = 0.12; rad.angle = 30; rad.feather = 60
        rad.mode = .subtract
        var a = LocalAdjustment(name: "Sky", components: [lin, rad])
        a.settings.exposure = 1; a.settings.temperature = 40; a.settings.tint = -20; a.settings.contrast = 30
        var lum = MaskComponent(kind: .luminance)
        lum.low = 30; lum.high = 80; lum.smoothness = 15
        var rad2 = MaskComponent(kind: .radial)
        rad2.center = MaskPoint(0.3, 0.4); rad2.radiusX = 0.3; rad2.radiusY = 0.3
        rad2.mode = .intersect
        var b = LocalAdjustment(name: "Mid", components: [lum, rad2])
        b.invert = true
        b.settings.saturation = -60; b.settings.colorAmount = 40; b.settings.colorHue = 200
        b.settings.curve = [CurvePoint(0, 0.05), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        var col = MaskComponent(kind: .color)
        col.hue = 40; col.chroma = 0.1; col.range = 50
        var c = LocalAdjustment(name: "Warm", components: [col])
        c.settings.exposure = -0.7; c.settings.saturation = 30
        var d = LocalAdjustment(name: "Neutral", components: [MaskComponent(kind: .radial)])
        d.settings.grain = 50
        e.masks = [a, b, c, d]
        return e
    }

    @Test("GPU masks match the CPU reference (gradients, ranges, colour; rotated and cropped)")
    func gpuMatchesCPU() throws {
        let src = TestFiles.syntheticRaw(width: 96, height: 64)
        try engine.setSource(src)
        let e = maskedEdit(src)
        let full = engine.outputSize(e.geometry)
        let r = try engine.render(e, view: ViewRequest(region: CGRect(origin: .zero, size: full), scale: 1, exact: true))
        let gpu = try PipelineTests().download(r, engine: engine)
        let p = DevelopParameters.resolve(e, source: src)
        #expect(p.locals.count == 4)
        let toSource = e.geometry.outputToSource(sourceWidth: src.image.width, sourceHeight: src.image.height)
        let L = Double(max(src.image.width, src.image.height))
        var worst = 0.0, selected = 0
        for y in 0..<gpu.height {
            for x in 0..<gpu.width {
                let sp = toSource.apply([Double(x) + 0.5, Double(y) + 0.5])
                let native = src.image[Int(sp.x), Int(sp.y)]
                let px = MaskMath.Pixel(sensor: sp / L, lab: Develop.maskLab(native, p))
                let w = p.masks.map { MaskMath.weight($0, px) }
                if w[0] > 0.5 { selected += 1 }
                let cpu = Develop.pixel(native, p, local: LocalValues(base: 0, mid: 0, fine: 0, dark: 0, masks: w))
                for k in 0..<3 {
                    worst = max(worst, abs(OutputColorSpace.sRGB.encode(max(0, Double(gpu[x, y][k]))) - OutputColorSpace.sRGB.encode(max(0, Double(cpu[k])))) * 65535)
                }
            }
        }
        #expect(selected > 100 && selected < gpu.width * gpu.height - 100, "the sky mask selects part of the picture")
        #expect(worst < 6, "worst difference \(worst) of a 16-bit code")
    }

    @Test("A mask without adjustments changes nothing")
    func neutralMaskIsIdentity() throws {
        let src = TestFiles.syntheticRaw()
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        e.light.exposure = 0.4; e.color.saturation = 20
        let a = try engine.renderFull(e)
        e.masks = [LocalAdjustment(name: "Nothing", components: [MaskComponent(kind: .radial), MaskComponent(kind: .linear)])]
        let b = try engine.renderFull(e)
        #expect(a.pixels == b.pixels)
    }

    @Test("Brush strokes paint and erase; preview equals export")
    func brushPaintsAndErases() throws {
        let src = TestFiles.syntheticRaw(width: 200, height: 120)
        try engine.setSource(src)
        var e = EditState.initial(for: src)
        let plain = try engine.renderFull(e)
        var brush = MaskComponent(kind: .brush)
        // A horizontal stroke through the middle (y = 60 px = 0.3 of the long side), radius 10 px.
        brush.strokes = [BrushStroke(points: [MaskPoint(0.1, 0.3), MaskPoint(0.5, 0.3), MaskPoint(0.9, 0.3)], radius: 0.05, feather: 20, flow: 100, erase: false)]
        var m = LocalAdjustment(name: "Brush", components: [brush])
        m.settings.exposure = 1
        e.masks = [m]
        let painted = try engine.renderFull(e)
        func ratio(_ img: LinearImage, _ x: Int, _ y: Int) -> Float { ToneMath.lum(img[x, y]) / max(ToneMath.lum(plain[x, y]), 1e-6) }
        // On the stroke (in the dark half, where +1 EV shows fully): clearly brighter; far from it: unchanged.
        #expect(ratio(painted, 40, 60) > 1.8)
        #expect(ratio(painted, 150, 60) > 1.08)
        #expect(abs(ratio(painted, 40, 10) - 1) < 1e-4)
        // Erase the right half of the stroke.
        e.masks[0].components[0].strokes.append(BrushStroke(points: [MaskPoint(0.6, 0.3), MaskPoint(1.0, 0.3)], radius: 0.08, feather: 0, flow: 100, erase: true))
        let erased = try engine.renderFull(e)
        #expect(abs(ratio(erased, 170, 60) - 1) < 1e-3)
        #expect(ratio(erased, 40, 60) > 1.8)
        // The 100 % preview of a region equals the export there.
        let r = try engine.render(e, view: ViewRequest(region: CGRect(x: 20, y: 30, width: 150, height: 60), scale: 1, exact: true))
        let v = try PipelineTests().download(r, engine: engine)
        var worst: Float = 0
        for y in 0..<v.height { for x in 0..<v.width { worst = max(worst, simd_length(v[x, y] - erased[x + 20, y + 30])) } }
        #expect(worst < 1e-5, "preview differs from export by \(worst)")
    }

    @Test("Masks are saved and read back")
    func codable() throws {
        let src = TestFiles.syntheticRaw()
        let e = maskedEdit(src)
        let back = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(e))
        #expect(back == e)
    }
}
