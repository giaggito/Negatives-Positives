import Foundation
import simd

/// Double exposure: where a layer lies on the photo, and how its light combines with the photo's.
///
/// Layers are composited first, before anything else is developed — in scene light, as linear Rec.2020 at
/// the photo's "as shot" white balance — so white balance, exposure, local tone, film, grain and everything
/// after act on the double exposure as one picture, as they would on a double-exposed negative.
///
/// A layer pixel l (native values of the layer's file) becomes scene light in the photo's units:
///     l' = 2^(EV_layer + baseline_layer − baseline_photo) · M_layer(white balance) · l
/// (display-referred files are first taken out of their display shoulder). With k = amount × mask × coverage
/// and the photo's pixel b, the blend is:
///     film      b·(1 − k/2) + l'·k/2                 (two exposures, half each)
///     screen    mix(b, S⁻¹(1 − (1 − S(b))(1 − S(l'))), k),  S(x) = x·d / (1 + x·d)
///     lighten   mix(b, max(b, l'), k)          darken  mix(b, min(b, l'), k)
///     multiply  mix(b, b · l'·d, k)            normal  mix(b, l', k)
/// where d = 2^baseline_photo brings scene light to display units (white ≈ 1).
public enum LayerMath {
    /// The facts about a layer's file that placement and colour need.
    public struct Frame: Sendable, Equatable {
        public var fullWidth: Int, fullHeight: Int
        public var orientation: FrameGeometry
        public init(fullWidth: Int, fullHeight: Int, orientation: FrameGeometry) {
            self.fullWidth = fullWidth; self.fullHeight = fullHeight; self.orientation = orientation
        }
        public init(_ s: SourceImage) { self.init(fullWidth: s.fullSize.width, fullHeight: s.fullSize.height, orientation: s.defaultGeometry) }
        /// Upright size (as the layer's photo is normally seen).
        public var upright: (width: Int, height: Int) { orientation.orientedSize(sourceWidth: fullWidth, sourceHeight: fullHeight) }
    }

    @inline(__always) static func flipMatrix(_ f: Bool) -> simd_double2x2 { simd_double2x2(diagonal: [f ? -1 : 1, 1]) }

    /// Photo sensor px (full quality) -> the layer's texture coordinates (0…1 over its sensor image).
    public static func sensorToLayerUV(_ layer: PhotoLayer, frame: Frame, photoSensor: (width: Int, height: Int)) -> Affine2D {
        let L = Double(max(photoSensor.width, photoSensor.height))
        let up = frame.upright
        let Ll = Double(max(up.width, up.height))
        let a = layer.angle * .pi / 180
        // s (normalised) = c + size · R(a) · F · q   =>   q = F · R(−a) · (s − c) / size
        let toQ = Affine2D(m: flipMatrix(layer.flip), t: .zero)
            .concatenating(.rotation(radians: -a))
            .concatenating(.scale(1 / max(layer.size, 1e-6)))
            .concatenating(.translation([-layer.center.x, -layer.center.y]))
            .concatenating(.scale(1 / L))
        let toUpright = Affine2D.translation([Double(up.width) / 2, Double(up.height) / 2]).concatenating(.scale(Ll))
        let toLayerSensor = frame.orientation.outputToSource(sourceWidth: frame.fullWidth, sourceHeight: frame.fullHeight)
        let toUV = Affine2D(m: simd_double2x2(diagonal: [1 / Double(frame.fullWidth), 1 / Double(frame.fullHeight)]), t: .zero)
        return toUV.concatenating(toLayerSensor).concatenating(toUpright).concatenating(toQ)
    }

    /// The rotation (degrees) and mirroring of the photo's sensor as it is shown with `geometry`.
    static func screenFrame(_ geometry: FrameGeometry, photoSensor: (width: Int, height: Int)) -> (angle: Double, flip: Bool) {
        let s = geometry.outputToSource(sourceWidth: photoSensor.width, sourceHeight: photoSensor.height).m
        let flip = simd_determinant(s) < 0
        let r = s * flipMatrix(flip)
        return (atan2(r.columns.0.y, r.columns.0.x) * 180 / .pi, flip)
    }

