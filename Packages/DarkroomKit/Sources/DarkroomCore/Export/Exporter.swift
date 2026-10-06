import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers
#if canImport(CTurboJPEG)
import CTurboJPEG
#endif

public enum ExportFormat: String, CaseIterable, Codable, Sendable {
    /// 8-bit JPEG, dithered, 4:4:4 chroma by default (the only lossy format).
    case jpeg
    /// 16 bits per channel, encoded in the output space.
    case tiff16
    /// 32-bit float per channel, linear light in the output space, unclipped.
    case tiff32
    /// 10-bit HEIF.
    case heic
    /// 8-bit PNG, dithered (lossless; used by the identity tests).
    case png8

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .tiff16, .tiff32: return "tif"
        case .heic: return "heic"
        case .png8: return "png"
        }
    }

    public var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .tiff16: return "TIFF 16-bit"
        case .tiff32: return "TIFF 32-bit float (linear)"
        case .heic: return "HEIC 10-bit"
        case .png8: return "PNG 8-bit"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .tiff16, .tiff32: return .tiff
        case .heic: return .heic
        case .png8: return .png
        }
    }
}

public enum TIFFCompression: String, CaseIterable, Codable, Sendable {
    case none, lzw
    public var displayName: String { self == .none ? "Uncompressed" : "LZW (lossless)" }
}

public struct ExportOptions: Codable, Equatable, Sendable {
    public var format: ExportFormat
    public var space: OutputColorSpace
    /// JPEG / HEIC quality, 1…100.
    public var quality: Int
    /// JPEG chroma: 4:4:4 (full colour resolution) or 4:2:0.
    public var chroma444: Bool
    public var tiffCompression: TIFFCompression
    /// Copy EXIF / TIFF / GPS metadata from the original file.
    public var includeMetadata: Bool
    /// Print resolution written into the file (pixels per inch).
    public var dpi: Double

    public init(format: ExportFormat = .jpeg, space: OutputColorSpace = .sRGB, quality: Int = 95, chroma444: Bool = true,
                tiffCompression: TIFFCompression = .none, includeMetadata: Bool = true, dpi: Double = 300) {
        self.format = format
        self.space = space
        self.quality = quality
        self.chroma444 = chroma444
        self.tiffCompression = tiffCompression
        self.includeMetadata = includeMetadata
        self.dpi = dpi
    }
}

public struct ExportReport: Sendable {
    /// Fraction of channel values outside the output gamut/range that had to be clipped (integer formats).
    public var clippedFraction: Double
    public var width: Int
    public var height: Int
    public var bytes: Int
}

public enum ExportError: Error, CustomStringConvertible {
    case write(String)
    public var description: String { switch self { case .write(let s): return "Export failed: \(s)" } }
}

/// Writes pipeline output (display-linear Rec.2020, float) to files.
///
/// Quantisation happens here and only here, as the very last step:
/// - 16-bit: rounding to the nearest code (steps of 1/65535 are far below visibility);
/// - 8-bit (JPEG, PNG): *stochastic rounding* (random dither of one code value), so smooth gradients
///   never band. Values that already sit on an 8-bit code (within 0.001 of a step, e.g. an untouched
///   8-bit source) are kept exactly, so an unedited JPEG/PNG round-trips bit-for-bit. The dither is
///   seeded by pixel position: the same image always gives the same file.
public enum Exporter {

    /// Legacy entry point (Negatives).
    @discardableResult
    public static func write(_ image: LinearImage, to url: URL, format: ExportFormat, space: OutputColorSpace,
                             jpegQuality: Double = 0.95) throws -> ExportReport {
        try write(image, to: url, options: ExportOptions(format: format, space: space, quality: Int((jpegQuality * 100).rounded()),
                                                         includeMetadata: false), software: "Negatives")
    }

