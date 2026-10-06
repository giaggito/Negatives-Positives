import CoreGraphics
import Foundation
import simd

/// Output colour spaces. Each has an analytic definition (primaries + transfer function) used for the
/// encoding, and the matching system ICC profile that gets embedded. Tests check the two agree.
public enum OutputColorSpace: String, CaseIterable, Codable, Sendable {
    case sRGB, displayP3, adobeRGB, proPhoto, rec2020

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB (1998)"
        case .proPhoto: return "ProPhoto RGB"
        case .rec2020: return "Rec. 2020"
        }
    }

    public var space: ColorScience.RGBSpace {
        switch self {
        case .sRGB: return ColorScience.sRGB
        case .displayP3: return ColorScience.displayP3
        case .adobeRGB: return ColorScience.adobeRGB
        case .proPhoto: return ColorScience.proPhoto
        case .rec2020: return ColorScience.rec2020
        }
    }

    /// Linear Rec.2020 (D65) -> linear output space, with Bradford adaptation when the white differs.
    public var fromRec2020: simd_double3x3 {
        var m = space.fromXYZ
        if space.white != ColorScience.d65 {
            m = m * ColorScience.adaptation(from: ColorScience.xyz(fromXY: ColorScience.d65), to: ColorScience.xyz(fromXY: space.white))
        }
        return m * ColorScience.rec2020.toXYZ
    }

    /// Encoded -> linear (inverse of `encode`).
    public func decode(_ e: Double) -> Double {
        let s = e < 0 ? -1.0 : 1.0, a = abs(e)
        switch self {
        case .sRGB, .displayP3:
            return s * (a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4))
        case .adobeRGB: return s * pow(a, 563.0 / 256.0)
        case .proPhoto: return s * pow(a, 1.8)
        case .rec2020: return s * pow(a, 2.4)
        }
    }

    /// Transfer function (linear -> encoded), as defined by the embedded ICC profiles.
    public func encode(_ v: Double) -> Double {
        let s = v < 0 ? -1.0 : 1.0, a = abs(v)
        switch self {
        case .sRGB, .displayP3:
            return s * (a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1 / 2.4) - 0.055)
        case .adobeRGB:
            return s * pow(a, 256.0 / 563.0)
        case .proPhoto:
            return s * pow(a, 1 / 1.8)          // Apple's ROMM RGB profile: pure 1.8, no linear toe
        case .rec2020:
            return s * pow(a, 1 / 2.4)          // Apple's ITU-R 2020 profile: pure 2.4 (BT.1886 display)
        }
    }

    /// ICC-carrying CGColorSpace for encoded (integer) output.
    public var cgColorSpace: CGColorSpace {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB: return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        case .proPhoto: return CGColorSpace(name: CGColorSpace.rommrgb)!
        case .rec2020: return CGColorSpace(name: CGColorSpace.itur_2020)!
        }
    }

    /// Linear-light version of the space, for 32-bit float output (values outside 0…1 are kept).
    public var linearCGColorSpace: CGColorSpace {
        switch self {
        case .sRGB: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        case .rec2020: return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        case .adobeRGB, .proPhoto:
            let s = space
            let xyz = s.toXYZ
            let wp = ColorScience.xyz(fromXY: s.white)
            var white: [CGFloat] = [wp.x, wp.y, wp.z].map { CGFloat($0) }
            var black: [CGFloat] = [0, 0, 0]
            var gamma: [CGFloat] = [1, 1, 1]
            // CGColorSpace expects the matrix row-major as XYZ of R, G, B (i.e. the columns of toXYZ).
            var m: [CGFloat] = [xyz.columns.0, xyz.columns.1, xyz.columns.2].flatMap { [$0.x, $0.y, $0.z] }.map { CGFloat($0) }
            return CGColorSpace(calibratedRGBWhitePoint: &white, blackPoint: &black, gamma: &gamma, matrix: &m)!
        }
    }
}
