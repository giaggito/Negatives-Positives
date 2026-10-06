import CoreGraphics
import Foundation
import simd

public enum SourceLoader {
    /// Opens a photograph. `proxy` = a quick half-resolution decode for RAF (≈0.4 s instead of ≈5 s),
    /// shown while the full-quality decode runs; ignored for other formats (they decode fast anyway).
    public static func load(url: URL, proxy: Bool = false) throws -> SourceImage {
        if ImageLoader.isRaw(url) {
            let raw = try RawDecoder.decode(url: url, quality: proxy ? .half : .best, reconstructHighlights: true, applyDefaultCrop: true)
            let neutral = raw.asShotNeutral ?? [1, 1, 1]
            let asShot = WhiteBalance.neutralizing(raw.cameraToRec2020 * neutral) ?? .neutral
            let full: (Int, Int) = proxy ? fullRawSize(raw.image, url: url) : (raw.image.width, raw.image.height)
            let src = SourceImage(url: url, kind: .raw, image: raw.image, cameraToRec2020: raw.cameraToRec2020,
                                  asShotWhiteBalance: asShot, defaultOrientation: (raw.orientationQuarterTurns, false),
                                  baselineExposure: 0, isProxy: proxy, fullSize: full, bitsPerComponent: 14,
                                  cameraDescription: "\(raw.cameraMake) \(raw.cameraModel)")
            let baseline = baselineExposure(for: src)
            return SourceImage(url: url, kind: .raw, image: raw.image, cameraToRec2020: raw.cameraToRec2020,
                               asShotWhiteBalance: asShot, defaultOrientation: (raw.orientationQuarterTurns, false),
                               baselineExposure: baseline, isProxy: proxy, fullSize: full, bitsPerComponent: 14,
                               cameraDescription: src.cameraDescription)
        }
        let l = try ImageLoader.load(url: url)
        let props = l.properties
        let make = (props["{TIFF}"] as? [String: Any])?["Make"] as? String ?? ""
        let model = (props["{TIFF}"] as? [String: Any])?["Model"] as? String ?? ""
        return SourceImage(url: url, kind: .display, image: l.image, cameraToRec2020: matrix_identity_double3x3,
                           asShotWhiteBalance: .neutral, defaultOrientation: (l.orientationQuarterTurns, l.flipHorizontal),
                           baselineExposure: 0, isProxy: false, fullSize: (l.image.width, l.image.height),
                           bitsPerComponent: l.bitsPerComponent, cameraDescription: [make, model].filter { !$0.isEmpty }.joined(separator: " "))
    }

    /// The full-quality size of a RAF whose half-size decode is `half`: the camera's declared size when the
    /// aspect matches, else twice the half size.
    static func fullRawSize(_ half: LinearImage, url: URL) -> (Int, Int) {
        let props = ImageLoader.properties(url: url)
        if let w = props["PixelWidth"] as? Int, let h = props["PixelHeight"] as? Int, w > 0, h > 0,
           abs(Double(w) / Double(h) - Double(half.width) / Double(half.height)) < 0.01 {
            return (w, h)
        }
        return (half.width * 2, half.height * 2)
    }

    /// Stops to add so the Standard profile is as bright as the camera's own JPEG (which also accounts for
    /// the camera's dynamic-range modes). The medians of the two luminances are matched; the median commutes
    /// with the (monotonic) tone curve, so the solution is closed-form:
    ///     EV = log2( P⁻¹(median_jpeg) / median_raw )
    static func baselineExposure(for src: SourceImage) -> Double {
        guard let thumb = ImageLoader.browsingThumbnail(url: src.url, maxPixel: 1024),
              let jpeg = try? ImageLoader.linearize(thumb),
              let curve = ToneMath.printCurve(for: .standard)
        else { return 0 }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        var jy = [Double]()
        for i in stride(from: 0, to: jpeg.width * jpeg.height, by: 3) {
            jy.append(Double(ToneMath.lum(SIMD3(jpeg.pixels[i * 4], jpeg.pixels[i * 4 + 1], jpeg.pixels[i * 4 + 2]))))
        }
        let m = simd_float3x3(src.inputMatrix(whiteBalance: nil))
        var ry = [Double]()
        let step = max(1, src.image.width * src.image.height / 300_000)
        for i in stride(from: 0, to: src.image.width * src.image.height, by: step) {
            let c = m * SIMD3(src.image.pixels[i * 4], src.image.pixels[i * 4 + 1], src.image.pixels[i * 4 + 2])
            ry.append(Double(ToneMath.lum(c)))
        }
        let mj = median(jy), mr = median(ry)
        guard mj > 1e-5, mj < 0.95, mr > 1e-7 else { return 0 }
        let target = PrintCurve.invert(mj, curve.resolved)
        return min(7, max(-3, log2(target / mr)))
    }
}