    @discardableResult
    public static func write(_ image: LinearImage, to url: URL, options: ExportOptions, metadataSource: URL? = nil,
                             software: String) throws -> ExportReport {
        let w = image.width, h = image.height
        var clipped = 0
        let meta = options.includeMetadata ? metadata(from: metadataSource, software: software, width: w, height: h, dpi: options.dpi)
                                           : basicMetadata(software: software, dpi: options.dpi)
        switch options.format {
        case .tiff32:
            let cg = floatImage(image, space: options.space)
            try writeImageIO(cg, to: url, type: .tiff, metadata: meta, properties: tiffProperties(options))
        case .tiff16:
            let (data, c) = encode16(image, space: options.space)
            clipped = c
            let cg = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: w * 6,
                             space: options.space.cgColorSpace,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                             provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            try writeImageIO(cg, to: url, type: .tiff, metadata: meta, properties: tiffProperties(options))
        case .png8, .jpeg:
            let (data, c) = encode8(image, space: options.space)
            clipped = c
            if options.format == .jpeg {
                try writeJPEG(data, width: w, height: h, to: url, options: options, metadata: meta)
            } else {
                let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                                 space: options.space.cgColorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                 provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                try writeImageIO(cg, to: url, type: .png, metadata: meta, properties: dpiProperties(options))
            }
        case .heic:
            clipped = countClipped(image, space: options.space)
            try writeHEIC(image, to: url, options: options, metadata: meta)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ExportReport(clippedFraction: Double(clipped) / Double(w * h * 3), width: w, height: h, bytes: bytes)
    }

    // MARK: Quantisation

    /// Encodes into the output space and quantises to 16 bits (rounded). Returns data and clipped count.
    static func encode16(_ image: LinearImage, space: OutputColorSpace) -> (Data, Int) {
        let w = image.width, h = image.height
        let m = simd_float3x3(space.fromRec2020)
        var out = [UInt16](repeating: 0, count: w * h * 3)
        var clippedRows = [Int](repeating: 0, count: h)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                clippedRows.withUnsafeMutableBufferPointer { cr in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        var c = 0
                        for x in 0..<w {
                            let i = y * w + x
                            let lin = SIMD3<Double>(m * SIMD3(src[i * 4], src[i * 4 + 1], src[i * 4 + 2]))
                            for k in 0..<3 {
                                var e = space.encode(lin[k])
                                if e < 0 || e > 1 { c += 1; e = min(max(e, 0), 1) }
                                dst[i * 3 + k] = UInt16((e * 65535).rounded())
                            }
                        }
                        cr[y] = c
                    }
                }
            }
        }
        return (out.withUnsafeBytes { Data($0) }, clippedRows.reduce(0, +))
    }

    /// Encodes into the output space and quantises to 8 bits with stochastic rounding (see type docs).
    public static func encode8(_ image: LinearImage, space: OutputColorSpace) -> (Data, Int) {
        let w = image.width, h = image.height
        let m = simd_float3x3(space.fromRec2020)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        var clippedRows = [Int](repeating: 0, count: h)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                clippedRows.withUnsafeMutableBufferPointer { cr in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        var c = 0
                        for x in 0..<w {
                            let i = y * w + x
                            let lin = SIMD3<Double>(m * SIMD3(src[i * 4], src[i * 4 + 1], src[i * 4 + 2]))
                            for k in 0..<3 {
                                var e = space.encode(lin[k])
                                if e < 0 || e > 1 { c += 1; e = min(max(e, 0), 1) }
                                dst[i * 3 + k] = quantize8(e, x: x, y: y, channel: k)
                            }
                        }
                        cr[y] = c
                    }
                }
            }
        }
        return (out.withUnsafeBytes { Data($0) }, clippedRows.reduce(0, +))
    }

    /// Stochastic rounding of an encoded value in [0, 1] to 8 bits.
    @inline(__always) public static func quantize8(_ e: Double, x: Int, y: Int, channel: Int) -> UInt8 {
        let v = e * 255
        let n = v.rounded()
        if abs(v - n) < 1e-3 { return UInt8(n) }          // already on a code: keep it exactly
        let u = ditherNoise(x: x, y: y, channel: channel)  // uniform [0, 1)
        return UInt8(min(255, max(0, (v + u).rounded(.down))))
    }

    /// Deterministic uniform noise in [0, 1) from pixel coordinates (PCG-style integer hash).
    @inline(__always) static func ditherNoise(x: Int, y: Int, channel: Int) -> Double {
        var s = UInt32(truncatingIfNeeded: x) &* 0x9E3779B1 ^ UInt32(truncatingIfNeeded: y) &* 0x85EBCA77 ^ UInt32(channel) &* 0xC2B2AE3D
        s = s &* 747796405 &+ 2891336453
        let word = ((s >> ((s >> 28) &+ 4)) ^ s) &* 277803737
        let r = (word >> 22) ^ word
        return Double(r) / 4294967296.0
    }

    static func countClipped(_ image: LinearImage, space: OutputColorSpace) -> Int {
        let m = simd_float3x3(space.fromRec2020)
        var c = 0
        let n = image.width * image.height
        image.pixels.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let v = m * SIMD3(p[i * 4], p[i * 4 + 1], p[i * 4 + 2])
                for k in 0..<3 where v[k] < 0 || v[k] > 1 { c += 1 }
            }
        }
        return c
    }

    /// Linear float image in the output space (no clipping), tagged with the matching linear profile.
    static func floatImage(_ image: LinearImage, space: OutputColorSpace) -> CGImage {
        let w = image.width, h = image.height
        let m = simd_float3x3(space.fromRec2020)
        var out = [Float](repeating: 0, count: w * h * 3)
        image.pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        let v = m * SIMD3(src[i * 4], src[i * 4 + 1], src[i * 4 + 2])
                        dst[i * 3] = v.x; dst[i * 3 + 1] = v.y; dst[i * 3 + 2] = v.z
                    }
                }
            }
        }
        let data = out.withUnsafeBytes { Data($0) } as CFData
        return CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 96, bytesPerRow: w * 12,
                       space: space.linearCGColorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    // MARK: Writers

    static func tiffProperties(_ o: ExportOptions) -> [CFString: Any] {
        dpiProperties(o).merging([kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: o.tiffCompression == .lzw ? 5 : 1,
                                                                   kCGImagePropertyTIFFXResolution: o.dpi, kCGImagePropertyTIFFYResolution: o.dpi,
                                                                   kCGImagePropertyTIFFResolutionUnit: 2] as [CFString: Any]]) { a, _ in a }
    }

    /// Print resolution as the file's own resolution fields.
    static func dpiProperties(_ o: ExportOptions) -> [CFString: Any] {
        [kCGImagePropertyDPIWidth: o.dpi, kCGImagePropertyDPIHeight: o.dpi]
    }

    static func writeImageIO(_ cg: CGImage, to url: URL, type: UTType, metadata: CGImageMetadata?, properties: [CFString: Any]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportError.write("cannot create \(url.path)")
        }
        CGImageDestinationAddImageAndMetadata(dest, cg, metadata, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.write("finalize \(url.path)") }
    }

    static func writeJPEG(_ rgb: Data, width w: Int, height h: Int, to url: URL, options: ExportOptions, metadata: CGImageMetadata?) throws {
        #if canImport(CTurboJPEG)
        let icc = (options.space.cgColorSpace.copyICCData() as Data?) ?? Data()
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outSize = 0
        var err = [CChar](repeating: 0, count: 256)
        let rc = rgb.withUnsafeBytes { p in
            icc.withUnsafeBytes { ip in
                dr_jpeg_encode(p.bindMemory(to: UInt8.self).baseAddress, Int32(w), Int32(h), Int32(min(100, max(1, options.quality))),
                               options.chroma444 ? 1 : 0, Int32(min(65535, max(1, options.dpi.rounded()))), ip.bindMemory(to: UInt8.self).baseAddress, icc.count, &outPtr, &outSize, &err, 255)
            }
        }
        guard rc == 0, let outPtr else { throw ExportError.write("JPEG encoder: \(String(cString: err))") }
        let jpeg = Data(bytes: outPtr, count: outSize)
        dr_jpeg_free(outPtr)
        if let metadata {
            try rewriteMetadata(of: jpeg, type: .jpeg, metadata: metadata, to: url)
        } else {
            try jpeg.write(to: url)
        }
        #else
        // ImageIO only skips chroma subsampling at maximum quality.
        let q = options.chroma444 ? 1.0 : Double(options.quality) / 100
        let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                         space: options.space.cgColorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                         provider: CGDataProvider(data: rgb as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try writeImageIO(cg, to: url, type: .jpeg, metadata: metadata, properties: [kCGImageDestinationLossyCompressionQuality: q])
        #endif
    }

    static func writeHEIC(_ image: LinearImage, to url: URL, options: ExportOptions, metadata: CGImageMetadata?) throws {
        let cg = floatImage(image, space: options.space)
        let ctx = CIContext(options: [.workingFormat: CIFormat.RGBAf,
                                      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!])
        let ci = CIImage(cgImage: cg)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).heic")
        try ctx.writeHEIF10Representation(of: ci, to: tmp, colorSpace: options.space.cgColorSpace,
                                          options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Double(options.quality) / 100])
        defer { try? FileManager.default.removeItem(at: tmp) }
        try rewriteMetadata(of: try Data(contentsOf: tmp), type: .heic, metadata: metadata, to: url)
    }

    /// Losslessly re-wraps an encoded file with new metadata (no recompression).
    static func rewriteMetadata(of data: Data, type: UTType, metadata: CGImageMetadata?, to url: URL) throws {
        guard let metadata else { try data.write(to: url); return }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportError.write("cannot create \(url.path)")
        }
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) else {
            throw ExportError.write("metadata: \(err?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
    }

    // MARK: Metadata

    static func basicMetadata(software: String, dpi: Double) -> CGImageMetadata {
        let m = CGImageMetadataCreateMutable()
        set(m, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFSoftware, software as CFString)
        setDPI(m, dpi)
        return m
    }

    /// Metadata of the original file with the fields that no longer apply corrected: orientation is baked
    /// into the pixels (so 1), pixel dimensions are the export's, software is ours.
    static func metadata(from source: URL?, software: String, width: Int, height: Int, dpi: Double) -> CGImageMetadata {
        guard let source, let src = CGImageSourceCreateWithURL(source as CFURL, nil),
              let original = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let m = CGImageMetadataCreateMutableCopy(original) else { return basicMetadata(software: software, dpi: dpi) }
        set(m, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        set(m, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, width as CFNumber)
        set(m, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, height as CFNumber)
        set(m, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFSoftware, software as CFString)
        setDPI(m, dpi)
        return m
    }

    static func setDPI(_ m: CGMutableImageMetadata, _ dpi: Double) {
        set(m, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFXResolution, dpi as CFNumber)
        set(m, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFYResolution, dpi as CFNumber)
        set(m, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFResolutionUnit, 2 as CFNumber)
    }

    static func set(_ m: CGMutableImageMetadata, _ dict: CFString, _ key: CFString, _ value: CFTypeRef) {
        CGImageMetadataSetValueMatchingImageProperty(m, dict, key, value)
    }
}
