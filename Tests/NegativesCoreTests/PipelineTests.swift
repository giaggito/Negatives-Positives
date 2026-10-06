import CoreGraphics
import Foundation
import ImageIO
import simd
import Testing
@testable import NegativesCore

private func randomParameters(_ rng: inout SystemRandomNumberGenerator, monochrome: Bool = false) -> ConversionParameters {
    var curve = PrintCurve(exposure: .random(in: -2...2, using: &rng), contrast: .random(in: 0.6...2, using: &rng),
                           toe: .random(in: 0...1, using: &rng), shoulder: .random(in: 0...1, using: &rng), paperDmax: .random(in: 1.8...3, using: &rng))
    curve.exposure += 0
    return ConversionParameters(
        filmBase: [.random(in: 0.3...0.8, using: &rng), .random(in: 0.1...0.4, using: &rng), .random(in: 0.05...0.3, using: &rng)],
        calibration: FilmCalibration(gammaRatio: [.random(in: 0.8...1.2, using: &rng), 1, .random(in: 0.9...1.3, using: &rng)],
                                     offset: [.random(in: -0.2...0.2, using: &rng), 0, .random(in: -0.2...0.2, using: &rng)]),
        referenceDensity: .random(in: 0.8...1.6, using: &rng), filmGamma: .random(in: 0.5...0.7, using: &rng),
        monochrome: monochrome, monochromeWeights: [0.25, 0.5, 0.25],
        colorMatrix: WhiteBalance(temperature: .random(in: 3000...9000, using: &rng), tint: .random(in: -30...30, using: &rng)).matrix
            * ColorScience.sRGBToRec2020 * xe4CameraToSRGB,
        curve: curve.resolved)
}

@Suite("GPU pipeline")
struct GPUTests {
    let gpu = GPUPipeline.shared!

