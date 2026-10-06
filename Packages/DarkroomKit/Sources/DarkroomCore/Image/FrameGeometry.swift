import CoreGraphics
import Foundation
import simd

/// 2D affine map `p' = M·p + t` in Double precision.
public struct Affine2D: Equatable, Sendable {
    public var m: simd_double2x2
    public var t: SIMD2<Double>

    public static let identity = Affine2D(m: matrix_identity_double2x2, t: .zero)

    public init(m: simd_double2x2, t: SIMD2<Double>) { self.m = m; self.t = t }

    public func apply(_ p: SIMD2<Double>) -> SIMD2<Double> { m * p + t }
    /// self ∘ other  (apply `other` first).
    public func concatenating(_ other: Affine2D) -> Affine2D { Affine2D(m: m * other.m, t: m * other.t + t) }
    public var inverse: Affine2D { let mi = m.inverse; return Affine2D(m: mi, t: -(mi * t)) }

    public static func translation(_ v: SIMD2<Double>) -> Affine2D { Affine2D(m: matrix_identity_double2x2, t: v) }
    public static func scale(_ s: Double) -> Affine2D { Affine2D(m: simd_double2x2(diagonal: [s, s]), t: .zero) }
    public static func rotation(radians a: Double) -> Affine2D {
        Affine2D(m: simd_double2x2(columns: ([cos(a), sin(a)], [-sin(a), cos(a)])), t: .zero)
    }
}

/// How a frame is oriented and cropped. All coordinates are continuous pixel coordinates with pixel
/// centres at +0.5, y pointing down.
///
/// Order of operations, sensor → output:
///   1. flips in sensor space (a negative may be shot emulsion-up),
///   2. quarter turns clockwise,
///   3. fine straightening by `straighten` degrees (positive = counter-clockwise) about the image centre,
///      keeping the canvas size,
///   4. crop, given as a rectangle normalised to the canvas of step 3.
public struct FrameGeometry: Codable, Equatable, Sendable {
    public var quarterTurns: Int = 0
    public var flipHorizontal = false
    public var flipVertical = false
    public var straighten: Double = 0
    /// Normalised crop (x, y, width, height) in the oriented canvas.
    public var crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    public init(quarterTurns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false,
                straighten: Double = 0, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        self.quarterTurns = quarterTurns
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.straighten = straighten
        self.crop = crop
    }

    var turns: Int { ((quarterTurns % 4) + 4) % 4 }

    /// Size of the oriented canvas (after flips and quarter turns).
    public func orientedSize(sourceWidth w: Int, sourceHeight h: Int) -> (width: Int, height: Int) {
        turns % 2 == 0 ? (w, h) : (h, w)
    }

    /// Output size in pixels at full resolution.
    public func outputSize(sourceWidth w: Int, sourceHeight h: Int) -> (width: Int, height: Int) {
        let o = orientedSize(sourceWidth: w, sourceHeight: h)
        let cw = max(1, Int((crop.width * Double(o.width)).rounded()))
        let ch = max(1, Int((crop.height * Double(o.height)).rounded()))
        return (cw, ch)
    }

    /// Maps output pixel coordinates (at `scale` output pixels per source pixel) to source coordinates.
    public func outputToSource(sourceWidth w: Int, sourceHeight h: Int, scale: Double = 1) -> Affine2D {
        let W = Double(w), H = Double(h)
        let o = orientedSize(sourceWidth: w, sourceHeight: h)
        let OW = Double(o.width), OH = Double(o.height)
        // output -> canvas. The crop origin snaps to whole pixels so a plain crop never resamples.
        let toCanvas = Affine2D.translation([(crop.minX * OW).rounded(), (crop.minY * OH).rounded()]).concatenating(.scale(1 / scale))
        // canvas -> oriented (undo straightening: rotate by −θ about the centre; y-down so CCW on screen = −angle here)
        let c = SIMD2(OW / 2, OH / 2)
        let theta = straighten * .pi / 180
        let unStraighten = Affine2D.translation(c).concatenating(.rotation(radians: theta)).concatenating(.translation(-c))
        // oriented -> flipped sensor (undo quarter turns)
        let unTurn: Affine2D
        switch turns {
        case 1: unTurn = Affine2D(m: simd_double2x2(columns: ([0, -1], [1, 0])), t: [0, H])      // x = y', y = H − x'
        case 2: unTurn = Affine2D(m: simd_double2x2(diagonal: [-1, -1]), t: [W, H])
        case 3: unTurn = Affine2D(m: simd_double2x2(columns: ([0, 1], [-1, 0])), t: [W, 0])      // x = W − y', y = x'
        default: unTurn = .identity
        }
        // flipped sensor -> sensor
        let unFlip = Affine2D(m: simd_double2x2(diagonal: [flipHorizontal ? -1 : 1, flipVertical ? -1 : 1]),
                              t: [flipHorizontal ? W : 0, flipVertical ? H : 0])
        return unFlip.concatenating(unTurn).concatenating(unStraighten).concatenating(toCanvas)
    }

    /// True when every output pixel centre lands exactly on a source pixel centre (no resampling needed).
    public func isPixelExact(scale: Double = 1, sourceWidth w: Int, sourceHeight h: Int) -> Bool {
        guard straighten == 0, scale == 1 else { return false }
        let a = outputToSource(sourceWidth: w, sourceHeight: h)
        let p = a.apply([0.5, 0.5])
        return abs(p.x - 0.5 - (p.x - 0.5).rounded()) < 1e-9 && abs(p.y - 0.5 - (p.y - 0.5).rounded()) < 1e-9
    }
}
