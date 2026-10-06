import Foundation
import Metal
import simd

/// What the conversion kernel writes.
public enum OutputStage: Int, Sendable {
    /// Display-linear Rec.2020 positive (after the print curve).
    case positive = 0
    /// Scene-linear Rec.2020 (before the print curve).
    case sceneLinear = 1
    /// Neutral-locked equivalent density (debugging / analysis).
    case density = 2
    /// The negative itself, as the camera saw it (the "before" view), display-linear Rec.2020.
    case negative = 3
}

/// Metal implementation of the negative conversion, on top of the family's shared `MetalContext`
/// (which owns the device, the geometry resampler and the area-average downsampler).
/// All textures are `rgba32Float` (asserted), all math is float32 with precise transcendental functions.
public final class GPUPipeline: @unchecked Sendable {
    public let context: MetalContext
    public var device: MTLDevice { context.device }
    let convertPSO: MTLComputePipelineState
    public static let pixelFormat = MetalContext.pixelFormat

    public static let shared: GPUPipeline? = MetalContext.shared.flatMap { try? GPUPipeline(context: $0) }

    public init(context: MetalContext) throws {
        self.context = context
        convertPSO = try context.pipeline(context.compile(metalKernelSource), "convert")
    }

    // MARK: Textures

    public func makeTexture(width: Int, height: Int) throws -> MTLTexture { try context.makeTexture(width: width, height: height) }
    public func upload(_ image: LinearImage) throws -> MTLTexture { try context.upload(image) }
    public func download(_ t: MTLTexture) -> LinearImage { context.download(t) }
    public func download(_ t: MTLTexture, x: Int, y: Int, width: Int, height: Int) -> LinearImage {
        context.download(t, x: x, y: y, width: width, height: height)
    }

    // MARK: Passes

    /// Geometry (flip / rotate / straighten / crop / scale) and flat-field, in linear camera RGB.
    /// `flatField` is a (small, smooth) per-channel gain map over the sensor.
    public func orient(_ src: MTLTexture, geometry: FrameGeometry, scale: Double = 1, flatField: MTLTexture? = nil) throws -> MTLTexture {
        try context.orient(src, geometry: geometry, scale: scale, flatField: flatField)
    }

    /// Exact area-average downsample to `width` × `height`.
    public func downsample(_ src: MTLTexture, width: Int, height: Int, into existing: MTLTexture? = nil) throws -> MTLTexture {
        try context.downsample(src, width: width, height: height, into: existing)
    }

    public static func uniforms(_ p: ConversionParameters, stage: OutputStage) -> [SIMD4<Float>] {
        let m = p.colorMatrix
        func f3(_ v: SIMD3<Double>, _ w: Double) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w)) }
        return [
            f3(1 / p.filmBase, p.referenceDensity),
            f3(1 / p.calibration.gammaRatio, 1 / p.filmGamma),
            f3(p.calibration.offset, p.monochrome ? 1 : 0),
            f3(p.monochromeWeights, Double(stage.rawValue)),
            f3(m.columns.0, 0), f3(m.columns.1, 0), f3(m.columns.2, 0),
            SIMD4(Float(p.curve.exposure), Float(p.curve.slope), Float(p.curve.y0), Float(p.curve.aHigh)),
            SIMD4(Float(p.curve.aLow), Float(p.curve.kShoulder), Float(p.curve.kToe), Float(0.85 / p.filmBase.max())),
        ] + [f3(p.colourModel.columns.0, 0), f3(p.colourModel.columns.1, 0), f3(p.colourModel.columns.2, 0)] + pathUniforms(p.calibration)
    }

    static func pathUniforms(_ c: FilmCalibration) -> [SIMD4<Float>] {
        guard let p = c.neutral, p.count >= 2 else { return [.zero] }
        let pts = Array(p.prefix(FilmCalibration.maxPathPoints))
        return [SIMD4(Float(pts.count), 0, 0, 0)] + pts.map { SIMD4(Float($0.x + $0.y), Float($0.x + $0.z), Float($0.x), 0) }
    }

    /// The per-pixel negative → positive conversion.
    public func convert(_ src: MTLTexture, parameters: ConversionParameters, stage: OutputStage = .positive, into dst: MTLTexture? = nil) throws -> MTLTexture {
        let out = try dst ?? makeTexture(width: src.width, height: src.height)
        try context.run { context.encode($0, convertPSO, textures: [src, out], uniforms: Self.uniforms(parameters, stage: stage), size: (out.width, out.height)) }
        return out
    }
}
