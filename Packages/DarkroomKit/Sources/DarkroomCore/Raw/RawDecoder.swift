import CLibRaw
import ImageIO
import Foundation
import simd

/// A decoded raw file: linear camera RGB plus everything needed to interpret it.
public struct RawImage: Sendable {
    /// Linear camera RGB, black-subtracted, scaled by the fixed `multipliers`. 1.0 = the saturation level
    /// of the most sensitive channel. Values are never clipped by us (the sensor clips by itself).
    public var image: LinearImage
    public var cameraMake: String
    public var cameraModel: String
    /// Fixed channel multipliers applied before demosaicing (camera daylight balance, constant per camera).
    public var multipliers: SIMD3<Double>
    /// Per-channel value at which the sensor saturates, in `image` units.
    public var clipLevel: SIMD3<Double>
    /// Balanced camera RGB -> linear sRGB (D65). Rows sum to 1: equal channels stay neutral.
    public var cameraToSRGB: simd_double3x3
    public var isoSpeed: Double
    public var shutter: Double
    /// The camera's "as shot" white balance expressed as the colour of a neutral object in `image`
    /// (balanced camera RGB, green = 1). Nil when the file has none.
    public var asShotNeutral: SIMD3<Double>?
    /// Camera orientation: quarter turns clockwise needed to show the picture upright (0…3).
    public var orientationQuarterTurns: Int = 0
    /// Number of pixels whose clipped channels were reconstructed (0 unless `reconstructHighlights`).
    public var reconstructedPixels: Int = 0

    public init(image: LinearImage, cameraMake: String, cameraModel: String, multipliers: SIMD3<Double>, clipLevel: SIMD3<Double>,
                cameraToSRGB: simd_double3x3, isoSpeed: Double, shutter: Double) {
        self.image = image
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.multipliers = multipliers
        self.clipLevel = clipLevel
        self.cameraToSRGB = cameraToSRGB
        self.isoSpeed = isoSpeed
        self.shutter = shutter
    }

    /// Balanced camera RGB -> linear Rec.2020.
    public var cameraToRec2020: simd_double3x3 { ColorScience.sRGBToRec2020 * cameraToSRGB }
}

public enum DemosaicQuality: String, Codable, Sendable {
    /// X-Trans Markesteijn 1-pass (~1 s for 26 MP). Same colours, slightly less fine detail.
    case fast
    /// X-Trans Markesteijn 3-pass (~6 s for 26 MP). Used for export.
    case best
    /// 2×2 binned, no interpolation (~0.4 s). For thumbnails and statistics only.
    case half
}

public enum RawDecoderError: Error, CustomStringConvertible {
    case libraw(String, Int32)
    case unsupported(String)

    public var description: String {
        switch self {
        case .libraw(let step, let code): return "LibRaw \(step) failed: \(String(cString: libraw_strerror(code)))"
        case .unsupported(let s): return s
        }
    }
}

/// LibRaw-based decoder configured for scientific, scene-referred output:
/// - camera-native RGB (no colour matrix), linear (gamma 1), no auto-brightening,
/// - fixed white-balance multipliers (camera daylight `pre_mul`), never "as shot",
/// - highlights left unclipped, no `adjust_maximum` (it would vary the scale frame to frame),
/// - no noise reduction, no sharpening, no rotation.
/// LibRaw works in 16-bit integers internally, above the sensor's 14 bits, so nothing is lost; the result
/// is converted to Float immediately.
/// Every LibRaw call runs on this one thread, which never ends. LibRaw is built with OpenMP, whose runtime
/// belongs to the thread that first used it: when that thread exits (GCD retires idle worker threads), the
/// runtime shuts down and LibRaw's critical sections are left pointing at freed locks — the next decode on
/// another thread crashed. A permanent thread keeps the runtime alive; decodes are serialised (each one
/// already uses every core).
final class LibRawThread: @unchecked Sendable {
    static let shared = LibRawThread()
    private let lock = NSCondition()
    private var jobs: [() -> Void] = []

    private init() {
        let t = Thread { [unowned self] in self.loop() }
        t.name = "LibRaw"
        t.qualityOfService = .userInitiated
        t.stackSize = 8 << 20
        t.start()
    }

    private func loop() {
        while true {
            lock.lock()
            while jobs.isEmpty { lock.wait() }
            let job = jobs.removeFirst()
            lock.unlock()
            job()
        }
    }

    /// Runs `body` on the LibRaw thread and waits for it.
    func run<T>(_ body: @escaping () throws -> T) throws -> T {
        if Thread.current.name == "LibRaw" { return try body() }
        var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        jobs.append { result = Result { try body() }; done.signal() }
        lock.signal()
        lock.unlock()
        done.wait()
        return try result!.get()
    }
}

public enum RawDecoder {

