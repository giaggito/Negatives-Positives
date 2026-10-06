import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers
@testable import PositivesCore

enum TestFiles {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("positives-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// A deterministic test picture: gradients, saturated patches and noise, 8 or 16 bit, written with ImageIO
    /// in the given colour space.
    static func writeTestImage(name: String, width: Int = 96, height: Int = 64, bits: Int, type: UTType,
                               space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> URL {
        let url = dir.appendingPathComponent(name)
        var state: UInt32 = 12345
        func rnd() -> Double { state = state &* 1664525 &+ 1013904223; return Double(state >> 8) / Double(1 << 24) }
        let maxV = Double((1 << bits) - 1)
        var vals = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                switch (x / 24, y / 32) {
                case (0, _): vals[i] = Double(x) / 23; vals[i + 1] = Double(y) / 63; vals[i + 2] = 0.5
                case (1, 0): vals[i] = 1; vals[i + 1] = 0.1; vals[i + 2] = 0.05
                case (1, 1): vals[i] = 0.05; vals[i + 1] = 0.3; vals[i + 2] = 1
                default: vals[i] = rnd(); vals[i + 1] = rnd(); vals[i + 2] = rnd()
                }
            }
        }
        let cg: CGImage
        if bits == 8 {
            let px = vals.map { UInt8(($0 * maxV).rounded()) }
            cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                         provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        } else {
            let px = vals.map { UInt16(($0 * maxV).rounded()) }
            cg = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: width * 6, space: space,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                         provider: CGDataProvider(data: px.withUnsafeBytes { Data($0) } as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, nil)
        CGImageDestinationFinalize(d)
        return url
    }

    /// Raw integer samples of an image file (8 or 16 bit, RGB), as stored.
    static func samples(_ url: URL) -> (bits: Int, values: [Int], width: Int, height: Int) {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let data = cg.dataProvider!.data! as Data
        let bpc = cg.bitsPerComponent, bpp = cg.bitsPerPixel / bpc
        var out = [Int]()
        out.reserveCapacity(cg.width * cg.height * 3)
        data.withUnsafeBytes { raw in
            for y in 0..<cg.height {
                for x in 0..<cg.width {
                    for c in 0..<3 {
                        let o = y * cg.bytesPerRow + (x * bpp + c) * bpc / 8
                        out.append(bpc == 16 ? Int(raw.load(fromByteOffset: o, as: UInt16.self)) : Int(raw[o]))
                    }
                }
            }
        }
        return (bpc, out, cg.width, cg.height)
    }

    /// A synthetic RAF-like source: camera RGB with a known matrix.
    static func syntheticRaw(width: Int = 64, height: Int = 48) -> SourceImage {
        var img = LinearImage(width: width, height: height)
        var state: UInt32 = 99
        func rnd() -> Float { state = state &* 1664525 &+ 1013904223; return Float(state >> 8) / Float(1 << 24) }
        for y in 0..<height { for x in 0..<width { img[x, y] = SIMD3(rnd(), rnd(), rnd()) * (x < width / 2 ? 0.03 : 1.6) } }
        // X-E4-like camera matrix (rows sum to 1).
        let cam = simd_double3x3(rows: [SIMD3(1.69, -0.62, -0.07), SIMD3(-0.18, 1.51, -0.33), SIMD3(0.02, -0.46, 1.44)])
        return SourceImage(url: dir.appendingPathComponent("synthetic.raf"), kind: .raw, image: img,
                           cameraToRec2020: ColorScience.sRGBToRec2020 * cam, asShotWhiteBalance: WhiteBalance(temperature: 5200, tint: 4),
                           defaultOrientation: (0, false), baselineExposure: 0.6, isProxy: false, fullSize: (width, height),
                           bitsPerComponent: 14, cameraDescription: "Synthetic")
    }
}
