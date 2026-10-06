import CoreGraphics
import Foundation
import simd

/// Flat-field correction from a shot of the bare light panel.
///
/// The panel shot is reduced to a smooth gain map  G_c(x) = F_c(centre) / F_c(x)  (per channel), so
/// that multiplying a scan by G removes vignetting and illumination fall-off/colour shifts. The map is
/// blurred heavily: it must only describe illumination, never panel texture or dust.
public struct FlatField: Sendable {
    /// Per-channel gain over the sensor, normalised to 1 at the centre.
    public let gain: LinearImage

    public init(gain: LinearImage) { self.gain = gain }

    public init(panel: RawImage) {
        let full = panel.image
        let factor = max(1, full.width / 192)
        var small = full.downsampled(by: factor)
        small = FlatField.gaussianBlur(small, sigma: Double(small.width) * 0.02)
        let cx = small.width / 2, cy = small.height / 2, r = max(1, small.width / 20)
        var centre = SIMD3<Double>.zero
        var n = 0.0
        for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r) { centre += SIMD3<Double>(small[x, y]); n += 1 } }
        centre /= n
        var g = small
        for y in 0..<g.height {
            for x in 0..<g.width {
                let v = SIMD3<Double>(small[x, y])
                g[x, y] = SIMD3<Float>(centre / simd_max(v, SIMD3(repeating: 1e-9)))
            }
        }
        gain = g
    }

    /// Gain at a normalised sensor position (0…1).
    public func gain(atNormalized p: SIMD2<Double>) -> SIMD3<Double> {
        gain.sampleBilinear(SIMD2(p.x * Double(gain.width), p.y * Double(gain.height)))
    }

    static func gaussianBlur(_ img: LinearImage, sigma: Double) -> LinearImage {
        let r = Int(ceil(sigma * 3))
        let k = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        func pass(_ src: LinearImage, horizontal: Bool) -> LinearImage {
            var out = src
            for y in 0..<src.height {
                for x in 0..<src.width {
                    var acc = SIMD3<Double>.zero, ws = 0.0
                    for (i, w) in k.enumerated() {
                        let d = i - r
                        let xx = horizontal ? x + d : x, yy = horizontal ? y : y + d
                        guard xx >= 0, yy >= 0, xx < src.width, yy < src.height else { continue }
                        acc += w * SIMD3<Double>(src[xx, yy]); ws += w
                    }
                    out[x, y] = SIMD3<Float>(acc / ws)
                }
            }
            return out
        }
        return pass(pass(img, horizontal: true), horizontal: false)
    }
}

/// Statistics gathering on a small "analysis proxy" of the sensor image (area-averaged, linear camera RGB).
/// Working on the proxy makes measurements fast and insensitive to grain and dust; the results are stored
/// as numbers, so the resolution they were measured at never affects rendering.
public struct AnalysisProxy: Sendable {
    public let image: LinearImage
    public let flat: FlatField?
    /// Full-resolution sensor size the proxy represents.
    public let sourceWidth: Int, sourceHeight: Int
    /// Sensor saturation level per channel (same units as the image).
    public let clipLevel: SIMD3<Double>

    /// Proxy pixels are 8×8 sensor pixels (≈ 780×520 for 26 MP: plenty for statistics, small enough
    /// to keep a whole roll in memory).
    public static let factor = 8

    public init(raw: RawImage, flat: FlatField?) {
        image = raw.image.downsampled(by: Self.factor)
        self.flat = flat
        sourceWidth = raw.image.width
        sourceHeight = raw.image.height
        clipLevel = raw.clipLevel
    }

    public init(image: LinearImage, sourceWidth: Int, sourceHeight: Int, clipLevel: SIMD3<Double>, flat: FlatField?) {
        self.image = image
        self.flat = flat
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.clipLevel = clipLevel
    }

    /// Fast path: builds the proxy from a half-size (2×2 binned) decode, ~0.4 s for 26 MP.
    /// Binning and demosaic-then-average are both area averages of the same linear data.
    public static func load(_ url: URL, flat: FlatField?) throws -> AnalysisProxy {
        let half = try RawDecoder.decodeAny(url: url, quality: .half)
        return AnalysisProxy(image: half.image.downsampled(by: factor / 2),
                             sourceWidth: half.image.width * 2, sourceHeight: half.image.height * 2,
                             clipLevel: half.clipLevel, flat: flat)
    }

    /// Flat-fielded camera RGB at a full-resolution sensor position.
    public func sample(sensor p: SIMD2<Double>) -> SIMD3<Double> {
        let sx = Double(image.width) / Double(sourceWidth), sy = Double(image.height) / Double(sourceHeight)
        var v = image.sampleBilinear(SIMD2(p.x * sx, p.y * sy))
        if let flat { v *= flat.gain(atNormalized: SIMD2(p.x / Double(sourceWidth), p.y / Double(sourceHeight))) }
        return v
    }