    /// - Parameter reconstructHighlights: rebuild clipped channels from the surviving ones (see
    ///   `HighlightReconstruction`). Off for film scans (Negatives), on for photographs (Positives).
    /// - Parameter applyDefaultCrop: crop to the camera's official image area (e.g. 6240×4160 for the X-E4)
    ///   instead of LibRaw's slightly larger active area.
    public static func decode(url: URL, quality: DemosaicQuality = .best, reconstructHighlights: Bool = false,
                              applyDefaultCrop: Bool = false) throws -> RawImage {
        try LibRawThread.shared.run {
            try decodeOnLibRawThread(url: url, quality: quality, reconstructHighlights: reconstructHighlights, applyDefaultCrop: applyDefaultCrop)
        }
    }

    private static func decodeOnLibRawThread(url: URL, quality: DemosaicQuality, reconstructHighlights: Bool,
                                             applyDefaultCrop: Bool) throws -> RawImage {
        guard let lr = libraw_init(0) else { throw RawDecoderError.unsupported("LibRaw init failed") }
        defer { libraw_close(lr) }

        var rc = libraw_open_file(lr, url.path)
        guard rc == 0 else { throw RawDecoderError.libraw("open", rc) }
        rc = libraw_unpack(lr)
        guard rc == 0 else { throw RawDecoderError.libraw("unpack", rc) }

        // Read before processing: LibRaw overwrites it with `user_flip`.
        let flip = Int(lr.pointee.sizes.flip)

        // Fixed multipliers: the camera's daylight balance derived from its colour matrix (constant per model).
        let pre = lr.pointee.color.pre_mul
        var mul = SIMD3<Double>(Double(pre.0), Double(pre.1), Double(pre.2))
        if mul.y <= 0 { mul = [1, 1, 1] }
        mul /= mul.y

        withUnsafeMutablePointer(to: &lr.pointee.params) { p in
            p.pointee.output_color = 0
            p.pointee.gamm.0 = 1
            p.pointee.gamm.1 = 1
            p.pointee.no_auto_bright = 1
            p.pointee.output_bps = 16
            p.pointee.use_camera_wb = 0
            p.pointee.use_auto_wb = 0
            p.pointee.user_mul = (Float(mul.x), Float(mul.y), Float(mul.z), Float(mul.y))
            p.pointee.highlight = 1
            p.pointee.adjust_maximum_thr = 0
            p.pointee.user_flip = 0
            p.pointee.med_passes = 0
            p.pointee.fbdd_noiserd = 0
            p.pointee.half_size = quality == .half ? 1 : 0
            p.pointee.user_qual = quality == .best ? 3 : 0
        }

        rc = libraw_dcraw_process(lr)
        guard rc == 0 else { throw RawDecoderError.libraw("process", rc) }

        let sizes = lr.pointee.sizes
        let w = Int(sizes.iwidth), h = Int(sizes.iheight)
        guard let img = lr.pointee.image, w > 0, h > 0 else { throw RawDecoderError.unsupported("No image data") }
        let colors = Int(lr.pointee.idata.colors)
        guard colors == 3 else { throw RawDecoderError.unsupported("Unsupported colour layout (\(colors) colours)") }

        var pixels = [Float](repeating: 1, count: w * h * 4)
        let scale: Float = 1 / 65535
        pixels.withUnsafeMutableBufferPointer { dst in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let s = img[y * w + x]
                    let o = (y * w + x) * 4
                    dst[o] = Float(s.0) * scale
                    dst[o + 1] = Float(s.1) * scale
                    dst[o + 2] = Float(s.2) * scale
                }
            }
        }

        // LibRaw scales channel c by mul_c / max(mul) when highlights are unclipped, so it saturates there.
        let clip = mul / mul.max()

        let rc3 = lr.pointee.color.rgb_cam
        let m = simd_double3x3(rows: [
            SIMD3(Double(rc3.0.0), Double(rc3.0.1), Double(rc3.0.2)),
            SIMD3(Double(rc3.1.0), Double(rc3.1.1), Double(rc3.1.2)),
            SIMD3(Double(rc3.2.0), Double(rc3.2.1), Double(rc3.2.2)),
        ])

        func string<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { raw in
                let bytes = raw.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
        }

        // As-shot white balance: the camera multiplies channel c by cam_mul[c]; we balanced with `mul`, so a
        // neutral object under the shooting light has balanced camera RGB ∝ mul / cam_mul.
        let cm = lr.pointee.color.cam_mul
        var asShot: SIMD3<Double>?
        if cm.0 > 0, cm.1 > 0, cm.2 > 0 {
            let n = mul / SIMD3(Double(cm.0), Double(cm.1), Double(cm.2))
            asShot = n / n.y
        }
        let turns: Int
        switch flip {
        case 3: turns = 2
        case 5: turns = 3   // 90° counter-clockwise
        case 6: turns = 1   // 90° clockwise
        default: turns = 0
        }

        var image = LinearImage(width: w, height: h, pixels: pixels)
        // DNG lens corrections (OpcodeList3): distortion now, on the whole active area; vignetting after the
        // highlights are rebuilt (so the gain never makes unclipped corners look clipped).
        let op3 = lr.pointee.color.dng_levels.rawopcodes.2
        let opcodes = op3.len > 0 && op3.data != nil ? DNGOpcodes(Data(bytes: op3.data, count: Int(op3.len))) : nil
        if let opcodes, !opcodes.warps.isEmpty { DNGOpcodes.applyWarps(opcodes.warps, to: &image) }
        var cropOrigin = (x: 0, y: 0)
        if applyDefaultCrop {
            let sz = lr.pointee.sizes
            let c = sz.raw_inset_crops.0
            let sx = Double(w) / Double(max(1, Int(sz.width))), sy = Double(h) / Double(max(1, Int(sz.height)))
            if c.cleft != 0xffff, c.ctop != 0xffff, c.cwidth > 0, c.cheight > 0 {
                let x0 = Int((Double(Int(c.cleft) - Int(sz.left_margin)) * sx).rounded())
                var y0 = Int((Double(Int(c.ctop) - Int(sz.top_margin)) * sy).rounded())
                let cw = Int((Double(c.cwidth) * sx).rounded())
                var ch = Int((Double(c.cheight) * sy).rounded())
                // LibRaw's inset for some Fuji bodies is a few rows short of the camera's own size (X-E4:
                // 6240×4155 vs 6240×4160 in the camera JPEG). When the file declares an aspect ratio, extend
                // upwards to it, keeping the bottom edge — this matches the camera and Apple's decoder exactly.
                let aspect = Double(sz.raw_aspect) / 1000
                if aspect > 1, abs(Double(cw) / Double(ch) / aspect - 1) < 0.01 {
                    let target = Int((Double(cw) / aspect).rounded())
                    if target > ch, y0 - (target - ch) >= 0 { y0 -= target - ch; ch = target }
                }
                if x0 >= 0, y0 >= 0, x0 + cw <= w, y0 + ch <= h, cw < w || ch < h {
                    image = image.cropped(x: x0, y: y0, width: cw, height: ch)
                    cropOrigin = (x0, y0)
                }
            }
        }
        var reconstructed = 0
        if reconstructHighlights {
            reconstructed = HighlightReconstruction.apply(to: &image, clipLevel: clip, neutral: asShot ?? [1, 1, 1])
        }
        if let opcodes, !opcodes.vignettes.isEmpty {
            DNGOpcodes.applyVignettes(opcodes.vignettes, to: &image, origin: cropOrigin, full: (w, h))
        }

        var result = RawImage(
            image: image,
            cameraMake: string(lr.pointee.idata.make),
            cameraModel: string(lr.pointee.idata.model),
            multipliers: mul,
            clipLevel: clip,
            cameraToSRGB: m,
            isoSpeed: Double(lr.pointee.other.iso_speed),
            shutter: Double(lr.pointee.other.shutter)
        )
        result.asShotNeutral = asShot
        result.orientationQuarterTurns = turns
        result.reconstructedPixels = reconstructed
        return result
    }
}

