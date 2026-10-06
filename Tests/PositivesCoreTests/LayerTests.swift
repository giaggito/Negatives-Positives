import CoreGraphics
import Foundation
import simd
import Testing
@testable import PositivesCore

@Suite("Layers", .serialized)
struct LayerTests {
    let engine = try! RenderEngine(context: MetalContext.shared!)

    /// A second "camera file": smooth colour ramps, its own white balance and baseline.
    static func layerSource(width: Int = 96, height: Int = 64, orientation: Int = 0) -> SourceImage {
        var img = LinearImage(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(width - 1), v = Float(y) / Float(height - 1)
                img[x, y] = SIMD3(0.02 + 1.4 * u, 0.05 + 0.9 * v, 0.6 * (1 - u) + 0.3 * v)
            }
        }
        let cam = simd_double3x3(rows: [SIMD3(1.6, -0.5, -0.1), SIMD3(-0.2, 1.45, -0.25), SIMD3(0.03, -0.4, 1.37)])
        return SourceImage(url: TestFiles.dir.appendingPathComponent("layer-\(width)x\(height)-\(orientation).raf"), kind: .raw, image: img,
                           cameraToRec2020: ColorScience.sRGBToRec2020 * cam, asShotWhiteBalance: WhiteBalance(temperature: 6100, tint: -3),
                           defaultOrientation: (orientation, false), baselineExposure: 0.2, isProxy: false, fullSize: (width, height),
                           bitsPerComponent: 14, cameraDescription: "Synthetic layer")
    }

    /// The photo with the layer composited on the CPU (LayerMath), as a plain source.
    static func cpuComposite(_ base: SourceImage, _ layerSrc: SourceImage, _ l: PhotoLayer) -> SourceImage {
        let ref = simd_float3x3(base.inputMatrix(whiteBalance: nil)), inv = ref.inverse
        let lm = LayerMath.colourMatrix(l, layerSource: layerSrc, photoBaseline: base.baselineExposure)
        let d = Float(pow(2, base.baselineExposure))
        var img = base.image
        for y in 0..<img.height {
            for x in 0..<img.width {
                let r = LayerMath.blend(ref * base.image[x, y], lm * layerSrc.image[x, y], k: Float(l.amount / 100), mode: l.blend.code, display: d)
                img[x, y] = inv * r
            }
        }
        return SourceImage(url: TestFiles.dir.appendingPathComponent("composite.raf"), kind: base.kind, image: img, cameraToRec2020: base.cameraToRec2020,
                           asShotWhiteBalance: base.asShotWhiteBalance, defaultOrientation: base.defaultOrientation,
                           baselineExposure: base.baselineExposure, isProxy: false, fullSize: base.fullSize,
                           bitsPerComponent: base.bitsPerComponent, cameraDescription: base.cameraDescription)
    }

    @Test("GPU composite matches the CPU reference in every blend mode", arguments: PhotoLayer.Blend.allCases)
    func gpuMatchesCPU(_ blend: PhotoLayer.Blend) throws {
        let base = TestFiles.syntheticRaw(width: 96, height: 64)
        let layerSrc = Self.layerSource()
        var e = EditState.initial(for: base)
        e.light.exposure = 0.2
        var l = LayerMath.place(PhotoLayer(path: layerSrc.url.path), frame: LayerMath.Frame(layerSrc),
                                photoSensor: (96, 64), geometry: e.geometry)
        l.blend = blend; l.amount = 80; l.exposure = -0.4; l.temperature = 30
        e.layers = [l]
        try engine.setSource(base)
        try engine.setLayerSource(layerSrc)
        let gpu = try engine.renderFull(e)

        let comp = Self.cpuComposite(base, layerSrc, l)
        var plain = e
        plain.layers = []
        try engine.setSource(comp)
        let cpu = try engine.renderFull(plain)
        var worst: Float = 0
        for i in 0..<(gpu.width * gpu.height) {
            for k in 0..<3 {
                let a = OutputColorSpace.sRGB.encode(max(0, Double(gpu.pixels[i * 4 + k]))), b = OutputColorSpace.sRGB.encode(max(0, Double(cpu.pixels[i * 4 + k])))
                worst = max(worst, Float(abs(a - b)) * 65535)
            }
        }
        #expect(worst < 8, "\(blend.rawValue): worst difference \(worst) of a 16-bit code")
    }

    @Test("A layer at zero amount, or hidden, changes nothing")
    func neutralLayer() throws {
        let base = TestFiles.syntheticRaw(width: 96, height: 64)
        let layerSrc = Self.layerSource()
        try engine.setSource(base)
        try engine.setLayerSource(layerSrc)
        var e = EditState.initial(for: base)
        e.light.exposure = 0.3
        let a = try engine.renderFull(e)
        var l = PhotoLayer(path: layerSrc.url.path)
        l.amount = 0
        e.layers = [l]
        #expect(try engine.renderFull(e).pixels == a.pixels)
        e.layers[0].amount = 100; e.layers[0].enabled = false
        #expect(try engine.renderFull(e).pixels == a.pixels)
        e.layers[0].enabled = true
        #expect(try engine.renderFull(e).pixels != a.pixels)
    }

    @Test("Masked layer shows only inside its mask")
    func maskedLayer() throws {
        let base = TestFiles.syntheticRaw(width: 96, height: 64)
        let layerSrc = Self.layerSource()
        try engine.setSource(base)
        try engine.setLayerSource(layerSrc)
        var e = EditState.initial(for: base)
        let plain = try engine.renderFull(e)
        var l = LayerMath.place(PhotoLayer(path: layerSrc.url.path), frame: LayerMath.Frame(layerSrc), photoSensor: (96, 64), geometry: e.geometry)
        l.blend = .normal
        var r = MaskComponent(kind: .radial)
        r.center = MaskPoint(0.25, 0.33); r.radiusX = 0.12; r.radiusY = 0.12; r.feather = 10
        l.mask.components = [r]
        e.layers = [l]
        let masked = try engine.renderFull(e)
        e.layers[0].mask.components = []
        let everywhere = try engine.renderFull(e)
        func px(_ img: LinearImage, _ x: Int, _ y: Int) -> SIMD3<Float> { img[x, y] }
        // Inside the circle (centre 24, 32 — positions are fractions of the long side): the layer; far outside: the photo.
        #expect(simd_length(px(masked, 24, 32) - px(everywhere, 24, 32)) < 0.01)
        #expect(simd_length(px(masked, 80, 50) - px(plain, 80, 50)) < 1e-4)
        #expect(simd_length(px(masked, 80, 50) - px(everywhere, 80, 50)) > 0.01)
    }

    @Test("Placement fills the frame upright for every orientation, crop and straightening")
    func placement() {
        let sensor = (6000, 4000)
        let layer = LayerMath.Frame(fullWidth: 3000, fullHeight: 4500, orientation: FrameGeometry(quarterTurns: 1))
        let geometries = [FrameGeometry(), FrameGeometry(quarterTurns: 1), FrameGeometry(quarterTurns: 3, flipHorizontal: true),
                          FrameGeometry(quarterTurns: 2, straighten: 7, crop: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)),
                          FrameGeometry(flipVertical: true, straighten: -12)]
        for g in geometries {
            for fill in [true, false] {
                let l = LayerMath.place(PhotoLayer(path: "/x.jpg"), frame: layer, photoSensor: sensor, geometry: g, fill: fill)
                let out = g.outputSize(sourceWidth: sensor.0, sourceHeight: sensor.1)
                let a = LayerMath.sensorToLayerUV(l, frame: layer, photoSensor: sensor)
                    .concatenating(g.outputToSource(sourceWidth: sensor.0, sourceHeight: sensor.1))
                let c = a.apply([Double(out.width) / 2, Double(out.height) / 2])
                #expect(abs(c.x - 0.5) < 1e-9 && abs(c.y - 0.5) < 1e-9, "\(g) centre → \(c)")
                // Upright: moving right / down on screen moves right / down in the layer's upright picture.
                let up = layer.orientation.outputToSource(sourceWidth: layer.fullWidth, sourceHeight: layer.fullHeight).inverse
                    .concatenating(Affine2D(m: simd_double2x2(diagonal: [Double(layer.fullWidth), Double(layer.fullHeight)]), t: .zero))
                    .concatenating(a)
                #expect(up.m.columns.0.x > 0 && abs(up.m.columns.0.y) < 1e-9 && up.m.columns.1.y > 0 && abs(up.m.columns.1.x) < 1e-9, "\(g): \(up.m)")
                #expect(abs(LayerMath.screenAngle(l, geometry: g, photoSensor: sensor)) < 1e-9)
                #expect(!LayerMath.screenFlip(l, geometry: g, photoSensor: sensor))
                // Fill covers every corner of the frame; fit touches two opposite edges and stays inside.
                let corners = [(0.0, 0.0), (Double(out.width), 0), (0, Double(out.height)), (Double(out.width), Double(out.height))].map { a.apply([$0.0, $0.1]) }
                if fill {
                    #expect(corners.allSatisfy { $0.x > -1e-6 && $0.x < 1 + 1e-6 && $0.y > -1e-6 && $0.y < 1 + 1e-6 }, "\(g) fill")
                } else {
                    let ai = a.inverse
                    let inside = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)].map { ai.apply([$0.0, $0.1]) }
                    #expect(inside.allSatisfy { $0.x > -1e-6 && $0.x < Double(out.width) + 1e-6 && $0.y > -1e-6 && $0.y < Double(out.height) + 1e-6 }, "\(g) fit")
                }
            }
        }
        // Screen rotation round-trips.
        let g = FrameGeometry(quarterTurns: 3, flipHorizontal: true, straighten: 5)
        var l = LayerMath.place(PhotoLayer(path: "/x.jpg"), frame: layer, photoSensor: sensor, geometry: g)
        l.angle = LayerMath.sensorAngle(screen: 25, geometry: g, photoSensor: sensor)
        #expect(abs(LayerMath.screenAngle(l, geometry: g, photoSensor: sensor) - 25) < 1e-9)
    }

    @Test("Layers survive an archive round trip")
    func codable() throws {
        var e = EditState()
        var l = PhotoLayer(path: "/photos/a.raf")
        l.blend = .screen; l.amount = 60; l.center = MaskPoint(0.3, 0.2); l.size = 0.8; l.angle = 12; l.flip = true
        l.mask.components = [MaskComponent(kind: .sky)]
        e.layers = [l]
        let back = try JSONDecoder().decode(EditState.self, from: try JSONEncoder().encode(e))
        #expect(back.layers == e.layers)
        #expect(try JSONDecoder().decode(EditState.self, from: Data("{}".utf8)).layers.isEmpty)
    }
}
