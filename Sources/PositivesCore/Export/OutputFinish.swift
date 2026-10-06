import Foundation
import simd

/// What an export is for: its size (full resolution, a long edge in pixels, or a print size at a resolution)
/// and the sharpening that suits the medium.
public struct OutputSettings: Codable, Equatable, Sendable {
    public enum Size: String, Codable, CaseIterable, Sendable { case full, longEdge, print }
    public enum Sharpening: String, Codable, CaseIterable, Sendable {
        case none, screen, glossy, matte
        public var title: String {
            switch self {
            case .none: return "None"
            case .screen: return "Screen"
            case .glossy: return "Glossy paper"
            case .matte: return "Matte paper"
            }
        }
    }

    public var size: Size = .full
    /// Long edge in pixels (`longEdge`).
    public var longEdge = 2048
    /// Print: long side in centimetres, and pixels per inch (also written into the file).
    public var printLongCM = 30.0
    public var dpi = 300.0
    public var sharpening: Sharpening = .none
    /// 0 low, 1 standard, 2 high.
    public var strength = 1

    public init() {}

    /// Output pixel size for a picture of `w` × `h` (aspect kept; never 0).
    public func pixelSize(width w: Int, height h: Int) -> (width: Int, height: Int) {
        let long: Int
        switch size {
        case .full: return (w, h)
        case .longEdge: long = max(16, longEdge)
        case .print: long = max(16, Int((printLongCM / 2.54 * dpi).rounded()))
        }
        let s = Double(long) / Double(max(w, h))
        return (max(1, Int((Double(w) * s).rounded())), max(1, Int((Double(h) * s).rounded())))
    }

    /// Sharpening radius (σ, output px) and amount for the medium.
    var sharpen: (sigma: Double, amount: Double)? {
        let k = [0.6, 1.0, 1.5][min(max(strength, 0), 2)]
        switch sharpening {
        case .none: return nil
        case .screen: return (0.7, 0.45 * k)
        // Ink spreads on paper: print sharpening works at a scale set by the print resolution, stronger on
        // matte paper, whose ink spreads more.
        case .glossy: return (0.9 * dpi / 300, 0.65 * k)
        case .matte: return (1.2 * dpi / 300, 0.85 * k)
        }
    }
}

/// The last steps before the file: resampling to the output size and output sharpening.
public enum OutputFinish {
    /// - Parameter grainFree: the same picture rendered without grain. Then only the picture is sharpened and
    ///   the grain is laid back on as it was — sharpening never makes the grain crisper.
    public static func apply(_ image: LinearImage, _ s: OutputSettings, grainFree: LinearImage? = nil) -> LinearImage {
        let size = s.pixelSize(width: image.width, height: image.height)
        var out = Resample.lanczos3(image, width: size.width, height: size.height)
        guard let sh = s.sharpen else { return out }
        guard let clean = grainFree.map({ Resample.lanczos3($0, width: size.width, height: size.height) }) else {
            return sharpen(out, sigma: sh.sigma, amount: sh.amount)
        }
        let sharp = sharpen(clean, sigma: sh.sigma, amount: sh.amount)
        // Grain is a fluctuation of exposure: put it back as a ratio (as a difference in the deepest shadows).
        out.pixels.withUnsafeMutableBufferPointer { g in
            DispatchQueue.concurrentPerform(iterations: size.height) { y in
                for i in (y * size.width * 4)..<((y + 1) * size.width * 4) where i % 4 != 3 {
                    let c = clean.pixels[i], gr = g[i], sv = sharp.pixels[i]
                    let w = min(max((c - 0.002) / 0.006, 0), 1)
                    let ratio = c > 1e-6 ? min(max(gr / c, 0.25), 4) : 1
                    g[i] = max(0, w * sv * ratio + (1 - w) * (sv + gr - c))
                }
            }
        }
        return out
    }