extension RawDecoder {
    /// A RAW file, or an image file — JPEG, TIFF, HEIC, PNG, e.g. a scanner's or a phone's picture of a negative —
    /// brought into the same form: its colours in linear light (linear Rec.2020 as the "camera" space, 1.0 = the
    /// file's white, where it clips). RAW files keep far more of the film's density range; image files work, but
    /// their own tone curve and 8-bit steps limit how faithfully a negative can be inverted.
    public static func decodeAny(url: URL, quality: DemosaicQuality = .best, reconstructHighlights: Bool = false,
                                 applyDefaultCrop: Bool = false) throws -> RawImage {
        if ImageLoader.isRaw(url) {
            return try decode(url: url, quality: quality, reconstructHighlights: reconstructHighlights, applyDefaultCrop: applyDefaultCrop)
        }
        let l = try ImageLoader.load(url: url)
        var img = quality == .half ? l.image.downsampled(by: 2) : l.image
        img.pixels.withUnsafeMutableBufferPointer { p in
            for i in stride(from: 0, to: p.count, by: 4) {
                p[i] = max(p[i], 0); p[i + 1] = max(p[i + 1], 0); p[i + 2] = max(p[i + 2], 0); p[i + 3] = 1
            }
        }
        let tiff = l.properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        var r = RawImage(image: img, cameraMake: tiff?["Make"] as? String ?? "", cameraModel: tiff?["Model"] as? String ?? "",
                         multipliers: [1, 1, 1], clipLevel: [1, 1, 1], cameraToSRGB: ColorScience.sRGBToRec2020.inverse,
                         isoSpeed: 0, shutter: 0)
        r.orientationQuarterTurns = l.orientationQuarterTurns
        return r
    }
}
