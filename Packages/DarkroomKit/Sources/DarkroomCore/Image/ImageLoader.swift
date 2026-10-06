import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// A decoded display-referred file (JPEG, HEIC, PNG, TIFF…), linearised into the working space.
public struct LoadedImage: @unchecked Sendable {
    /// Linear-light Rec.2020 (D65), 32-bit float, converted from the file's embedded ICC profile by ColorSync.
    /// Values are exactly the file's colours: nothing is clipped, re-encoded or tone-mapped.
    public var image: LinearImage
    /// Quarter turns clockwise needed to show the picture upright, from the EXIF orientation (mirrored
    /// orientations also set `flipHorizontal`).
    public var orientationQuarterTurns: Int
    public var flipHorizontal: Bool
    /// Bits per channel in the file (8 for JPEG, 16 for 16-bit TIFF …).
    public var bitsPerComponent: Int
    /// Name of the embedded profile, if any ("sRGB IEC61966-2.1", "Display P3", …).
    public var profileName: String?
    /// The file's metadata (EXIF, TIFF, GPS …) to carry into exports.
    public var properties: [String: Any]
}

public enum ImageLoaderError: Error, CustomStringConvertible {
    case unreadable(String)
    public var description: String { switch self { case .unreadable(let s): return "Cannot read \(s)" } }
}