    /// The Metal kernel must reproduce the Double reference to float32 accuracy at every stage.
    @Test(arguments: [OutputStage.density, .sceneLinear, .positive], [false, true])
    func kernelMatchesReference(stage: OutputStage, monochrome: Bool) throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5 {
            let p = randomParameters(&rng, monochrome: monochrome)
            var img = LinearImage(width: 64, height: 64)
            for y in 0..<64 { for x in 0..<64 {
                img[x, y] = SIMD3<Float>(SIMD3<Double>(.random(in: 0.0005...1, using: &rng), .random(in: 0.0005...1, using: &rng),
                                                       .random(in: 0.0005...1, using: &rng)) * p.filmBase)
            } }
            let out = gpu.download(try gpu.convert(try gpu.upload(img), parameters: p, stage: stage))
            var worst = 0.0
            for y in 0..<64 { for x in 0..<64 {
                let cam = SIMD3<Double>(img[x, y])
                let ref: SIMD3<Double>
                switch stage {
                case .density: ref = NegativeModel.equivalentDensity(cam, p)
                case .sceneLinear: ref = NegativeModel.sceneLinear(cam, p)
                case .positive, .negative: ref = NegativeModel.positive(cam, p)
                }
                let got = SIMD3<Double>(out[x, y])
                // Absolute for density; for linear light, relative to the pixel's largest component (a colour
                // matrix with negative terms can legitimately make one component a small difference of large ones).
                let err = stage == .density ? (got - ref).maxAbs : (got - ref).maxAbs / max(ref.maxAbs, 1e-3)
                worst = max(worst, err)
            } }
            #expect(worst < 2e-4, "stage \(stage) worst error \(worst)")
        }
    }

    @Test func pixelExactGeometryIsBitExact() throws {
        var img = LinearImage(width: 37, height: 23)
        for y in 0..<23 { for x in 0..<37 { img[x, y] = SIMD3(Float(x) / 37, Float(y) / 23, Float(x * y) / 851 + 0.123456789) } }
        let src = try gpu.upload(img)
        for turns in 0..<4 {
            for flip in [false, true] {
                var g = FrameGeometry(quarterTurns: turns, flipHorizontal: flip)
                g.crop = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.7)
                let out = gpu.download(try gpu.orient(src, geometry: g))
                let map = g.outputToSource(sourceWidth: 37, sourceHeight: 23)
                for y in 0..<out.height { for x in 0..<out.width {
                    let s = map.apply([Double(x) + 0.5, Double(y) + 0.5])
                    let expected = img[Int(s.x), Int(s.y)]
                    #expect(out[x, y] == expected)
                } }
            }
        }
    }

    @Test func straighteningNeverOvershoots() throws {
        // A hard edge: Lanczos alone would ring below the dark side (negative light → bogus density).
        var img = LinearImage(width: 64, height: 64)
        for y in 0..<64 { for x in 0..<64 { img[x, y] = x < 32 ? SIMD3(repeating: 0.001) : SIMD3(repeating: 0.9) } }
        let out = gpu.download(try gpu.orient(try gpu.upload(img), geometry: FrameGeometry(straighten: 3.7)))
        for i in stride(from: 0, to: out.pixels.count, by: 4) {
            #expect(out.pixels[i] >= 0.001 - 1e-6 && out.pixels[i] <= 0.9 + 1e-6)
        }
    }

    @Test func noStageIsQuantised() throws {
        // A smooth gradient through the whole chain must keep many thousands of distinct levels.
        let w = 4096
        var img = LinearImage(width: w, height: 4)
        for x in 0..<w { for y in 0..<4 { img[x, y] = SIMD3(repeating: Float(0.02 + 0.6 * Double(x) / Double(w))) * SIMD3(0.8, 0.4, 0.25) } }
        var roll = RollSettings()
        roll.filmBase = [0.8, 0.4, 0.25]
        let p = try ConversionParameters.resolve(roll: roll, frame: FrameSettings(), cameraToRec2020: ColorScience.sRGBToRec2020 * xe4CameraToSRGB)
        let src = try gpu.upload(img)
        for stage in [OutputStage.density, .sceneLinear, .positive] {
            let out = gpu.download(try gpu.convert(src, parameters: p, stage: stage))
            let audit = StageAudit.audit(out, name: "\(stage)", sampleStride: 1)
            #expect(audit.nonFinite == 0)
            #expect(!audit.looksQuantizedTo8Bit, "\(audit)")
            #expect(audit.distinctLevels > 3000, "\(audit)")
        }
        #expect(gpu.download(src).pixels == img.pixels)  // upload/download is lossless
    }

    /// Preview = export, area-averaged. Compare the GPU preview with a CPU box-filter of the export image.
    @Test func previewMatchesExport() throws {
        let film = SyntheticFilm()
        var img = LinearImage(width: 400, height: 300)
        var rng = SystemRandomNumberGenerator()
        for y in 0..<300 { for x in 0..<400 {
            // Patches plus fine "grain" so that downsample-then-convert would visibly differ.
            let patch = SIMD3<Double>(Double((x / 50) % 4) * 0.2 + 0.05, Double((y / 50) % 3) * 0.25 + 0.05, 0.3)
            let grain = Double.random(in: 0.7...1.3, using: &rng)
            img[x, y] = SIMD3<Float>(film.scan(exposure: patch * grain))
        } }
        let raw = RawImage(image: img, cameraMake: "Test", cameraModel: "Synthetic", multipliers: [1, 1, 1], clipLevel: [1, 1, 1],
                           cameraToSRGB: xe4CameraToSRGB, isoSpeed: 100, shutter: 1)
        let frame = DecodedFrame(url: URL(fileURLWithPath: "/tmp/x"), raw: raw)
        var roll = RollSettings()
        roll.filmBase = film.rebate
        let proc = try Processor()
        let settings = FrameSettings()
        let export = try proc.render(frame, roll: roll, settings: settings)
        let preview = try proc.preview(frame, roll: roll, settings: settings, maxSize: 100)
        #expect(preview.width == 100 && preview.height == 75)
        let cpu = export.downsampled(by: 4)
        var worst: Float = 0
        for i in 0..<cpu.pixels.count { worst = max(worst, abs(cpu.pixels[i] - preview.pixels[i])) }
        #expect(worst < 1e-5, "preview differs from export by \(worst)")
    }
}