    /// A placement that shows the layer upright and centred on the photo as it is framed now, covering the
    /// whole frame (`fill`) or fitting inside it.
    public static func place(_ layer: PhotoLayer, frame: Frame, photoSensor: (width: Int, height: Int), geometry: FrameGeometry,
                             fill: Bool = true) -> PhotoLayer {
        var l = layer
        let out = geometry.outputSize(sourceWidth: photoSensor.width, sourceHeight: photoSensor.height)
        let up = frame.upright
        let sw = Double(out.width) / Double(up.width), sh = Double(out.height) / Double(up.height)
        let sigma = fill ? max(sw, sh) : min(sw, sh)                     // output px per layer upright px
        let L = Double(max(photoSensor.width, photoSensor.height))
        let s = geometry.outputToSource(sourceWidth: photoSensor.width, sourceHeight: photoSensor.height)
        let c = s.apply([Double(out.width) / 2, Double(out.height) / 2]) / L
        let f = screenFrame(geometry, photoSensor: photoSensor)
        l.center = MaskPoint(c.x, c.y)
        l.size = sigma * Double(max(up.width, up.height)) / L
        l.angle = f.angle
        l.flip = f.flip
        return l
    }

    /// The layer's rotation as seen on screen (degrees, −180…180) and back.
    public static func screenAngle(_ layer: PhotoLayer, geometry: FrameGeometry, photoSensor: (width: Int, height: Int)) -> Double {
        let f = screenFrame(geometry, photoSensor: photoSensor)
        var a = (layer.angle - f.angle) * (f.flip ? -1 : 1)
        a = (a + 180).truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        return a - 180
    }
    public static func sensorAngle(screen: Double, geometry: FrameGeometry, photoSensor: (width: Int, height: Int)) -> Double {
        let f = screenFrame(geometry, photoSensor: photoSensor)
        return f.angle + screen * (f.flip ? -1 : 1)
    }
    /// Whether the layer looks mirrored on screen.
    public static func screenFlip(_ layer: PhotoLayer, geometry: FrameGeometry, photoSensor: (width: Int, height: Int)) -> Bool {
        layer.flip != screenFrame(geometry, photoSensor: photoSensor).flip
    }

    /// The layer's white balance: its own, shifted like a mask's (±100 = ±50 mired / ±60 tint).
    public static func whiteBalance(_ layer: PhotoLayer, asShot wb: WhiteBalance) -> WhiteBalance {
        guard layer.temperature != 0 || layer.tint != 0 else { return wb }
        let mired = 1e6 / wb.temperature - layer.temperature * 0.5
        let t = min(max(1e6 / max(mired, 50), WhiteBalance.temperatureRange.lowerBound), WhiteBalance.temperatureRange.upperBound)
        return WhiteBalance(temperature: t, tint: wb.tint + layer.tint * 0.6)
    }

    /// Layer native values -> scene light in the photo's units (linear Rec.2020, before the photo's exposure).
    public static func colourMatrix(_ layer: PhotoLayer, layerSource s: SourceImage, photoBaseline: Double) -> simd_float3x3 {
        let m = s.inputMatrix(whiteBalance: whiteBalance(layer, asShot: s.asShotWhiteBalance))
        return simd_float3x3(m * pow(2, layer.exposure + s.baselineExposure - photoBaseline))
    }

    // MARK: Blend (CPU reference of `layer_blend`)

    @inline(__always) static func compress(_ x: SIMD3<Float>) -> SIMD3<Float> { let p = simd_max(x, .zero); return p / (1 + p) }

    public static func blend(_ b: SIMD3<Float>, _ l: SIMD3<Float>, k: Float, mode: Int, display d: Float) -> SIMD3<Float> {
        guard k > 0 else { return b }
        let l = simd_max(l, .zero)
        switch mode {
        case 0: return b * (1 - 0.5 * k) + l * (0.5 * k)
        case 1:
            let r = simd_min(1 - (1 - compress(b * d)) * (1 - compress(l * d)), SIMD3(repeating: 0.9999))
            return simd_mix(b, r / (1 - r) / d, SIMD3(repeating: k))
        case 2: return simd_mix(b, simd_max(b, l), SIMD3(repeating: k))
        case 3: return simd_mix(b, simd_min(b, l), SIMD3(repeating: k))
        case 4: return simd_mix(b, b * l * d, SIMD3(repeating: k))
        default: return simd_mix(b, l, SIMD3(repeating: k))
        }
    }
}
