import CoreGraphics
import Foundation
import simd

/// An opened photograph: its pixels as they come out of the decoder ("native" values) plus what is needed
/// to bring them into the working space.
///
/// - RAF: linear camera RGB, balanced with the camera's fixed daylight multipliers, highlights rebuilt,
///   cropped to the camera's image area. White balance is applied as a diagonal in camera space
///   (real raw white balance), then the camera matrix takes it to linear Rec.2020.
/// - JPEG / HEIC / PNG / TIFF: the file's colours, linearised from its ICC profile into linear Rec.2020.
///   White balance is a Bradford adaptation in linear light.
public final class SourceImage: @unchecked Sendable {
    public enum Kind: String, Sendable { case raw, display }

    public let url: URL
    public let kind: Kind
    public let image: LinearImage
    /// Balanced camera RGB -> linear Rec.2020 (identity for display-referred files).
    public let cameraToRec2020: simd_double3x3
    /// White balance the photo was shot with (RAF), or the neutral setting (other files).
    public let asShotWhiteBalance: WhiteBalance
    /// Orientation from the camera / EXIF, as the default geometry.
    public let defaultOrientation: (quarterTurns: Int, flipHorizontal: Bool)
    /// Exposure offset (stops) that makes a RAF as bright as the camera's own JPEG (0 for other files).
    public let baselineExposure: Double
    /// A quick, half-resolution decode shown while the full-quality one is prepared.
    public let isProxy: Bool
    /// Pixel size of the full-quality image (equal to `image` size unless `isProxy`).
    public let fullSize: (width: Int, height: Int)
    public let bitsPerComponent: Int
    public let cameraDescription: String

    public init(url: URL, kind: Kind, image: LinearImage, cameraToRec2020: simd_double3x3, asShotWhiteBalance: WhiteBalance,
                defaultOrientation: (Int, Bool), baselineExposure: Double, isProxy: Bool, fullSize: (Int, Int),
                bitsPerComponent: Int, cameraDescription: String) {
        self.url = url
        self.kind = kind
        self.image = image
        self.cameraToRec2020 = cameraToRec2020
        self.asShotWhiteBalance = asShotWhiteBalance
        self.defaultOrientation = defaultOrientation
        self.baselineExposure = baselineExposure
        self.isProxy = isProxy
        self.fullSize = fullSize
        self.bitsPerComponent = bitsPerComponent
        self.cameraDescription = cameraDescription
    }

    public var defaultProfile: ToneProfile { kind == .raw ? .standard : .original }
    public var availableProfiles: [ToneProfile] { kind == .raw ? [.standard, .flat, .linear] : [.original] }

    /// The geometry a fresh edit starts from (upright).
    public var defaultGeometry: FrameGeometry {
        FrameGeometry(quarterTurns: defaultOrientation.quarterTurns, flipHorizontal: defaultOrientation.flipHorizontal)
    }

    /// Native -> linear Rec.2020 including white balance (nil = as shot).
    ///
    /// RAF: the light's colour W (from temperature/tint) is expressed in balanced camera RGB,
    /// c_W = camToRec2020⁻¹ · Rec2020(W) with Y(W) = 1, and divided out channel by channel:
    ///     M = camToRec2020 · diag(1 / c_W)
    /// so an object lit by W becomes neutral with its luminance preserved.
    /// Other files: Bradford adaptation from W to D65 in linear Rec.2020 (identity at 6504 K / 0).
    public func inputMatrix(whiteBalance wb: WhiteBalance?) -> simd_double3x3 {
        let wb = wb ?? asShotWhiteBalance
        switch kind {
        case .display:
            return wb.matrix
        case .raw:
            let xyz = ColorScience.xyz(fromXY: ColorScience.xy(fromUV: wb.sourceWhiteUV))
            let rgb = ColorScience.rec2020.fromXYZ * xyz
            let c = cameraToRec2020.inverse * rgb
            let safe = SIMD3<Double>(max(c.x, 1e-4), max(c.y, 1e-4), max(c.z, 1e-4))
            return cameraToRec2020 * simd_double3x3(diagonal: 1 / safe)
        }
    }

    /// Eyedropper: the white balance that makes a pixel (native values, before white balance) neutral.
    /// For display-referred files the value is first taken out of the display shoulder (see `ToneMath`).
    public func whiteBalance(neutralizing native: SIMD3<Double>) -> WhiteBalance? {
        switch kind {
        case .raw:
            return WhiteBalance.neutralizing(cameraToRec2020 * native)
        case .display:
            let pre = SIMD3<Double>(ToneMath.shoulderInverse(SIMD3<Float>(native)))
            return WhiteBalance.neutralizing(pre)
        }
    }
}
