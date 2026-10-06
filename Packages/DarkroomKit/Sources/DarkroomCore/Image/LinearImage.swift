import Foundation
import simd

/// A 32-bit float RGBA image, interleaved, rows top-down. Alpha is carried but unused (always 1).
/// This is the only pixel container the pipeline uses on the CPU side: there is no 8-bit path.
public struct LinearImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * 4, "LinearImage: pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: SIMD3<Float> = .zero) {
        self.width = width
        self.height = height
        var p = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) { p[i * 4] = fill.x; p[i * 4 + 1] = fill.y; p[i * 4 + 2] = fill.z }
        self.pixels = p
    }

    @inline(__always) public subscript(x: Int, y: Int) -> SIMD3<Float> {
        get { let i = (y * width + x) * 4; return SIMD3(pixels[i], pixels[i + 1], pixels[i + 2]) }
        set { let i = (y * width + x) * 4; pixels[i] = newValue.x; pixels[i + 1] = newValue.y; pixels[i + 2] = newValue.z }
    }

    /// Area-average (box) downsample by an integer factor. Averaging in linear light is physically correct
    /// and never overshoots, so it can feed logarithms safely.
    public func downsampled(by factor: Int) -> LinearImage {
        guard factor > 1 else { return self }
        let w = width / factor, h = height / factor
        var out = [Float](repeating: 1, count: w * h * 4)
        let norm = 1 / Float(factor * factor)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        var acc = SIMD3<Float>.zero
                        for sy in 0..<factor {
                            var i = ((y * factor + sy) * width + x * factor) * 4
                            for _ in 0..<factor {
                                acc += SIMD3(src[i], src[i + 1], src[i + 2])
                                i += 4
                            }
                        }
                        let o = (y * w + x) * 4
                        dst[o] = acc.x * norm; dst[o + 1] = acc.y * norm; dst[o + 2] = acc.z * norm
                    }
                }
            }
        }
        return LinearImage(width: w, height: h, pixels: out)
    }

    /// Exact sub-rectangle copy (no resampling).
    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> LinearImage {
        var out = [Float](repeating: 0, count: w * h * 4)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for row in 0..<h {
                    let s = ((y + row) * width + x) * 4
                    dst.baseAddress!.advanced(by: row * w * 4).update(from: src.baseAddress!.advanced(by: s), count: w * 4)
                }
            }
        }
        return LinearImage(width: w, height: h, pixels: out)
    }

    /// Bilinear sample at continuous pixel coordinates (pixel centres at +0.5), edges clamped.
    public func sampleBilinear(_ p: SIMD2<Double>) -> SIMD3<Double> {
        let fx = min(max(p.x - 0.5, 0), Double(width - 1)), fy = min(max(p.y - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func v(_ x: Int, _ y: Int) -> SIMD3<Double> { SIMD3<Double>(self[x, y]) }
        let top = v(x0, y0) * (1 - tx) + v(x1, y0) * tx
        let bottom = v(x0, y1) * (1 - tx) + v(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }
}
