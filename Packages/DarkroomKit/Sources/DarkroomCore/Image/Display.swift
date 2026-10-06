import CoreGraphics
import Foundation
import simd

extension LinearImage {
    /// A CGImage that carries the pipeline's float data unchanged, tagged as extended linear Rec.2020, so
    /// that the system colour-manages it to whatever display it lands on (no 8-bit step on our side).
    public func makeCGImage() -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                       space: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Per-channel histogram of the image as it will look in sRGB (display-referred), `bins` buckets.
    public func histogram(bins: Int = 128) -> [SIMD3<Float>] {
        var h = [SIMD3<Float>](repeating: .zero, count: bins)
        let m = simd_float3x3(OutputColorSpace.sRGB.fromRec2020)
        let n = width * height
        let step = max(1, n / 200_000)
        var i = 0
        while i < n {
            let v = m * SIMD3(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2])
            for k in 0..<3 {
                let e = OutputColorSpace.sRGB.encode(Double(v[k]))
                let b = min(bins - 1, max(0, Int(e * Double(bins))))
                h[b][k] += 1
            }
            i += step
        }
        return h
    }
}