@Suite("Export")
struct ExportTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("negatives-tests-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    /// Our analytic encoding must agree with ColorSync using the ICC profile we embed.
    @Test(arguments: OutputColorSpace.allCases)
    func encodingMatchesEmbeddedProfile(space: OutputColorSpace) throws {
        let src = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        var worst = 0.0
        for v in [SIMD3<Double>(0.18, 0.18, 0.18), [0.5, 0.3, 0.2], [0.05, 0.1, 0.2], [0.7, 0.65, 0.6], [0.01, 0.012, 0.009], [0.3, 0.4, 0.1]] {
            let lin = space.fromRec2020 * v
            let ours = SIMD3(space.encode(lin.x), space.encode(lin.y), space.encode(lin.z))
            let c = CGColor(colorSpace: src, components: [v.x, v.y, v.z, 1].map { CGFloat($0) })!
            let conv = try #require(c.converted(to: space.cgColorSpace, intent: .relativeColorimetric, options: nil))
            let cs = conv.components!.map { Double($0) }
            worst = max(worst, (ours - SIMD3(cs[0], cs[1], cs[2])).maxAbs)
        }
        #expect(worst < 2e-3, "\(space.displayName): max difference \(worst)")
    }

    func testImage() -> LinearImage {
        var img = LinearImage(width: 64, height: 32)
        for y in 0..<32 { for x in 0..<64 { img[x, y] = SIMD3(Float(x) / 63 * 0.9 + 0.01, Float(y) / 31 * 0.8 + 0.05, 0.4) } }
        return img
    }

    @Test(arguments: OutputColorSpace.allCases)
    func tiff16RoundTrip(space: OutputColorSpace) throws {
        let url = dir.appendingPathComponent("t16-\(space.rawValue).tif")
        let img = testImage()
        try Exporter.write(img, to: url, format: .tiff16, space: space)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyDepth] as? Int == 16)
        #expect(props[kCGImagePropertyProfileName] != nil, "ICC profile embedded")
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cg.bitsPerComponent == 16)
        let data = cg.dataProvider!.data! as Data
        let m = space.fromRec2020
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt16.self)
            let stride = cg.bytesPerRow / 2
            let comps = cg.bitsPerPixel / 16
            for (x, y) in [(0, 0), (10, 5), (63, 31), (40, 20)] {
                let lin = m * SIMD3<Double>(img[x, y])
                for k in 0..<3 {
                    let expected = UInt16((min(max(space.encode(lin[k]), 0), 1) * 65535).rounded())
                    let got = p[y * stride + x * comps + k]
                    #expect(abs(Int(got) - Int(expected)) <= 1)
                }
            }
        }
    }

    @Test func tiff32IsBitExactAndLinear() throws {
        let url = dir.appendingPathComponent("t32.tif")
        var img = testImage()
        img[3, 3] = [1.7, -0.02, 0.5]  // out-of-range values survive in float output
        try Exporter.write(img, to: url, format: .tiff32, space: .rec2020)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cg.bitsPerComponent == 32)
        #expect(cg.bitmapInfo.contains(.floatComponents))
        let data = cg.dataProvider!.data! as Data
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            let stride = cg.bytesPerRow / 4, comps = cg.bitsPerPixel / 32
            for (x, y) in [(0, 0), (3, 3), (63, 31)] {
                for k in 0..<3 { #expect(p[y * stride + x * comps + k] == img.pixels[(y * 64 + x) * 4 + k]) }
            }
        }
    }

    @Test func jpegHasProfile() throws {
        let url = dir.appendingPathComponent("t.jpg")
        try Exporter.write(testImage(), to: url, format: .jpeg, space: .sRGB)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyProfileName] as? String != nil)
    }
}