public enum ImageLoader {
    /// RAW formats read with LibRaw: Fujifilm, Canon, Nikon, Sony, Panasonic, Olympus / OM, Pentax, Leica,
    /// Samsung, Sigma, Hasselblad, Phase One, Kodak, Minolta, GoPro and any DNG.
    public static let rawExtensions: Set<String> = [
        "raf", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "rw2", "raw", "rwl", "orf", "ori", "pef", "ptx",
        "dng", "srw", "x3f", "3fr", "fff", "iiq", "mos", "erf", "mef", "mrw", "dcr", "kdc", "gpr",
    ]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]

    public static func isRaw(_ url: URL) -> Bool { rawExtensions.contains(url.pathExtension.lowercased()) }
    public static func isSupported(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return rawExtensions.contains(e) || imageExtensions.contains(e)
    }

    /// Decodes and linearises an image file. ColorSync converts from the embedded ICC profile (or sRGB when
    /// the file has none) to extended-range linear Rec.2020 in 32-bit float; Rec.2020 contains every
    /// common source gamut, so nothing is clipped.
    public static func load(url: URL) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary)
        else { throw ImageLoaderError.unreadable(url.lastPathComponent) }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        let profile = props[kCGImagePropertyProfileName as String] as? String
        let image = try linearize(cg, profileName: profile)
        let (turns, flip) = orientation(props[kCGImagePropertyOrientation as String] as? Int ?? 1)
        return LoadedImage(image: image, orientationQuarterTurns: turns, flipHorizontal: flip,
                           bitsPerComponent: cg.bitsPerComponent,
                           profileName: cg.colorSpace.flatMap { $0.name as String? } ?? (props[kCGImagePropertyProfileName as String] as? String),
                           properties: props)
    }

    /// The standard space a CGImage is encoded in, recognised by its colour space (system profiles) or the
    /// embedded profile's name. Nil for anything else.
    static func standardSpace(of cg: CGImage, profileName: String?) -> OutputColorSpace? {
        if cg.colorSpace == nil { return .sRGB }
        if let n = cg.colorSpace?.name as String? {
            let known: [(CFString, OutputColorSpace)] = [(CGColorSpace.sRGB, .sRGB), (CGColorSpace.displayP3, .displayP3),
                                                         (CGColorSpace.adobeRGB1998, .adobeRGB), (CGColorSpace.rommrgb, .proPhoto),
                                                         (CGColorSpace.itur_2020, .rec2020)]
            if let k = known.first(where: { ($0.0 as String) == n }) { return k.1 }
        }
        switch profileName {
        case "sRGB IEC61966-2.1", "sRGB IEC61966-2-1 black scaled", "sRGB": return .sRGB
        case "Display P3": return .displayP3
        case "Adobe RGB (1998)", "Compatible with Adobe RGB (1998)": return .adobeRGB
        case "ProPhoto RGB", "ROMM RGB: ISO 22028-2:2013": return .proPhoto
        default: return nil
        }
    }

    /// Converts any CGImage into linear Rec.2020 float.
    ///
    /// Files in a standard space (sRGB, Display P3, Adobe RGB, ProPhoto, Rec.2020 — nearly all photos) are
    /// decoded analytically: the integer codes are read without any conversion, linearised with the space's
    /// exact transfer function and taken to Rec.2020 with a Double-precision matrix. This is exact (ColorSync
    /// works through lookup tables for integer data, off by up to a 16-bit code), so an unedited file
    /// round-trips bit for bit. Any other profile goes through ColorSync in float.
    public static func linearize(_ cg: CGImage, profileName: String? = nil) throws -> LinearImage {
        if cg.colorSpace?.model == .rgb || cg.colorSpace == nil,
           cg.bitsPerComponent <= 16, !cg.bitmapInfo.contains(.floatComponents),
           let space = standardSpace(of: cg, profileName: profileName) {
            return try linearizeAnalytic(cg, space: space)
        }
        return try linearizeColorSync(cg)
    }

    static func linearizeAnalytic(_ cg: CGImage, space: OutputColorSpace) throws -> LinearImage {
        let w = cg.width, h = cg.height
        let bits = cg.bitsPerComponent > 8 ? 16 : 8
        let cs = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // Same colour space, wider-or-equal depth: a plain copy of the codes (8 -> 16 bit is exact: ×257).
        let bpr = w * 4 * bits / 8
        var raw = [UInt8](repeating: 0, count: bpr * h)
        let info: UInt32 = bits == 16 ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
                                      : CGImageAlphaInfo.noneSkipLast.rawValue
        let ok = raw.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: bits, bytesPerRow: bpr, space: cs, bitmapInfo: info)
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return try linearizeColorSync(cg) }
        // Lookup table: code -> linear (exact transfer function in Double).
        let levels = bits == 16 ? 65536 : 256
        let lut = (0..<levels).map { Float(space.decode(Double($0) / Double(levels - 1))) }
        let m = simd_float3x3(space.fromRec2020.inverse)
        var pixels = [Float](repeating: 1, count: w * h * 4)
        raw.withUnsafeBytes { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let v: SIMD3<Float>
                        if bits == 16 {
                            let o = y * bpr + x * 8
                            v = SIMD3(lut[Int(src.load(fromByteOffset: o, as: UInt16.self))],
                                      lut[Int(src.load(fromByteOffset: o + 2, as: UInt16.self))],
                                      lut[Int(src.load(fromByteOffset: o + 4, as: UInt16.self))])
                        } else {
                            let o = y * bpr + x * 4
                            v = SIMD3(lut[Int(src[o])], lut[Int(src[o + 1])], lut[Int(src[o + 2])])
                        }
                        let c = m * v
                        let i = (y * w + x) * 4
                        dst[i] = c.x; dst[i + 1] = c.y; dst[i + 2] = c.z
                    }
                }
            }
        }
        return LinearImage(width: w, height: h, pixels: pixels)
    }

    /// ColorSync conversion into extended linear Rec.2020 float (any profile).
    static func linearizeColorSync(_ cg: CGImage) throws -> LinearImage {
        let w = cg.width, h = cg.height
        var image = cg
        if cg.colorSpace == nil || cg.colorSpace?.model != .rgb {
            // Grey or untagged: let CoreGraphics interpret it, tagging untagged data as sRGB.
            if cg.colorSpace == nil, let tagged = cg.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { image = tagged }
        }
        var pixels = [Float](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.setRenderingIntent(.relativeColorimetric)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ImageLoaderError.unreadable("pixel data") }
        // Opaque photographs: alpha is 1 everywhere; un-premultiply defensively for files that carry alpha.
        pixels.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let a = p[i + 3]
                    if a > 0, a != 1 { p[i] /= a; p[i + 1] /= a; p[i + 2] /= a }
                    p[i + 3] = 1
                }
            }
        }
        return LinearImage(width: w, height: h, pixels: pixels)
    }

    /// EXIF orientation -> (quarter turns clockwise, horizontal flip applied first).
    public static func orientation(_ exif: Int) -> (Int, Bool) {
        switch exif {
        case 2: return (0, true)
        case 3: return (2, false)
        case 4: return (2, true)
        case 5: return (3, true)   // transpose = mirror, then 90° counter-clockwise
        case 6: return (1, false)
        case 7: return (1, true)   // transverse = mirror, then 90° clockwise
        case 8: return (3, false)
        default: return (0, false)
        }
    }

    /// Fast thumbnail for browsing (embedded preview when present), already upright. 8-bit is fine here:
    /// it is only ever shown in the filmstrip until the real render replaces it.
    public static func browsingThumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// The file's metadata dictionary (EXIF, TIFF, GPS…), for carrying into exports. Works for RAF too.
    public static func properties(url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
    }
}
