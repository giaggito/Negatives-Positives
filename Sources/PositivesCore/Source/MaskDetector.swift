import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import simd
import Vision

/// Subject and people masks from Apple's Vision framework (on-device): the photo is rendered small (about
/// 1600 px, default orientation, neutral settings), Vision separates the subject (foreground instances) or
/// people, and the mask comes back at that size; the engine scales it to the photo. Results are cached per
/// file for the session.
public enum MaskDetector {
    private static let lock = NSLock()
    private static var cache: [String: DetectedMask] = [:]
    private static var order: [String] = []

    public static func detect(_ kind: MaskComponent.Kind, source: SourceImage) -> DetectedMask? {
        guard kind.isDetected else { return nil }
        let key = "\(kind.rawValue)|\(source.url.path)"
        lock.lock()
        if let m = cache[key] { lock.unlock(); return m }
        lock.unlock()
        guard let (image, orientation) = visionInput(source) else { return nil }
        var m: DetectedMask?
        switch kind {
        case .subject:
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            let r = VNGenerateForegroundInstanceMaskRequest()
            if (try? handler.perform([r])) != nil, let obs = r.results?.first,
               let b = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
                m = values(of: b, orientation: orientation)
            }
        case .people:
            m = people(source, image: image, orientation: orientation)
            if let p = m { m = refined(p, guide: image) }
        case .sky:
            m = sky(image, orientation: orientation)
        default:
            break
        }
        // Nothing found: an empty mask (selects nothing), so the edit still renders.
        let result = m ?? DetectedMask(width: 1, height: 1, values: [0], orientation: orientation)
        lock.lock()
        cache[key] = result
        order.append(key)
        if order.count > 12 { cache[order.removeFirst()] = nil }
        lock.unlock()
        return result
    }

    // MARK: Sky

    /// Loads the sky model and runs it once in the background (the first prediction prepares the Neural
    /// Engine, which takes seconds), so the first Sky mask is quick.
    public static func warmUp() {
        // Late and at the lowest priority: preparing the model keeps the CPU busy for a while.
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 45) {
            guard let m = skyModel, let a = try? MLMultiArray(shape: [1, 3, 320, 320], dataType: .float32) else { return }
            _ = try? m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": a]))
        }
    }

    private static let modelLock = NSLock()
    private static var skyModelLoaded = false
    private static var skyModelCache: MLModel?
    /// U²-Net sky segmentation (Resources/SkySegmentation.mlmodelc, MIT; see SKY_MODEL_LICENSE.txt).
    static var skyModel: MLModel? {
        modelLock.lock(); defer { modelLock.unlock() }
        if !skyModelLoaded {
            skyModelLoaded = true
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            if let url = Bundle.module.url(forResource: "SkySegmentation", withExtension: "mlmodelc") {
                skyModelCache = try? MLModel(contentsOf: url, configuration: cfg)
            }
        }
        return skyModelCache
    }

    /// Sky: the network's 320 × 320 probability map, scaled to the 1600-px rendering and fitted to its edges
    /// with a guided filter (so branches, roofs and horizons are followed at that resolution).
    static func sky(_ image: CGImage, orientation: FrameGeometry) -> DetectedMask? {
        guard let model = skyModel else { return nil }
        let n = 320
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        let dst = input.dataPointer.assumingMemoryBound(to: Float.self)
        for y in 0..<n {
            for x in 0..<n {
                for c in 0..<3 { dst[(c * n + y) * n + x] = (Float(px[(y * n + x) * 4 + c]) / 255 - mean[c]) / std[c] }
            }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let o = out.featureValue(for: "sky")?.multiArrayValue else { return nil }
        var prob = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { prob[i] = o[i].floatValue }
        let lo = prob.min() ?? 0, hi = prob.max() ?? 1
        prob = prob.map { ($0 - lo) / max(hi - lo, 1e-6) }
        // To the guide's size (bilinear), then edge-aware refinement.
        let W = image.width, H = image.height
        var up = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            let fy = min(max((Double(y) + 0.5) / Double(H) * Double(n) - 0.5, 0), Double(n - 1))
            let y0 = min(Int(fy), n - 2), ty = Float(fy - Double(y0))
            for x in 0..<W {
                let fx = min(max((Double(x) + 0.5) / Double(W) * Double(n) - 0.5, 0), Double(n - 1))
                let x0 = min(Int(fx), n - 2), tx = Float(fx - Double(x0))
                let a = prob[y0 * n + x0] * (1 - tx) + prob[y0 * n + x0 + 1] * tx
                let b = prob[(y0 + 1) * n + x0] * (1 - tx) + prob[(y0 + 1) * n + x0 + 1] * tx
                up[y * W + x] = a * (1 - ty) + b * ty
            }
        }
        return refined(DetectedMask(width: W, height: H, values: up, orientation: orientation), guide: image)
    }

    /// Fits a soft mask to the edges of the picture (He et al.'s guided filter, guide = luminance of the
    /// 1600-px rendering, radius ≈ 0.6 % of its long side): q = ā·I + b̄ with a = cov(I, p) / (var(I) + ε).
    static func refined(_ m: DetectedMask, guide image: CGImage) -> DetectedMask {
        let W = image.width, H = image.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return m }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var I = [Float](repeating: 0, count: W * H), p = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                I[i] = (0.299 * Float(px[i * 4]) + 0.587 * Float(px[i * 4 + 1]) + 0.114 * Float(px[i * 4 + 2])) / 255
                // The mask at this pixel (it may have another resolution).
                let mx = min(m.width - 1, x * m.width / W), my = min(m.height - 1, y * m.height / H)
                p[i] = m.values[my * m.width + mx]
            }
        }
        let r = max(3, Int(Double(max(W, H)) * 0.006))
        func box(_ v: [Float]) -> [Float] {
            // Separable running means with clamped edges.
            var t = [Float](repeating: 0, count: W * H), o = [Float](repeating: 0, count: W * H)
            DispatchQueue.concurrentPerform(iterations: H) { y in
                var acc: Float = 0
                for x in -r...r { acc += v[y * W + min(max(x, 0), W - 1)] }
                for x in 0..<W {
                    t.withUnsafeMutableBufferPointer { $0[y * W + x] = acc / Float(2 * r + 1) }
                    acc += v[y * W + min(x + r + 1, W - 1)] - v[y * W + max(x - r, 0)]
                }
            }
            DispatchQueue.concurrentPerform(iterations: W) { x in
                var acc: Float = 0
                for y in -r...r { acc += t[min(max(y, 0), H - 1) * W + x] }
                for y in 0..<H {
                    o.withUnsafeMutableBufferPointer { $0[y * W + x] = acc / Float(2 * r + 1) }
                    acc += t[min(y + r + 1, H - 1) * W + x] - t[max(y - r, 0) * W + x]
                }
            }
            return o
        }
        let mI = box(I), mp = box(p)
        let mII = box(zip(I, I).map(*)), mIp = box(zip(I, p).map(*))
        let eps: Float = 1e-3
        var a = [Float](repeating: 0, count: W * H), b = [Float](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            let v = mII[i] - mI[i] * mI[i], c = mIp[i] - mI[i] * mp[i]
            a[i] = c / (v + eps)
            b[i] = mp[i] - a[i] * mI[i]
        }
        let ma = box(a), mb = box(b)
        let q = (0..<(W * H)).map { min(max(ma[$0] * I[$0] + mb[$0], 0), 1) }
        return DetectedMask(width: W, height: H, values: q, orientation: m.orientation)
    }

    /// People: Vision's segmentation is made for people who fill the frame, so each person found by the
    /// human detector is also segmented in a close-up (rendered from the full-resolution photo) and pasted
    /// into a 3200-px mask.
    static func people(_ s: SourceImage, image: CGImage, orientation: FrameGeometry) -> DetectedMask? {
        func segment(_ img: CGImage) -> DetectedMask? {
            let r = VNGeneratePersonSegmentationRequest()
            r.qualityLevel = .accurate
            r.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
            let h = VNImageRequestHandler(cgImage: img, orientation: .up)
            guard (try? h.perform([r])) != nil, let b = r.results?.first?.pixelBuffer else { return nil }
            return values(of: b, orientation: orientation)
        }
        let W = image.width, H = image.height
        let k = 3200 / Double(max(W, H))
        let cw = Int(Double(W) * k), ch = Int(Double(H) * k)
        var canvas = [Float](repeating: 0, count: cw * ch)
        /// Pastes `m` (covering the normalised rectangle r of the frame, y down) with max().
        func paste(_ m: DetectedMask, _ r: CGRect) {
            let x0 = max(0, Int(r.minX * Double(cw))), x1 = min(cw, Int(r.maxX * Double(cw)))
            let y0 = max(0, Int(r.minY * Double(ch))), y1 = min(ch, Int(r.maxY * Double(ch)))
            guard x1 > x0, y1 > y0 else { return }
            for y in y0..<y1 {
                let v = (Double(y) + 0.5) / Double(ch)
                let my = min(max((v - r.minY) / r.height * Double(m.height) - 0.5, 0), Double(m.height - 1))
                for x in x0..<x1 {
                    let u = (Double(x) + 0.5) / Double(cw)
                    let mx = min(max((u - r.minX) / r.width * Double(m.width) - 0.5, 0), Double(m.width - 1))
                    let ix = min(Int(mx), m.width - 2 < 0 ? 0 : m.width - 2), iy = min(Int(my), m.height - 2 < 0 ? 0 : m.height - 2)
                    let fx = Float(mx - Double(ix)), fy = Float(my - Double(iy))
                    func at(_ a: Int, _ b: Int) -> Float { m.values[min(b, m.height - 1) * m.width + min(a, m.width - 1)] }
                    let val = (at(ix, iy) * (1 - fx) + at(ix + 1, iy) * fx) * (1 - fy) + (at(ix, iy + 1) * (1 - fx) + at(ix + 1, iy + 1) * fx) * fy
                    canvas[y * cw + x] = max(canvas[y * cw + x], val)
                }
            }
        }
        if let whole = segment(image) { paste(whole, CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let detect = VNDetectHumanRectanglesRequest()
        detect.upperBodyOnly = false
        if (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([detect])) != nil {
            for o in detect.results ?? [] where o.confidence > 0.3 {
                // Vision boxes are normalised with y up; pad generously so the whole figure is inside.
                let b = o.boundingBox
                var r = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height).insetBy(dx: -b.width * 0.35, dy: -b.height * 0.15)
                r = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard r.width > 0.01, r.height > 0.01, let crop = visionInput(s, region: r, maxSide: 1024)?.0, let cm = segment(crop) else { continue }
                paste(cm, r)
            }
        }
        return DetectedMask(width: cw, height: ch, values: canvas, orientation: orientation)
    }

    /// 8-bit sRGB rendering of (a region of) the photo in its default orientation, long side ≤ `maxSide`:
    /// each output pixel is the box average of the sensor pixels under it, through the default tone curve.
    /// `region` is normalised to the oriented frame (y down).
    static func visionInput(_ s: SourceImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                            maxSide: Double = 1600) -> (CGImage, FrameGeometry)? {
        let img = s.image
        let geo = s.defaultGeometry
        let o = geo.orientedSize(sourceWidth: img.width, sourceHeight: img.height)
        let rw = region.width * Double(o.width), rh = region.height * Double(o.height)
        let k = min(1, maxSide / max(rw, rh))               // output px per oriented px
        let ow = max(8, Int(rw * k)), oh = max(8, Int(rh * k))
        let step = max(1, Int((1 / k).rounded()))
        let toSensor = geo.outputToSource(sourceWidth: img.width, sourceHeight: img.height)
        let m = simd_float3x3(s.inputMatrix(whiteBalance: nil))
        let print = ToneMath.printCurve(for: .standard)!.resolved
        let gain = Float(pow(2, s.baselineExposure))
        let toSRGB = ToneMath.rec2020ToSRGB
        var bytes = [UInt8](repeating: 255, count: ow * oh * 4)
        bytes.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: oh) { y in
                for x in 0..<ow {
                    let q = toSensor.apply([region.minX * Double(o.width) + (Double(x) + 0.5) / k, region.minY * Double(o.height) + (Double(y) + 0.5) / k])
                    let sx = min(max(Int(q.x) - step / 2, 0), img.width - step), sy = min(max(Int(q.y) - step / 2, 0), img.height - step)
                    var acc = SIMD3<Float>.zero
                    for dy in 0..<step { for dx in 0..<step { acc += img[sx + dx, sy + dy] } }
                    var c = acc / Float(step * step)
                    if s.kind == .display { c = ToneMath.shoulderInverse(c) }
                    c = m * c * (s.kind == .raw ? gain : 1)
                    let d = s.kind == .raw ? SIMD3(ToneMath.printCurve(c.x, print), ToneMath.printCurve(c.y, print), ToneMath.printCurve(c.z, print))
                                           : SIMD3(ToneMath.shoulder(max(c.x, 0)), ToneMath.shoulder(max(c.y, 0)), ToneMath.shoulder(max(c.z, 0)))
                    let e = simd_clamp(toSRGB * d, .zero, .one)
                    let i = (y * ow + x) * 4
                    out[i] = UInt8(ToneMath.srgbEncode(e.x) * 255 + 0.5)
                    out[i + 1] = UInt8(ToneMath.srgbEncode(e.y) * 255 + 0.5)
                    out[i + 2] = UInt8(ToneMath.srgbEncode(e.z) * 255 + 0.5)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        var g = FrameGeometry()
        g.quarterTurns = geo.quarterTurns; g.flipHorizontal = geo.flipHorizontal; g.flipVertical = geo.flipVertical
        return (cg, g)
    }

    static func values(of b: CVPixelBuffer, orientation: FrameGeometry) -> DetectedMask? {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(b) else { return nil }
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b), bpr = CVPixelBufferGetBytesPerRow(b)
        let format = CVPixelBufferGetPixelFormatType(b)
        var v = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr)
            for x in 0..<w {
                switch format {
                case kCVPixelFormatType_OneComponent32Float: v[y * w + x] = row.load(fromByteOffset: x * 4, as: Float.self)
                case kCVPixelFormatType_OneComponent8: v[y * w + x] = Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255
                case kCVPixelFormatType_OneComponent16Half: v[y * w + x] = Float(row.load(fromByteOffset: x * 2, as: Float16.self))
                default: return nil
                }
            }
        }
        return DetectedMask(width: w, height: h, values: v.map { min(max($0, 0), 1) }, orientation: orientation)
    }
}