    /// Unsharp mask on lightness only (cube root of luminance, close to perceived lightness), so colours
    /// never fringe; the change is softly limited so edges never get bright or dark halos.
    public static func sharpen(_ image: LinearImage, sigma: Double, amount: Double) -> LinearImage {
        let w = image.width, h = image.height
        var light = [Float](repeating: 0, count: w * h)
        image.pixels.withUnsafeBufferPointer { p in
            light.withUnsafeMutableBufferPointer { l in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        l[i] = cbrt(max(0, ToneMath.lum(SIMD3(p[i * 4], p[i * 4 + 1], p[i * 4 + 2]))))
                    }
                }
            }
        }
        let blurred = Resample.gaussian(light, width: w, height: h, sigma: sigma)
        var out = image
        let a = Float(amount), limit: Float = 0.08
        out.pixels.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let i = y * w + x
                    let l = light[i]
                    guard l > 1e-4 else { continue }
                    let d = limit * tanh(a * (l - blurred[i]) / limit)
                    let f = pow(max(0, l + d) / l, 3)
                    p[i * 4] *= f; p[i * 4 + 1] *= f; p[i * 4 + 2] *= f
                }
            }
        }
        return out
    }
}

/// High-quality resampling in linear light.
public enum Resample {
    @inline(__always) static func lanczos(_ x: Double, _ a: Double = 3) -> Double {
        if x == 0 { return 1 }
        if abs(x) >= a { return 0 }
        let px = Double.pi * x
        return a * sin(px) * sin(px / a) / (px * px)
    }

    /// Weights of one axis: for each output sample, the first input index and normalised weights.
    static func weights(from n: Int, to m: Int) -> [(first: Int, w: [Float])] {
        let scale = Double(n) / Double(m)
        let stretch = max(1, scale)                 // widen the kernel when shrinking (anti-aliasing)
        let support = 3 * stretch
        return (0..<m).map { i in
            let c = (Double(i) + 0.5) * scale - 0.5
            let lo = Int(floor(c - support)) + 1, hi = Int(floor(c + support))
            var w = (lo...hi).map { lanczos((Double($0) - c) / stretch) }
            let sum = w.reduce(0, +)
            w = w.map { $0 / sum }
            return (lo, w.map(Float.init))
        }
    }

    /// Lanczos-3 resampling (separable); negative overshoots are clipped to 0.
    public static func lanczos3(_ img: LinearImage, width W: Int, height H: Int) -> LinearImage {
        guard W != img.width || H != img.height else { return img }
        let w = img.width, h = img.height
        // Horizontal: w × h -> W × h
        let wx = weights(from: w, to: W)
        var tmp = [Float](repeating: 0, count: W * h * 4)
        img.pixels.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for X in 0..<W {
                        var acc = SIMD4<Float>.zero
                        let (first, ws) = wx[X]
                        for (k, wt) in ws.enumerated() {
                            let x = min(max(first + k, 0), w - 1)
                            let i = (y * w + x) * 4
                            acc += wt * SIMD4(src[i], src[i + 1], src[i + 2], src[i + 3])
                        }
                        let o = (y * W + X) * 4
                        dst[o] = acc.x; dst[o + 1] = acc.y; dst[o + 2] = acc.z; dst[o + 3] = acc.w
                    }
                }
            }
        }
        // Vertical: W × h -> W × H
        let wy = weights(from: h, to: H)
        var out = [Float](repeating: 0, count: W * H * 4)
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: H) { Y in
                    let (first, ws) = wy[Y]
                    let o = Y * W * 4
                    for (k, wt) in ws.enumerated() {
                        let r = min(max(first + k, 0), h - 1) * W * 4
                        for j in 0..<(W * 4) { dst[o + j] += wt * src[r + j] }
                    }
                    for j in 0..<(W * 4) where dst[o + j] < 0 { dst[o + j] = 0 }
                }
            }
        }
        return LinearImage(width: W, height: H, pixels: out)
    }

    /// Separable Gaussian blur of a single-channel plane (edges clamped).
    public static func gaussian(_ plane: [Float], width w: Int, height h: Int, sigma: Double) -> [Float] {
        guard sigma > 0.05 else { return plane }
        let r = Int(ceil(3 * sigma))
        var k = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let s = k.reduce(0, +)
        k = k.map { $0 / s }
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        plane.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        var acc: Float = 0
                        for t in -r...r { acc += k[t + r] * src[y * w + min(max(x + t, 0), w - 1)] }
                        dst[y * w + x] = acc
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for t in -r...r {
                        let row = min(max(y + t, 0), h - 1) * w, kt = k[t + r]
                        for x in 0..<w { dst[y * w + x] += kt * src[row + x] }
                    }
                }
            }
        }
        return out
    }
}
