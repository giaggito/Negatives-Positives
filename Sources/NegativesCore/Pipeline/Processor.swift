import CoreGraphics
import Foundation
import Metal
import simd

/// A decoded frame ready for analysis and rendering.
public final class DecodedFrame: @unchecked Sendable {
    public let url: URL
    public let raw: RawImage
    private var texture: MTLTexture?

    public init(url: URL, raw: RawImage) {
        self.url = url
        self.raw = raw
    }

    public static func decode(_ url: URL, quality: DemosaicQuality = .best) throws -> DecodedFrame {
        DecodedFrame(url: url, raw: try RawDecoder.decodeAny(url: url, quality: quality))
    }

    func sourceTexture(_ gpu: GPUPipeline) throws -> MTLTexture {
        if let texture { return texture }
        let t = try gpu.upload(raw.image)
        texture = t
        return t
    }
}

/// High-level operations shared by the command-line tool and the app.
public final class Processor: @unchecked Sendable {
    public let gpu: GPUPipeline
    public var flat: FlatField?
    private var flatTexture: MTLTexture?

    public init(flat: FlatField? = nil) throws {
        guard let gpu = GPUPipeline.shared else { throw GPUError.noDevice }
        self.gpu = gpu
        self.flat = flat
        if let flat { flatTexture = try gpu.upload(flat.gain) }
    }

    // MARK: Measurement

    /// Measures the film base (rectangle median, or automatic) and stores it in the roll settings.
    @discardableResult
    public static func measureFilmBase(_ proxy: AnalysisProxy, file: String, rect: CGRect?, roll: inout RollSettings) -> Bool {
        let m: Estimators.FilmBaseMeasurement?
        if let rect {
            m = Estimators.filmBase(samples: proxy.samples(inNormalizedRect: rect), clipLevel: proxy.clipLevel)
        } else {
            m = Estimators.autoFilmBase(cells: proxy.cellMedians(), clipLevel: proxy.clipLevel, colorFilm: !roll.monochrome)
        }
        guard let m else { return false }
        roll.filmBase = m.base
        roll.filmBaseClipped = m.clippedFraction
        roll.filmBaseSource = .init(file: file, rect: rect)
        return true
    }

    /// Measures a frame's statistics (`FrameStats`) on its picture, inside its crop.
    public static func measureAnchors(_ proxy: AnalysisProxy, roll: RollSettings, settings: inout FrameSettings) {
        guard let base = roll.filmBase else { return }
        let colour = !(settings.monochrome ?? roll.monochrome)
        let picture = FrameDetector.detect(proxy, base: base, colorFilm: colour).map(\.rect)
        let s = proxy.pictureDensities(geometry: settings.geometry, base: base, picture: picture, colorFilm: colour)
        settings.stats = Estimators.frameStats(densities: s.densities, centreWeights: s.weights, picture: picture)
    }

    /// Pools the frames' statistics into the roll calibration and exposure reference.
    public static func analyzeRoll(_ roll: inout RollSettings, frames: [FrameSettings]) {
        let stats = frames.compactMap(\.stats)
        roll.version = RollSettings.currentVersion
        guard !stats.isEmpty else { return }
        let cal = roll.monochrome ? .identity : Estimators.rollCalibration(stats: stats)
        roll.calibration = cal
        roll.referenceDensity = Estimators.rollReferenceDensity(stats: stats, cal, filmGamma: roll.filmGamma)
    }

    // MARK: Rendering

    /// Renders a frame at `scale` (1 = full resolution). Preview and export both come through here.
    public func render(_ frame: DecodedFrame, roll: RollSettings, settings: FrameSettings,
                       stage: OutputStage = .positive, scale: Double = 1, audit: ((StageAudit) -> Void)? = nil) throws -> LinearImage {
        let params = try ConversionParameters.resolve(roll: roll, frame: settings, cameraToRec2020: frame.raw.cameraToRec2020)
        let src = try frame.sourceTexture(gpu)
        let oriented = try gpu.orient(src, geometry: settings.geometry, scale: scale, flatField: flatTexture)
        if let audit { audit(StageAudit.audit(gpu.download(oriented), name: "camera RGB")) }
        let out = try gpu.convert(oriented, parameters: params, stage: stage)
        let img = gpu.download(out)
        if let audit {
            if stage == .positive {
                audit(StageAudit.audit(gpu.download(try gpu.convert(oriented, parameters: params, stage: .density)), name: "density"))
                audit(StageAudit.audit(gpu.download(try gpu.convert(oriented, parameters: params, stage: .sceneLinear)), name: "scene linear"))
            }
            audit(StageAudit.audit(img, name: stage == .positive ? "positive" : "output"))
        }
        return img
    }

    /// Screen preview: the full-resolution render, area-averaged down to fit `maxSize`. Because it is
    /// literally the export image downsampled, preview and export colours are identical by construction.
    public func preview(_ frame: DecodedFrame, roll: RollSettings, settings: FrameSettings, maxSize: Int) throws -> LinearImage {
        let params = try ConversionParameters.resolve(roll: roll, frame: settings, cameraToRec2020: frame.raw.cameraToRec2020)
        let src = try frame.sourceTexture(gpu)
        let oriented = try gpu.orient(src, geometry: settings.geometry, flatField: flatTexture)
        let full = try gpu.convert(oriented, parameters: params)
        let s = min(1, Double(maxSize) / Double(max(full.width, full.height)))
        guard s < 1 else { return gpu.download(full) }
        return gpu.download(try gpu.downsample(full, width: max(1, Int((Double(full.width) * s).rounded())),
                                               height: max(1, Int((Double(full.height) * s).rounded()))))
    }
}