    /// All proxy pixels inside a normalised sensor rectangle (for the film-base median).
    public func samples(inNormalizedRect r: CGRect) -> [SIMD3<Double>] {
        let x0 = max(0, Int(r.minX * Double(image.width))), x1 = min(image.width, Int(ceil(r.maxX * Double(image.width))))
        let y0 = max(0, Int(r.minY * Double(image.height))), y1 = min(image.height, Int(ceil(r.maxY * Double(image.height))))
        var out: [SIMD3<Double>] = []
        guard x1 > x0, y1 > y0 else { return out }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let sensor = SIMD2((Double(x) + 0.5) * Double(sourceWidth) / Double(image.width),
                                   (Double(y) + 0.5) * Double(sourceHeight) / Double(image.height))
                out.append(sample(sensor: sensor))
            }
        }
        return out
    }

    /// Medians of a grid of tiles over the whole sensor (for the automatic film-base estimate).
    public func cellMedians(columns: Int = 64) -> [SIMD3<Double>] {
        let rows = max(1, columns * image.height / image.width)
        var out: [SIMD3<Double>] = []
        for j in 0..<rows {
            for i in 0..<columns {
                let r = CGRect(x: Double(i) / Double(columns), y: Double(j) / Double(rows), width: 1 / Double(columns), height: 1 / Double(rows))
                let s = samples(inNormalizedRect: r)
                if !s.isEmpty { out.append(Statistics.median(s)) }
            }
        }
        return out
    }

    /// Base-normalised densities of the picture's film pixels inside the frame's crop and the detected picture
    /// (each inset by `inset`), with a centre weight for each (Gaussian, σ = 0.35 of the picture size).
    public func pictureDensities(geometry: FrameGeometry, base: SIMD3<Double>, picture: CGRect?, colorFilm: Bool,
                                 inset: Double = 0.03, maxSamples: Int = 120_000) -> (densities: [SIMD3<Double>], weights: [Double]) {
        let size = geometry.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let map = geometry.outputToSource(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let w = Double(size.width), h = Double(size.height)
        let step = max(1.0, sqrt(w * h / Double(maxSamples)))
        let pic = picture.map { $0.insetBy(dx: $0.width * inset, dy: $0.height * inset) }
        // Nothing on a negative is denser than 2.5 above the brightest light of the scan (panel or base): darker
        // samples are a holder, a mask or light leaking onto them — whatever colour the light makes them.
        let sums = image.pixels.indices.filter { $0 % 4 == 0 }.map { Double(image.pixels[$0] + image.pixels[$0 + 1] + image.pixels[$0 + 2]) }.sorted()
        let floor = (sums.isEmpty ? 0 : sums[max(0, sums.count - 1 - sums.count / 200)]) * pow(10, -2.5)
        var d: [SIMD3<Double>] = [], cw: [Double] = []
        var y = h * inset + step / 2
        while y < h * (1 - inset) {
            var x = w * inset + step / 2
            while x < w * (1 - inset) {
                let s = map.apply(SIMD2(x, y))
                let n = CGPoint(x: s.x / Double(sourceWidth), y: s.y / Double(sourceHeight))
                if s.x >= 0, s.y >= 0, s.x < Double(sourceWidth), s.y < Double(sourceHeight), pic?.contains(n) ?? true {
                    let v = sample(sensor: s)
                    if v.x + v.y + v.z > floor, FrameDetector.isFilm(v, base: base, colorFilm: colorFilm) {
                        d.append(NegativeModel.density(v, base: base))
                        let r = pic ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                        let dx = (n.x - r.midX) / r.width, dy = (n.y - r.midY) / r.height
                        cw.append(exp(-(dx * dx + dy * dy) / (2 * 0.35 * 0.35)))
                    }
                }
                x += step
            }
            y += step
        }
        return (d, cw)
    }

    /// Base-normalised densities on a regular grid inside the frame's crop (inset by `inset` per side).
    public func densities(geometry: FrameGeometry, base: SIMD3<Double>, inset: Double = 0.02, maxSamples: Int = 250_000) -> [SIMD3<Double>] {
        let size = geometry.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let map = geometry.outputToSource(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        let w = Double(size.width), h = Double(size.height)
        let step = max(1.0, sqrt(w * h * (1 - 2 * inset) * (1 - 2 * inset) / Double(maxSamples)))
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(maxSamples)
        var y = h * inset + step / 2
        while y < h * (1 - inset) {
            var x = w * inset + step / 2
            while x < w * (1 - inset) {
                let s = map.apply(SIMD2(x, y))
                if s.x >= 0, s.y >= 0, s.x < Double(sourceWidth), s.y < Double(sourceHeight) {
                    out.append(NegativeModel.density(sample(sensor: s), base: base))
                }
                x += step
            }
            y += step
        }
        return out
    }
}
