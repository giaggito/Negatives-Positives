import CoreGraphics
import Foundation
import Metal
import simd

/// What part of the picture to render, in output pixels of the full-quality image (after geometry).
public struct ViewRequest: Equatable, Sendable {
    /// Region of the output image, in full-resolution output pixels.
    public var region: CGRect
    /// Render pixels per full-resolution pixel (≤ 1; magnified views are rendered at 1 and enlarged on screen).
    public var scale: Double
    /// false: fast path (input averaged from a pyramid level, effects evaluated at render resolution).
    /// true: computed at full resolution and area-averaged — exactly the export, smaller.
    public var exact: Bool

    public init(region: CGRect, scale: Double, exact: Bool) {
        self.region = region
        self.scale = scale
        self.exact = exact
    }
}

/// A rendered piece of the picture: display-linear Rec.2020, rgba32Float.
public struct RenderedView: @unchecked Sendable {
    public let texture: MTLTexture
    /// Output-pixel coordinates of the texture's top-left corner and its scale (texture px per output px).
    public let origin: CGPoint
    public let scale: Double
    public let exact: Bool
    public let histogram: Histogram?
}

public struct Histogram: Sendable, Equatable {
    public var bins: [SIMD3<Float>]
    /// Fraction of pixels crushed to black (every channel ≤ 1/4096) / with a channel at or above 1, in the output space.
    public var shadowClip: Double
    public var highlightClip: Double
    public static let empty = Histogram(bins: [], shadowClip: 0, highlightClip: 0)
}

/// The editor's GPU renderer for one photograph at a time. Not thread-safe: use from one serial queue.
///
/// Caches (each rebuilt only when its inputs change):
/// - source texture (per photo),
/// - oriented full-resolution image + area-average pyramid (per geometry),
/// - coarse maps: guided-filter coefficients for the large-scale base (highlights / shadows), the
///   mid-scale base (clarity) and the dehaze transmission (per white balance),
/// - view input + fine blur (per visible region and scale).
/// A slider that only changes per-pixel parameters therefore costs one `develop` pass over the visible
/// pixels. Each frame is one command buffer.
///
/// Resolution independence: every neighbourhood size is a fraction of the image's long side, and the
/// coarse maps are computed once from the full-resolution pyramid, so preview and export use the same maps.
/// The coarse maps are guided-filter coefficients computed at low resolution and applied with the
/// full-resolution guide (He & Sun's fast guided filter), so edges stay pixel-sharp.
public final class RenderEngine {
    public let context: MetalContext
    let fetchPSO, loglumPSO, gaussPSO, boxPSO, minPSO, gfPrepPSO, gfCoefPSO, darkPSO, developPSO, histPSO, intoPSO: MTLComputePipelineState
    let noisePSO, grainBoolPSO, grainCellsPSO, glowPSO, combinePSO: MTLComputePipelineState
    let maskEvalPSO, brushSegPSO, brushCompPSO, maskBlitPSO, maskClearPSO, maskCopyPSO, texClearPSO, layerPSO: MTLComputePipelineState
    var maskState = MaskGPUState()
    var layerState = LayerGPUState()
    let dummy: MTLTexture
    let dummyBuffer: MTLBuffer

    public private(set) var source: SourceImage?
    private var sourceTexture: MTLTexture?
    private var sourcePyramid: [MTLTexture] = []
    private(set) var orientedGeometry: FrameGeometry?
    /// [0] = oriented at source resolution: the photo, or the photo with its layers composited.
    var pyramid: [MTLTexture] = []

    private struct MapsKey: Equatable { var geometry: FrameGeometry; var matrix: simd_float3x3; var unrender: Bool }
    private var baseKey: MapsKey?, midKey: MapsKey?, darkKey: MapsKey?
    private var baseCoef: MTLTexture?, midCoef: MTLTexture?, darkCoef: MTLTexture?
    /// Atmospheric light before white balance (un-rendered native), per geometry.
    private var airlightNative: SIMD3<Float>?

    private struct ViewKey: Equatable {
        var region: CGRect; var scale: Double; var geometry: FrameGeometry; var interactiveGeometry: Bool; var proxy: Bool
    }
    private struct FineKey: Equatable { var view: ViewKey; var matrix: simd_float3x3; var unrender: Bool; var sigma: Float }
    /// Per-slot view caches (e.g. slot 0 = the visible region, slot 1 = the whole-picture overview), so
    /// alternating between them never refetches.
    private struct NoiseKey: Equatable { var view: ViewKey; var seed: UInt32; var field: GrainRender.Field; var layers: Int }
    private struct SoftKey: Equatable { var view: ViewKey; var sigma: Double }
    private struct ViewCache {
        var key: ViewKey?
        var input: MTLTexture?
        var fineKey: FineKey?
        var fine: MTLTexture?
        var noiseKey: NoiseKey?
        var noise: (MTLTexture, MTLTexture)?
        var softKey: SoftKey?
        var soft: MTLTexture?
        var outputs: [MTLTexture] = []
        var outputIndex = 0
        var masks: (MaskKey, MTLTexture)?
        var grainNorm: (Float, Float, Float) = (1, 1, 0)
    }
    private var views: [Int: ViewCache] = [:]
    private var scratch: [String: MTLTexture] = [:]
    private var curveLUT: (data: [SIMD4<Float>], texture: MTLTexture)?
    private var filmRes: (film: PreparedFilm, elut: MTLTexture, curves: MTLTexture, paper: MTLTexture, spec: MTLBuffer)?
    private struct GlowKey: Equatable {
        var geometry: FrameGeometry; var matrix: simd_float3x3; var unrender: Bool; var gain: Float
        var threshold: Float; var radius: Double
        var film: ObjectIdentifier?; var look: String?; var filmGain: Float
    }
    /// Bloom depends on exposure (threshold); halation is linear in exposure and is scaled in `develop`.
    private var glowKey: GlowKey?, halKey: GlowKey?
    private var lookTexture: (key: String, texture: MTLTexture)?
    let dummy3D: MTLTexture
    private var bloomMap: MTLTexture?, halMap: MTLTexture?
    private let histBuffer: MTLBuffer

    public init(context: MetalContext) throws {
        self.context = context
        let lib = try context.compile(positivesKernelSource + resampleIntoSource)
        func p(_ n: String) throws -> MTLComputePipelineState { try context.pipeline(lib, n) }
        fetchPSO = try p("fetch"); loglumPSO = try p("loglum"); gaussPSO = try p("gauss"); boxPSO = try p("boxmean")
        minPSO = try p("minfilter"); gfPrepPSO = try p("gf_prep"); gfCoefPSO = try p("gf_coef"); darkPSO = try p("darkchannel")
        developPSO = try p("develop"); histPSO = try p("histogram"); intoPSO = try p("resample_into")
        noisePSO = try p("grain_noise"); grainBoolPSO = try p("grain_boolean"); grainCellsPSO = try p("grain_cells"); glowPSO = try p("glow_source"); combinePSO = try p("combine3")
        maskEvalPSO = try p("mask_eval"); brushSegPSO = try p("brush_segments"); brushCompPSO = try p("brush_composite")
        maskBlitPSO = try p("mask_blit"); maskClearPSO = try p("mask_clear"); maskCopyPSO = try p("mask_copy"); texClearPSO = try p("tex_clear")
        layerPSO = try p("layer_composite")
        dummy = try context.makeTexture(width: 1, height: 1)
        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D; d3.pixelFormat = .rgba32Float; d3.width = 2; d3.height = 2; d3.depth = 2; d3.usage = .shaderRead
        guard let t3 = context.device.makeTexture(descriptor: d3) else { throw GPUError.allocation("3D") }
        dummy3D = t3
        guard let db = context.device.makeBuffer(length: 205 * 16, options: .storageModeShared) else { throw GPUError.allocation("film") }
        dummyBuffer = db
        guard let b = context.device.makeBuffer(length: 771 * 4, options: .storageModeShared) else { throw GPUError.allocation("histogram") }
        histBuffer = b
    }

    // MARK: Source & geometry

    public func setSource(_ s: SourceImage) throws {
        if source === s { return }
        releaseAll()
        source = s
        sourceTexture = try context.upload(s.image)
    }

    public func releaseAll() {
        source = nil; sourceTexture = nil; sourcePyramid = []; pyramid = []; orientedGeometry = nil
        baseKey = nil; midKey = nil; darkKey = nil; baseCoef = nil; midCoef = nil; darkCoef = nil; airlightNative = nil
        glowKey = nil; halKey = nil; bloomMap = nil; halMap = nil
        views = [:]; scratch = [:]
        maskState = MaskGPUState()
        layerState.base = []; layerState.key = nil
    }

    /// Full-quality output size for a geometry.
    public func outputSize(_ g: FrameGeometry) -> CGSize {
        guard let s = source else { return .zero }
        let o = g.outputSize(sourceWidth: s.fullSize.width, sourceHeight: s.fullSize.height)
        return CGSize(width: o.width, height: o.height)
    }

    /// Source-resolution pixels per full-quality pixel (0.5 for a half-size proxy).
    var sourceScale: Double {
        guard let s = source else { return 1 }
        return Double(s.image.width) / Double(s.fullSize.width)
    }

    private func ensureOriented(_ g: FrameGeometry) throws {
        guard let src = sourceTexture else { throw GPUError.allocation("no source") }
        if orientedGeometry == g, !pyramid.isEmpty { return }
        pyramid = []
        let o = try context.orient(src, geometry: g, emptyOutside: true)
        pyramid = try buildPyramid(o)
        orientedGeometry = g
        layerState.base = []; layerState.key = nil
        invalidateDerived()
    }

    /// Forgets everything computed from the oriented picture (after it changed).
    func invalidateDerived() {
        baseKey = nil; midKey = nil; darkKey = nil; airlightNative = nil; glowKey = nil; halKey = nil
        for k in views.keys {
            views[k]?.key = nil; views[k]?.fineKey = nil; views[k]?.noiseKey = nil; views[k]?.softKey = nil; views[k]?.masks = nil
        }
    }

    func buildPyramid(_ base: MTLTexture) throws -> [MTLTexture] {
        var levels = [base]
        try context.run { enc in
            var cur = base
            while max(cur.width, cur.height) > 64 {
                let n = try context.makeTexture(width: max(1, cur.width / 2), height: max(1, cur.height / 2))
                context.encodeDownsample(enc, src: cur, dst: n,
                                         region: CGRectLike(x: 0, y: 0, width: Double(n.width * 2), height: Double(n.height * 2)))
                levels.append(n)
                cur = n
            }
        }
        return levels
    }

    private func ensureSourcePyramid() throws {
        guard sourcePyramid.isEmpty, let src = sourceTexture else { return }
        sourcePyramid = try buildPyramid(src)
    }

    private func scratchTexture(_ name: String, _ w: Int, _ h: Int, _ format: MTLPixelFormat = .rgba32Float) throws -> MTLTexture {
        let key = "\(name)-\(w)x\(h)-\(format.rawValue)"
        if let t = scratch[key] { return t }
        let t = try context.makeTexture(width: w, height: h, format: format, gpuOnly: true)
        scratch[key] = t
        return t
    }

    // MARK: Coarse maps

    /// Pyramid level for the clarity map: the first with a long side below 1024 px. The highlight / shadow
    /// base and the dehaze map use the level below it (their neighbourhoods are 3× larger).
    private var levelMid: Int {
        var k = 0
        while k < pyramid.count - 1, max(pyramid[k].width, pyramid[k].height) >= 1024 { k += 1 }
        return k
    }
    private var levelBase: Int { min(pyramid.count - 1, levelMid + 1) }

    private func long(_ t: MTLTexture) -> Double { Double(max(t.width, t.height)) }

    private func encodeMaps(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters) throws {
        let key = MapsKey(geometry: orientedGeometry!, matrix: p.inputMatrix, unrender: p.unrender)
        let u = matrixUniforms(p)
        if p.needsLocal, baseKey != key {
            let lvl = pyramid[levelBase]
            baseCoef = try encodeGuided(enc, name: "base", level: lvl, input: nil, radius: Int((0.035 * long(lvl)).rounded()), eps: 0.3, u: u)
            baseKey = key
        }
        if p.needsMidMap, midKey != key {
            let lvl = pyramid[levelMid]
            midCoef = try encodeGuided(enc, name: "mid", level: lvl, input: nil, radius: Int((0.012 * long(lvl)).rounded()), eps: 0.12, u: u)
            midKey = key
        }
        if p.needsDarkMap, darkKey != key {
            let lvl = pyramid[levelBase]
            let w = lvl.width, h = lvl.height
            let dark = try scratchTexture("dark", w, h, .r32Float)
            let t1 = try scratchTexture("dark1", w, h, .r32Float)
            let r = Float(max(1, Int((0.008 * long(lvl)).rounded())))
            var du = u
            du.append(SIMD4(airlight(p), 0))
            context.encode(enc, darkPSO, textures: [lvl, dark], uniforms: du, size: (w, h))
            context.encode(enc, minPSO, textures: [dark, t1], uniforms: [SIMD4(r, 1, 0, 0)], size: (w, h))
            context.encode(enc, minPSO, textures: [t1, dark], uniforms: [SIMD4(r, 0, 1, 0)], size: (w, h))
            darkCoef = try encodeGuided(enc, name: "dark", level: lvl, input: dark, radius: Int((0.03 * long(lvl)).rounded()), eps: 0.02, u: u)
            darkKey = key
        }
    }

    /// Micrometres of film per full-quality pixel: the film frame (format) spans the uncropped picture.
    func micronsPerPixel(_ p: DevelopParameters) -> Double {
        guard let s = source else { return 5.8 }
        let frame = (p.grain?.frameLongSideMM ?? 36) * 1000
        return frame / Double(max(s.fullSize.width, s.fullSize.height))
    }

    /// Bloom and halation maps at coarse pyramid levels (both are smooth, wide glows).
    private func encodeGlow(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters) throws {
        guard p.hasBloom || p.hasHalation else { bloomMap = nil; halMap = nil; return }
        let res = p.film.flatMap { try? filmResources($0) }
        let fullLong = long(pyramid[0]) / sourceScale
        func level(forSigma sigmaFull: Double) -> (MTLTexture, Double) {
            var k = 0
            while k + 1 < pyramid.count, sigmaFull * sourceScale / pow(2, Double(k)) > 2.5 { k += 1 }
            return (pyramid[k], sigmaFull * sourceScale / pow(2, Double(k)))
        }
        let u = matrixUniforms(p)
        func blur(_ src: MTLTexture, _ dst: MTLTexture, _ tmp: MTLTexture, _ sigma: Double) {
            let r = Float(Int(ceil(3 * sigma)))
            context.encode(enc, gaussPSO, textures: [src, tmp], uniforms: [SIMD4(Float(sigma), r, 1, 0)], size: (src.width, src.height))
            context.encode(enc, gaussPSO, textures: [tmp, dst], uniforms: [SIMD4(Float(sigma), r, 0, 1)], size: (src.width, src.height))
        }
        if p.hasBloom {
            let key = GlowKey(geometry: orientedGeometry!, matrix: p.inputMatrix, unrender: p.unrender, gain: p.exposureGain,
                              threshold: p.bloomThreshold, radius: p.bloomRadius, film: nil, look: nil, filmGain: 1)
            if glowKey != key || bloomMap == nil {
                glowKey = key
                // Two-scale glow: a core of σ and a wider halo of 3σ (cascaded Gaussians).
                let (lvl, sigma) = level(forSigma: p.bloomRadius * fullLong)
                let w = lvl.width, h = lvl.height
                let src = try scratchTexture("glowSrc", w, h), t = try scratchTexture("glowTmp", w, h)
                let b1 = try scratchTexture("bloom1", w, h), b2 = try scratchTexture("bloom2", w, h)
                let out = try scratchTexture("bloomMap", w, h)
                context.encode(enc, glowPSO, textures: [lvl, res?.elut ?? dummy, src], uniforms: u + [SIMD4(p.exposureGain, p.bloomThreshold, 1, 1)], size: (w, h))
                blur(src, b1, t, max(0.5, sigma))
                blur(b1, b2, t, max(0.5, sigma * 8.0.squareRoot()))
                context.encode(enc, combinePSO, textures: [b1, b2, b2, out], uniforms: [SIMD4(0.6, 0.4, 0, 0)], size: (w, h))
                bloomMap = out
            }
        } else { bloomMap = nil; glowKey = nil }
        if p.hasHalation, p.look != nil || res != nil {
            // Computed at exposure gain 1 (the develop kernel scales it): the drag of exposure reuses it.
            let key = GlowKey(geometry: orientedGeometry!, matrix: p.inputMatrix, unrender: p.unrender, gain: 1, threshold: 0,
                              radius: p.halationRadius, film: p.film.map(ObjectIdentifier.init), look: p.look?.key, filmGain: p.film?.gain ?? 1)
            if halKey != key || halMap == nil {
                halKey = key
                // Back-reflection halation: bounces at σ√k, each half as strong as the last.
                let (lvl, sigma) = level(forSigma: p.halationRadius / micronsPerPixel(p))
                let w = lvl.width, h = lvl.height
                let src = try scratchTexture("halSrc", w, h), t = try scratchTexture("halTmp", w, h)
                let b1 = try scratchTexture("hal1", w, h), b2 = try scratchTexture("hal2", w, h), b3 = try scratchTexture("hal3", w, h)
                let out = try scratchTexture("halMap", w, h)
                // mode 2: film exposure (physical film); mode 3: scene light (film looks).
                let mode: Float = p.look != nil ? 3 : 2
                context.encode(enc, glowPSO, textures: [lvl, res?.elut ?? dummy, src], uniforms: u + [SIMD4(1, 0, p.film?.gain ?? 1, mode)], size: (w, h))
                let s1 = max(0.5, sigma)
                blur(src, b1, t, s1)
                blur(b1, b2, t, s1)
                blur(b2, b3, t, s1)
                context.encode(enc, combinePSO, textures: [b1, b2, b3, out], uniforms: [SIMD4(1, 0.5, 0.25, 0)], size: (w, h))
                halMap = out
            }
        } else { halMap = nil; halKey = nil }
    }

    /// The film look's colour table as a 3D texture.
    private func lookResource(_ l: LookRender) throws -> MTLTexture {
        if let t = lookTexture, t.key == l.key { return t.texture }
        let n = l.table.size
        let d = MTLTextureDescriptor()
        d.textureType = .type3D; d.pixelFormat = .rgba32Float; d.width = n; d.height = n; d.depth = n; d.usage = .shaderRead
        guard let t = context.device.makeTexture(descriptor: d) else { throw GPUError.allocation("look") }
        l.table.values.withUnsafeBytes {
            t.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                      bytesPerRow: n * 16, bytesPerImage: n * n * 16)
        }
        lookTexture = (l.key, t)
        return t
    }

    /// GPU copies of a prepared film's tables.
    private func filmResources(_ f: PreparedFilm) throws -> (film: PreparedFilm, elut: MTLTexture, curves: MTLTexture, paper: MTLTexture, spec: MTLBuffer) {
        if let r = filmRes, r.film === f { return r }
        let g = SpectralUpsampling.gridSize
        let elut = try context.makeTexture(width: g, height: g)
        f.exposureLUT.withUnsafeBytes { elut.replace(region: MTLRegionMake2D(0, 0, g, g), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: g * 16) }
        let n = f.curve.count
        let curves = try context.makeTexture(width: n, height: 2)
        (f.curve + f.preCouplerCurve).withUnsafeBytes { curves.replace(region: MTLRegionMake2D(0, 0, n, 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 16) }
        let pc = f.paperCurve.isEmpty ? [SIMD4<Float>](repeating: .zero, count: 2) : f.paperCurve
        let paper = try context.makeTexture(width: pc.count, height: 1)
        pc.withUnsafeBytes { paper.replace(region: MTLRegionMake2D(0, 0, pc.count, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: pc.count * 16) }
        let zeros = [SIMD4<Float>](repeating: .zero, count: Spectral.count)
        let spec = f.filmDyeBase + (f.printWeights.isEmpty ? zeros : f.printWeights) + (f.paperDyeBase.isEmpty ? zeros : f.paperDyeBase) + f.viewWeights
            + (f.scanWeights.isEmpty ? zeros : f.scanWeights)
        guard let buf = context.device.makeBuffer(bytes: spec, length: spec.count * 16, options: .storageModeShared) else { throw GPUError.allocation("film") }
        filmRes = (f, elut, curves, paper, buf)
        return filmRes!
    }

    /// Guided-filter coefficients (a, b) at a pyramid level; guide = pre-exposure log luminance, input = the
    /// guide itself (edge-aware smoothing) or `input`.
    private func encodeGuided(_ enc: MTLComputeCommandEncoder, name: String, level: MTLTexture, input: MTLTexture?,
                              radius: Int, eps: Float, u: [SIMD4<Float>]) throws -> MTLTexture {
        let w = level.width, h = level.height
        let g = try scratchTexture("g", w, h, .r32Float)
        let prep = try scratchTexture("prep", w, h)
        let tmp = try scratchTexture("tmp", w, h)
        let coefTmp = try scratchTexture("coefTmp", w, h, .rg32Float)
        let coef = try scratchTexture("coef-\(name)", w, h, .rg32Float)
        let r = Float(max(2, radius))
        context.encode(enc, loglumPSO, textures: [level, g], uniforms: u, size: (w, h))
        context.encode(enc, gfPrepPSO, textures: [g, input ?? g, prep], uniforms: [], size: (w, h))
        context.encode(enc, boxPSO, textures: [prep, tmp], uniforms: [SIMD4(r, 1, 0, 0)], size: (w, h))
        context.encode(enc, boxPSO, textures: [tmp, prep], uniforms: [SIMD4(r, 0, 1, 0)], size: (w, h))
        context.encode(enc, gfCoefPSO, textures: [prep, coefTmp], uniforms: [SIMD4(eps, 0, 0, 0)], size: (w, h))
        context.encode(enc, boxPSO, textures: [coefTmp, tmp], uniforms: [SIMD4(r, 1, 0, 0)], size: (w, h))
        context.encode(enc, boxPSO, textures: [tmp, coef], uniforms: [SIMD4(r, 0, 1, 0)], size: (w, h))
        return coef
    }

    /// Atmospheric light: mean colour of the 0.1 % pixels with the brightest dark channel. The pixels are
    /// chosen once per geometry (un-rendered native values); white balance is then a matrix product.
    private func airlight(_ p: DevelopParameters) -> SIMD3<Float> {
        if airlightNative == nil {
            let img = context.download(pyramid[levelBase])
            let n = img.width * img.height
            var pre = [SIMD3<Float>](repeating: .zero, count: n)
            var darks = [(Float, Int)]()
            darks.reserveCapacity(n)
            let m = p.inputMatrix
            for i in 0..<n {
                var c = SIMD3(img.pixels[i * 4], img.pixels[i * 4 + 1], img.pixels[i * 4 + 2])
                if p.unrender { c = ToneMath.shoulderInverse(c) }
                pre[i] = c
                let b = m * c
                darks.append((min(b.x, b.y, b.z), i))
            }
            let k = max(1, n / 1000)
            let top = darks.sorted { $0.0 > $1.0 }.prefix(k)
            airlightNative = top.reduce(SIMD3<Float>.zero) { $0 + pre[$1.1] } / Float(k)
        }
        return simd_max(p.inputMatrix * airlightNative!, SIMD3(repeating: 1e-3))
    }

    private func matrixUniforms(_ p: DevelopParameters) -> [SIMD4<Float>] {
        let m = p.inputMatrix
        return [SIMD4(m.columns.0, p.unrender ? 1 : 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0)]
    }

    // MARK: Rendering

    /// Renders a view of the edited picture (one command buffer).
    /// - Parameters:
    ///   - interactiveGeometry: geometry is being dragged — orient on the fly at render resolution instead of
    ///     rebuilding the full-resolution oriented image (local adjustments are skipped meanwhile).
    ///   - histogramSpace: also compute the histogram of the result in this output space.
    ///   - slot: which view cache to use (keep the visible region and an overview in different slots).
    ///   - overlayTarget: show the pixels selected by targeted colour `overlayTarget` (everything else grey).
    public func render(_ edit: EditState, view: ViewRequest, interactiveGeometry: Bool = false,
                       histogramSpace: OutputColorSpace? = nil, slot: Int = 0, overlayTarget: Int? = nil,
                       overlayMask: Int? = nil, fastGrain: Bool = false, fastLayers: Bool = false) throws -> RenderedView {
        guard let src = source else { throw GPUError.allocation("no source") }
        var p = DevelopParameters.resolve(edit, source: src, overlayTarget: overlayTarget, overlayMask: overlayMask)
        ensureDetectedMasks(p)
        let g = edit.geometry
        let full = outputSize(g)
        let scale = min(1, view.scale)
        let ox = max(0, min(view.region.minX, full.width - 1)), oy = max(0, min(view.region.minY, full.height - 1))
        let w = max(1, Int(((min(full.width, view.region.maxX) - ox) * scale).rounded(.up)))
        let h = max(1, Int(((min(full.height, view.region.maxY) - oy) * scale).rounded(.up)))
        let out = try outputTexture(width: w, height: h, slot: slot)
        let origin = CGPoint(x: ox, y: oy)

        let interactive = interactiveGeometry && orientedGeometry != g
        var approximateGrain = false
        var layersOnTheFly = false
        if !interactive {
            try ensureOriented(g)
            layersOnTheFly = try ensureComposite(p, fast: fastLayers)
        }
        if interactive {
            try ensureSourcePyramid()
            // Geometry is being dragged: the view is oriented on the fly, so are its layers.
            layersOnTheFly = !activeLayers(p).isEmpty
        }
        if !interactive && p.needsDarkMap { p.airlight = airlight(p) }

        try context.run { enc in
            if interactive {
                p.shadows = 0; p.highlights = 0; p.clarity = 0; p.dehaze = 0; p.bloomTint = .zero; p.halation = .zero
                p.masks = []; p.locals = []; p.maskOverlay = -1
            } else {
                try encodeMaps(enc, p)
                try encodeGlow(enc, p)
            }
            if view.exact && scale < 1 && !interactive {
                try encodeExact(enc, p, origin: origin, scale: scale, full: full, out: out)
            } else {
                let vk = ViewKey(region: CGRect(x: ox, y: oy, width: Double(w) / scale, height: Double(h) / scale), scale: scale,
                                 geometry: g, interactiveGeometry: interactive, proxy: src.isProxy)
                var cache = views[slot] ?? ViewCache()
                if cache.key != vk || cache.input == nil || layersOnTheFly {
                    let fetched = try encodeFetch(enc, geometry: g, origin: origin, scale: scale, width: w, height: h, interactive: interactive,
                                                  levels: layersOnTheFly ? layerState.base : nil)
                    if layersOnTheFly {
                        // A layer is being moved or changed: composite just this view (the full-resolution
                        // composite follows on release); refetched every frame.
                        let active = activeLayers(p)
                        let comp = try context.makeTexture(width: w, height: h, gpuOnly: true)
                        let masks = try encodeLayerMasks(enc, p, active, input: fetched, origin: origin, step: 1 / scale, geometry: g)
                        encodeLayerComposite(enc, p, active, base: fetched, out: comp, origin: origin, step: 1 / scale, masks: masks, geometry: g)
                        cache.input = comp
                        cache.key = nil
                        cache.masks = nil
                    } else {
                        cache.input = fetched
                        cache.key = vk
                    }
                    cache.fineKey = nil
                    cache.softKey = nil
                }
                let fine = try encodeFineBlur(enc, p, cache: &cache, key: vk, sigma: Float(0.0005 * Double(max(full.width, full.height)) * scale))
                let filmTex = try encodeFilmInputs(enc, p, cache: &cache, key: vk, scale: scale, origin: origin, step: 1 / scale, fastGrain: fastGrain)
                approximateGrain = filmTex.usedFastGrain
                let mw = try viewMaskWeights(enc, p, input: cache.input!, region: vk.region, scale: scale, geometry: g, origin: origin,
                                             full: full, cached: &cache.masks)
                encodeDevelop(enc, p, input: cache.input!, fine: fine, origin: origin, step: 1 / scale, full: full, out: out, film: filmTex, masks: mw)
                views[slot] = cache
            }
            if let histogramSpace { encodeHistogram(enc, out, space: histogramSpace) }
        }
        return RenderedView(texture: out, origin: origin, scale: scale,
                            exact: (view.exact || scale >= 1) && !interactive && !approximateGrain && !layersOnTheFly,
                            histogram: histogramSpace != nil ? readHistogram() : nil)
    }

    private func outputTexture(width w: Int, height h: Int, slot: Int) throws -> MTLTexture {
        // Ring of three per slot so the display can keep showing one while the next is rendered.
        var c = views[slot] ?? ViewCache()
        defer { views[slot] = c }
        c.outputs.removeAll { $0.width != w || $0.height != h }
        if c.outputs.count < 3 { let t = try context.makeTexture(width: w, height: h, gpuOnly: true); c.outputs.append(t); return t }
        c.outputIndex = (c.outputIndex + 1) % c.outputs.count
        return c.outputs[c.outputIndex]
    }

    /// Input at render resolution: from the oriented pyramid (area average), or — while geometry is being
    /// dragged — oriented on the fly from the source pyramid at the render scale.
    private func encodeFetch(_ enc: MTLComputeCommandEncoder, geometry g: FrameGeometry, origin: CGPoint, scale: Double,
                             width w: Int, height h: Int, interactive: Bool, levels override: [MTLTexture]? = nil) throws -> MTLTexture {
        let dst = try context.makeTexture(width: w, height: h, gpuOnly: true)
        let ss = sourceScale
        let levels = override ?? (interactive ? sourcePyramid : pyramid)
        var k = 0
        while k + 1 < levels.count, ss / pow(2, Double(k + 1)) >= scale { k += 1 }
        let lvl = levels[k]
        let levelScale = ss / pow(2, Double(k))                  // level px per full-quality output px
        if interactive {
            // render pixel (i + 0.5) -> level output px  levelScale·origin + (i + 0.5)·levelScale/scale -> level source px
            let a = g.outputToSource(sourceWidth: lvl.width, sourceHeight: lvl.height, scale: 1)
            let toLevel = Affine2D.translation([origin.x * levelScale, origin.y * levelScale]).concatenating(.scale(levelScale / scale))
            let m = a.concatenating(toLevel)
            let u: [SIMD4<Float>] = [
                SIMD4(Float(m.m.columns.0.x), Float(m.m.columns.0.y), Float(m.m.columns.1.x), Float(m.m.columns.1.y)),
                SIMD4(Float(m.t.x), Float(m.t.y), Float(lvl.width), Float(lvl.height)),
                SIMD4(0, 0, 1, 0),
            ]
            context.encode(enc, context.orientPipeline, textures: [lvl, dummy, dst], uniforms: u, size: (w, h))
        } else {
            let step = levelScale / scale
            let u = [SIMD4<Float>(Float(origin.x * levelScale), Float(origin.y * levelScale), Float(step), Float(step))]
            context.encode(enc, fetchPSO, textures: [lvl, dst], uniforms: u, size: (w, h))
        }
        return dst
    }

    /// Fine-scale Gaussian of the log luminance (texture). σ = 0.0005 × long side, in render pixels.
    private func encodeFineBlur(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, cache: inout ViewCache, key: ViewKey,
                                sigma: Float) throws -> MTLTexture {
        guard p.texture != 0, let input = cache.input else { return dummy }
        let fk = FineKey(view: key, matrix: p.inputMatrix, unrender: p.unrender, sigma: sigma)
        if cache.fineKey == fk, let f = cache.fine { return f }
        let w = input.width, h = input.height
        let l = (cache.fine?.width == w && cache.fine?.height == h) ? cache.fine! : try context.makeTexture(width: w, height: h, format: .r32Float, gpuOnly: true)
        let t = try scratchTexture("fineTmp", w, h, .r32Float)
        encodeLogLumBlur(enc, p, input: input, out: l, tmp: t, sigma: sigma)
        cache.fine = l
        cache.fineKey = fk
        return l
    }

    private func encodeLogLumBlur(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, input: MTLTexture, out l: MTLTexture,
                                  tmp t: MTLTexture, sigma: Float) {
        let w = input.width, h = input.height
        context.encode(enc, loglumPSO, textures: [input, l], uniforms: matrixUniforms(p), size: (w, h))
        if sigma >= 0.25 {
            let r = Float(Int(ceil(3 * sigma)))
            context.encode(enc, gaussPSO, textures: [l, t], uniforms: [SIMD4(sigma, r, 1, 0)], size: (w, h))
            context.encode(enc, gaussPSO, textures: [t, l], uniforms: [SIMD4(sigma, r, 0, 1)], size: (w, h))
        }
    }

    static func flags(_ p: DevelopParameters) -> Float {
        var f = 0
        if p.isIdentity { f |= 1 }
        if p.needsToneStage { f |= 2 }
        if p.needsColour { f |= 4 }
        if p.needsLocal { f |= 8 }
        if p.needsMidMap { f |= 16 }
        if p.texture != 0 { f |= 32 }
        return Float(f)
    }

    static func developUniforms(_ p: DevelopParameters, origin: CGPoint, step: Double, full: CGSize) -> [SIMD4<Float>] {
        let m = p.inputMatrix
        let pr = p.print ?? PrintCurve().resolved
        return [
            SIMD4(m.columns.0, p.unrender ? 1 : 0),
            SIMD4(m.columns.1, p.exposureGain),
            SIMD4(m.columns.2, p.exposureStops),
            SIMD4(p.shadows, p.highlights, p.clarityGain, p.textureGain),
            SIMD4(p.dehaze, p.airlight.x, p.airlight.y, p.airlight.z),
            SIMD4(Float(p.profileKind), p.contrastSlope, p.whites, p.blacks),
            SIMD4(Float(pr.exposure), Float(pr.slope), Float(pr.y0), Float(pr.aHigh)),
            SIMD4(Float(pr.aLow), Float(pr.kShoulder), Float(pr.kToe), flags(p)),
            SIMD4(p.saturation, p.vibrance, p.colorChrome, p.colorChromeBlue),
            SIMD4(Float(origin.x), Float(origin.y), Float(step), Float(step)),
            SIMD4(Float(full.width), Float(full.height), p.highlightTone, p.shadowTone),
        ] + colourUniforms(p)
    }

    /// u11…u33: curves, mixer, targeted colours, grading (layout documented in Kernels.swift).
    static func colourUniforms(_ p: DevelopParameters) -> [SIMD4<Float>] {
        var u = [SIMD4<Float>](repeating: .zero, count: 23)
        u[0] = SIMD4(p.masterCurve ? 1 : 0, p.rgbCurves ? 1 : 0, p.mixer != nil ? 1 : 0, Float(p.targets.count))
        u[1] = SIMD4(Float(p.overlayTarget), p.grading != nil ? 1 : 0, p.drCompression, 0)
        if let m = p.mixer { for i in 0..<8 { u[2 + i] = SIMD4(m[i], 0) } }
        for (i, t) in p.targets.prefix(4).enumerated() {
            u[10 + 2 * i] = SIMD4(t.hue, t.chroma, t.core, t.edge)
            u[11 + 2 * i] = SIMD4(t.hueShift, t.saturation, t.luminance, t.isolate)
        }
        if let g = p.grading {
            u[18] = SIMD4(g.shadows, 0); u[19] = SIMD4(g.midtones, 0); u[20] = SIMD4(g.highlights, 0); u[21] = SIMD4(g.global, 0)
            u[22] = SIMD4(g.shadowCentre, g.highlightCentre, g.halfWidth, 0)
        }
        return u
    }

    /// Per-render textures for film and grain: grain noise (coarse, fine), emulsion softness, and the uniform
    /// values that depend on the render pixel size.
    struct FilmInputs {
        /// Sparse and dense grain fields (see `add_grain`), the film softness blur.
        var noiseC: MTLTexture?, noiseF: MTLTexture?, soft: MTLTexture?
        var softWeight: Float = 0
        /// Variance per unit density, correlation of the two fields, extra normalisation (Gaussian fallback).
        var k: Float = 0, rho: Float = 1, normG: Float = 1, rhoOwn: Float = 0
        var usedFastGrain = false
    }

    /// Discrete Gaussian used by the `gauss` kernel: Σw² of the normalised 1-D weights.
    static func gaussSquaredSum(_ sigma: Double) -> Double {
        let r = Int(ceil(3 * sigma))
        let w = (-r...r).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        let s = w.reduce(0, +)
        return w.reduce(0) { $0 + ($1 / s) * ($1 / s) }
    }

    /// Emulsion scatter radius (render px) for a softness setting.
    func softSigma(_ p: DevelopParameters, scale: Double) -> Double {
        9 * (0.6 + 0.8 * Double(p.softness)) / (micronsPerPixel(p) / scale)
    }

    private func grainField(_ p: DevelopParameters, scale: Double) -> GrainRender.Field? {
        p.grain.map { $0.field(renderPixelMicrons: micronsPerPixel(p) / scale) }
    }

    /// 1 for monochrome grain; 4 when the dye layers also have their own grain (shared + R, G, B).
    private func grainLayers(_ p: DevelopParameters) -> Int { (p.grain?.colour ?? 0) > 0.001 ? 4 : 1 }

    /// Mean and spread of the Boolean grain fields for a set of parameters, measured once on a patch with the
    /// same kernel (so the fields can be normalised exactly): (mean s, 1/std s, mean d, 1/std d), correlation.
    struct GrainStats { var norm: SIMD4<Float>; var layer: SIMD2<Float>; var rho: Float; var rhoOwn: Float }
    private var grainStatsCache: [String: GrainStats] = [:]
    private func grainStats(_ f: GrainRender.Field, layers: Int) throws -> GrainStats {
        // The Boolean model is scale invariant: with the coverages fixed, its statistics depend only on the size
        // spread and on blur / radius. Measured on a field scaled to radius 6 µm, at quantised ratios.
        let q = (log2(f.filter / f.radius) * 40).rounded() / 40
        let key = String(format: "%.2f|%.3f", f.sigmaLn, q)
        if let s = grainStatsCache[key] { return s }
        var f = f
        let k = 6 / f.radius
        f.radius = 6; f.filter = 6 * pow(2, q); f.maxRadius *= k; f.cell *= k; f.reach = f.maxRadius + 3 * f.filter
        f.lambdaSparse /= k * k; f.lambdaDense /= k * k
        let n = 128
        let a = try context.makeTexture(width: n, height: n), b = try context.makeTexture(width: n, height: n)
        try context.run { context.encode($0, texClearPSO, textures: [a], uniforms: [], size: (n, n)); context.encode($0, texClearPSO, textures: [b], uniforms: [], size: (n, n)) }
        // A patch far from the frame, sampled every 1.5 µm.
        try context.run { try encodeBoolean($0, f, c: a, d: b, origin: CGPoint(x: 52_000, y: 61_000), step: 1, mpp: 1.5, seed: 4_242,
                                            norm: SIMD4(0, 1, 0, 1), layer: SIMD2(0, 1), layers: 3) }
        // The structure channel (x) only.
        let pa = context.download(a).pixels, pb = context.download(b).pixels
        let sa = stride(from: 0, to: n * n * 4, by: 4).map { pa[$0] }
        let sb = stride(from: 0, to: n * n * 4, by: 4).map { pb[$0] }
        let sl = stride(from: 1, to: n * n * 4, by: 4).map { pb[$0] }
        func stats(_ v: [Float]) -> (Double, Double) {
            var m = 0.0, q = 0.0
            for x in v { m += Double(x); q += Double(x) * Double(x) }
            m /= Double(v.count)
            return (m, max(q / Double(v.count) - m * m, 1e-12).squareRoot())
        }
        let (ms, ss) = stats(sa), (md, sd) = stats(sb), (ml, sdl) = stats(sl)
        func corr(_ x: [Float], _ mx: Double, _ sx: Double, _ y: [Float], _ my: Double, _ sy: Double) -> Float {
            var c = 0.0
            for i in 0..<x.count { c += (Double(x[i]) - mx) * (Double(y[i]) - my) }
            return Float(c / Double(x.count) / (sx * sy))
        }
        let rhoOwn = (corr(sa, ms, ss, sl, ml, sdl) + corr(sb, md, sd, sl, ml, sdl)) / 2
        let r = GrainStats(norm: SIMD4(Float(ms), Float(1 / ss), Float(md), Float(1 / sd)), layer: SIMD2(Float(ml), Float(1 / sdl)),
                           rho: corr(sa, ms, ss, sb, md, sd), rhoOwn: rhoOwn)
        grainStatsCache[key] = r
        return r
    }

    private var grainBuffers: (grains: MTLBuffer, counts: MTLBuffer, cells: Int)?

    /// Two-pass Boolean grain over a w×h render grid starting at output px `origin` (step output px per render
    /// px): the grains of every cell the grid can see, then each pixel. `norm` = (mean s, 1/std s, mean d,
    /// 1/std d); `ownNorm` scales the dye layers' own noise already in yzw.
    private func encodeBoolean(_ enc: MTLComputeCommandEncoder, _ f: GrainRender.Field, c: MTLTexture, d: MTLTexture,
                               origin: CGPoint, step: Double, mpp: Double, seed: UInt32, norm: SIMD4<Float>, layer: SIMD2<Float>,
                               layers: Int) throws {
        let x0 = origin.x * mpp, y0 = origin.y * mpp
        let x1 = x0 + Double(c.width) * step * mpp, y1 = y0 + Double(c.height) * step * mpp
        let cx0 = Int(floor((x0 - f.reach) / f.cell)), cy0 = Int(floor((y0 - f.reach) / f.cell))
        let cx1 = Int(floor((x1 + f.reach) / f.cell)), cy1 = Int(floor((y1 + f.reach) / f.cell))
        let gw = cx1 - cx0 + 1, gh = cy1 - cy0 + 1
        let cells = gw * gh
        if grainBuffers == nil || grainBuffers!.cells < cells {
            guard let g = context.device.makeBuffer(length: cells * 8 * 16, options: .storageModePrivate),
                  let n = context.device.makeBuffer(length: cells * 4, options: .storageModePrivate) else { throw GPUError.allocation("grain") }
            grainBuffers = (g, n, cells)
        }
        let (gb, nb, _) = grainBuffers!
        let mean = Float(f.lambdaDense * f.cell * f.cell)
        context.encode(enc, grainCellsPSO, textures: [],
                       uniforms: [SIMD4(Float(cx0), Float(cy0), Float(gw), Float(gh)),
                                  SIMD4(Float(seed % 65536), Float(f.radius), Float(f.sigmaLn), Float(f.cell)),
                                  SIMD4(mean, Float(f.lambdaSparse / f.lambdaDense), Float(f.maxRadius), 0)],
                       size: (gw, gh), buffers: [gb, nb])
        context.encode(enc, grainBoolPSO, textures: [c, d],
                       uniforms: [SIMD4(Float(origin.x), Float(origin.y), Float(step), Float(mpp)),
                                  SIMD4(Float(cx0), Float(cy0), Float(gw), Float(gh)),
                                  SIMD4(Float(f.cell), Float(f.filter), Float(f.reach), Float(layers)),
                                  norm, SIMD4(layer.x, layer.y, 0, 0)],
                       size: (c.width, c.height), buffers: [gb, nb])
    }

    /// Draws the two grain fields of a view or band into `c` (sparse) and `f` (dense).
    private func encodeGrain(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, c: MTLTexture, f: MTLTexture,
                             origin: CGPoint, step: Double, scale: Double, fast: Bool = false) throws -> (rho: Float, normG: Float, rhoOwn: Float) {
        guard let g = p.grain, var field = grainField(p, scale: scale) else { return (1, 1, 0) }
        if fast { field.boolean = false }
        if field.boolean {
            let layers = grainLayers(p)
            let st = try grainStats(field, layers: layers)
            try encodeBoolean(enc, field, c: c, d: f, origin: origin, step: step, mpp: micronsPerPixel(p), seed: g.seed, norm: st.norm,
                              layer: st.layer, layers: layers > 1 ? 3 : 1)
            return (st.rho, 1, st.rhoOwn)
        }
        // Grains far below a pixel: their sum is Gaussian; white noise per render pixel seen through the blur.
        let sigma = field.filter / (micronsPerPixel(p) / scale)
        encodeNoise(enc, c: c, f: f, origin: origin, step: step, scale: scale, seed: g.seed, sigmaC: sigma, sigmaF: sigma)
        return (1, sigma >= 0.35 ? Float(1 / Self.gaussSquaredSum(sigma)) : 1, 0)
    }

    /// Generates (and caches per view) grain noise and the softened input for a render at `scale`.
    /// `fastGrain`: while the view moves, a grain field that must be drawn anew uses the Gaussian fallback
    /// (`usedFastGrain` then tells the caller to render again, exactly, once things settle).
    private func encodeFilmInputs(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, cache: inout ViewCache, key: ViewKey,
                                  scale: Double, origin: CGPoint, step: Double, fastGrain: Bool = false) throws -> FilmInputs {
        var fi = FilmInputs()
        guard let input = cache.input else { return fi }
        let w = input.width, h = input.height
        if let g = p.grain, let field = grainField(p, scale: scale) {
            fi.k = field.k
            var shape = field
            shape.k = 0   // the strength does not change the pattern
            var nk = NoiseKey(view: key, seed: g.seed, field: shape, layers: grainLayers(p))
            let fast = fastGrain && field.boolean && cache.noiseKey != nk
            if fast { nk.field.boolean = false }
            fi.usedFastGrain = fast
            if cache.noiseKey != nk || cache.noise == nil {
                let c = (cache.noise?.0.width == w && cache.noise?.0.height == h) ? cache.noise!.0 : try context.makeTexture(width: w, height: h, gpuOnly: true)
                let f = (cache.noise?.1.width == w && cache.noise?.1.height == h) ? cache.noise!.1 : try context.makeTexture(width: w, height: h, gpuOnly: true)
                let r = try encodeGrain(enc, p, c: c, f: f, origin: origin, step: step, scale: scale, fast: fast)
                cache.noise = (c, f)
                cache.noiseKey = nk
                cache.grainNorm = r
            }
            fi.noiseC = cache.noise!.0; fi.noiseF = cache.noise!.1
            (fi.rho, fi.normG, fi.rhoOwn) = cache.grainNorm
        }
        if p.softness > 0 {
            let sigma = softSigma(p, scale: scale)
            if sigma >= 0.3 {
                let sk = SoftKey(view: key, sigma: sigma)
                if cache.softKey != sk || cache.soft == nil {
                    let t = (cache.soft?.width == w && cache.soft?.height == h) ? cache.soft! : try context.makeTexture(width: w, height: h, gpuOnly: true)
                    let tmp = try scratchTexture("softTmp", w, h)
                    let r = Float(Int(ceil(3 * sigma)))
                    context.encode(enc, gaussPSO, textures: [input, tmp], uniforms: [SIMD4(Float(sigma), r, 1, 0)], size: (w, h))
                    context.encode(enc, gaussPSO, textures: [tmp, t], uniforms: [SIMD4(Float(sigma), r, 0, 1)], size: (w, h))
                    cache.soft = t
                    cache.softKey = sk
                }
                fi.soft = cache.soft
                fi.softWeight = 0.7 * p.softness
            }
        }
        return fi
    }

    /// White Gaussian noise per render pixel (keyed on film position), blurred by `sigmaC` / `sigmaF` render px.
    /// Drawn with a margin and cropped, so a view's edges get exactly the noise the export has there.
    private func encodeNoise(_ enc: MTLComputeCommandEncoder, c: MTLTexture, f: MTLTexture, origin: CGPoint, step: Double, scale: Double,
                             seed: UInt32, sigmaC: Double, sigmaF: Double) {
        let w = c.width, h = c.height
        let m = max(sigmaC, sigmaF) >= 0.35 ? Int(ceil(3 * max(sigmaC, sigmaF))) + 1 : 0
        let pw = w + 2 * m, ph = h + 2 * m
        let pc = m > 0 ? ((try? scratchTexture("noisePadC", pw, ph)) ?? c) : c
        let pf = m > 0 ? ((try? scratchTexture("noisePadF", pw, ph)) ?? f) : f
        let o = CGPoint(x: origin.x - Double(m) * step, y: origin.y - Double(m) * step)
        context.encode(enc, noisePSO, textures: [pc, pf],
                       uniforms: [SIMD4(Float(o.x), Float(o.y), Float(step), Float(scale)), SIMD4(Float(seed % 65536), 0, 0, 0)],
                       size: (pw, ph))
        for (t, sigma) in [(pc, sigmaC), (pf, sigmaF)] where sigma >= 0.35 {
            let tmp = (try? scratchTexture("noiseTmp", pw, ph)) ?? dummy
            let r = Float(Int(ceil(3 * sigma)))
            context.encode(enc, gaussPSO, textures: [t, tmp], uniforms: [SIMD4(Float(sigma), r, 1, 0)], size: (pw, ph))
            context.encode(enc, gaussPSO, textures: [tmp, t], uniforms: [SIMD4(Float(sigma), r, 0, 1)], size: (pw, ph))
        }
        if m > 0 {
            context.encode(enc, fetchPSO, textures: [pc, c], uniforms: [SIMD4(Float(m), Float(m), 1, 1)], size: (w, h))
            context.encode(enc, fetchPSO, textures: [pf, f], uniforms: [SIMD4(Float(m), Float(m), 1, 1)], size: (w, h))
        }
    }


    /// u34…u50: film, halation, bloom, grain, softness, vignette (layout documented in Kernels.swift).
    func filmUniforms(_ p: DevelopParameters, _ fi: FilmInputs, full: CGSize) -> [SIMD4<Float>] {
        var u = [SIMD4<Float>](repeating: .zero, count: 26)
        u[25] = SIMD4(p.filmBalance, 0)
        if let l = p.look {
            u[0] = SIMD4(4, p.filmIntensity, 1, p.hasBloom ? 1 : 0)
            u[6] = SIMD4(0, 0, 0, p.hasHalation && halMap != nil ? 1 : 0)
            u[11] = SIMD4(p.halation, p.exposureGain)
            u[24] = SIMD4(1, Float(l.table.size), Float(l.grainCurve), Float(GrainRender.lookVisibility))
        } else if let f = p.film {
            u[17] = SIMD4(f.densityMid, f.isScan ? 1 : 0)
            u[18] = SIMD4(f.invGamma, f.scanChroma)
            u[19] = SIMD4(f.scanInverse.columns.0, 0); u[20] = SIMD4(f.scanInverse.columns.1, 0); u[21] = SIMD4(f.scanInverse.columns.2, 0)
            let c = f.scanCurve
            u[22] = SIMD4(Float(c.exposure), Float(c.slope), Float(c.y0), Float(c.aHigh))
            u[23] = SIMD4(Float(c.aLow), Float(c.kShoulder), Float(c.kToe), 0)
            let kind: Float = f.kind == .slide ? 2 : (f.kind == .bwNegative ? 3 : 1)
            u[0] = SIMD4(kind, p.filmIntensity, f.paperGamma, p.hasBloom ? 1 : 0)
            u[1] = SIMD4(f.logEMin, f.logEStep, f.paperLogEMin, f.paperLogEStep)
            u[2] = SIMD4(f.couplerMatrixT.columns.0, 0); u[3] = SIMD4(f.couplerMatrixT.columns.1, 0); u[4] = SIMD4(f.couplerMatrixT.columns.2, 0)
            u[5] = SIMD4(f.logK, f.gain)
            u[6] = SIMD4(f.mid, p.hasHalation && halMap != nil ? 1 : 0)
            u[7] = SIMD4(f.outputMatrix.columns.0, 0); u[8] = SIMD4(f.outputMatrix.columns.1, 0); u[9] = SIMD4(f.outputMatrix.columns.2, 0)
            u[10] = SIMD4(f.densityMax, 0)
            u[11] = SIMD4(p.halation, p.exposureGain)
        } else {
            u[0] = SIMD4(0, 1, 1, p.hasBloom ? 1 : 0)
        }
        if p.hasBloom && bloomMap == nil { u[0].w = 0 }
        u[12] = SIMD4(p.bloomTint, 0)
        if let g = p.grain, fi.noiseC != nil {
            u[10].w = 1
            u[13] = SIMD4(fi.k, 0, 0, Float(g.colour))
        }
        u[14] = SIMD4(fi.rho, fi.normG, fi.softWeight, fi.rhoOwn)
        if p.vignette.x != 0 {
            u[15] = p.vignette
            u[16] = SIMD4(p.vignetteHighlights, Float(full.width / max(full.height, 1)), 1, 0)
        }
        return u
    }

    private func encodeDevelop(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, input: MTLTexture, fine: MTLTexture,
                               origin: CGPoint, step: Double, full: CGSize, out: MTLTexture, film fi: FilmInputs = FilmInputs(),
                               masks: MTLTexture? = nil) {
        let res = p.film.flatMap { try? filmResources($0) }
        let u = Self.developUniforms(p, origin: origin, step: step, full: full) + filmUniforms(p, fi, full: full)
            + (masks != nil ? localUniforms(p) : [SIMD4(0, -1, 0, 0)])
        context.encode(enc, developPSO,
                       textures: [input, fine, baseCoef ?? dummy, midCoef ?? dummy, darkCoef ?? dummy, out, curveTexture(p),
                                  res?.elut ?? dummy, res?.curves ?? dummy, res?.paper ?? dummy, fi.noiseC ?? dummy, fi.noiseF ?? dummy,
                                  bloomMap ?? dummy, halMap ?? dummy, fi.soft ?? dummy,
                                  p.look.flatMap { try? lookResource($0) } ?? dummy3D, masks ?? dummyArray, localCurveTexture(p)],
                       uniforms: u, size: (out.width, out.height), buffers: [res?.spec ?? dummyBuffer])
    }

    /// Full-resolution bands (input, fine blur, develop) for source rows [Y0, Y1) and columns [X0, X1).
    private func encodeBand(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, X0: Int, Y0: Int, width bw: Int, height bh: Int,
                            full: CGSize, slot: Int) throws -> MTLTexture {
        let base = pyramid[0]
        let ss = sourceScale
        let input = try scratchTexture("bandIn\(slot)", bw, bh)
        let developed = try scratchTexture("bandOut\(slot)", bw, bh)
        context.encode(enc, fetchPSO, textures: [base, input], uniforms: [SIMD4(Float(X0), Float(Y0), 1, 1)], size: (bw, bh))
        var fine = dummy
        if p.texture != 0 {
            let l = try scratchTexture("bandFine\(slot)", bw, bh, .r32Float)
            let t = try scratchTexture("bandFineTmp\(slot)", bw, bh, .r32Float)
            encodeLogLumBlur(enc, p, input: input, out: l, tmp: t, sigma: Float(0.0005 * Double(max(full.width, full.height)) * ss))
            fine = l
        }
        // Band pixel (i, j) is full-quality output px (X0 + i + 0.5) / ss.
        let origin = CGPoint(x: Double(X0) / ss, y: Double(Y0) / ss)
        var fi = FilmInputs()
        if let field = grainField(p, scale: ss) {
            let c = try scratchTexture("bandNoiseC\(slot)", bw, bh), f = try scratchTexture("bandNoiseF\(slot)", bw, bh)
            (fi.rho, fi.normG, fi.rhoOwn) = try encodeGrain(enc, p, c: c, f: f, origin: origin, step: 1 / ss, scale: ss)
            fi.noiseC = c; fi.noiseF = f; fi.k = field.k
        }
        if p.softness > 0 {
            let sigma = softSigma(p, scale: ss)
            if sigma >= 0.3 {
                let t = try scratchTexture("bandSoft\(slot)", bw, bh), tmp = try scratchTexture("bandSoftTmp\(slot)", bw, bh)
                let r = Float(Int(ceil(3 * sigma)))
                context.encode(enc, gaussPSO, textures: [input, tmp], uniforms: [SIMD4(Float(sigma), r, 1, 0)], size: (bw, bh))
                context.encode(enc, gaussPSO, textures: [tmp, t], uniforms: [SIMD4(Float(sigma), r, 0, 1)], size: (bw, bh))
                fi.soft = t
                fi.softWeight = 0.7 * p.softness
            }
        }
        var mw: MTLTexture?
        if p.hasLocals, let g = orientedGeometry {
            let t = try bandMaskTexture(width: bw, height: bh, slot: slot)
            encodeMaskWeights(enc, p, input: input, out: t, geometry: g, origin: origin, step: 1 / ss, full: full)
            mw = t
        }
        encodeDevelop(enc, p, input: input, fine: fine, origin: origin, step: 1 / ss, full: full, out: developed, film: fi, masks: mw)
        return developed
    }

    private func bandMargin(_ p: DevelopParameters, full: CGSize) -> Int {
        var m = p.texture != 0 ? Int(ceil(3 * 0.0005 * Double(max(full.width, full.height)) * sourceScale)) + 2 : 0
        // Boolean grain is drawn per pixel (no neighbourhood); the Gaussian fallback is blurred.
        if let f = grainField(p, scale: sourceScale), !f.boolean {
            m = max(m, Int(ceil(3 * f.filter / micronsPerPixel(p) * sourceScale)) + 2)
        }
        if p.softness > 0 { m = max(m, Int(ceil(3 * softSigma(p, scale: sourceScale))) + 2) }
        return m
    }

    /// Exact view: full-resolution bands area-averaged into `out`.
    private func encodeExact(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, origin: CGPoint, scale: Double, full: CGSize,
                             out: MTLTexture, onlyBand: Int? = nil) throws {
        let base = pyramid[0]
        let ss = sourceScale
        let margin = bandMargin(p, full: full)
        let bandRows = max(1, Int((512 * scale).rounded()))
        let fx0 = origin.x * ss, fx1 = (origin.x + Double(out.width) / scale) * ss
        let X0 = max(0, Int(floor(fx0)) - margin), X1 = min(base.width, Int(ceil(fx1)) + margin)
        let maxRows = Int(ceil(Double(bandRows) / scale * ss)) + 2 * margin + 2
        var r0 = 0, slot = 0, band = 0
        while r0 < out.height {
            let r1 = min(out.height, r0 + bandRows)
            defer { band += 1 }
            if let only = onlyBand, only != band { r0 = r1; continue }
            let fy0 = (origin.y + Double(r0) / scale) * ss, fy1 = (origin.y + Double(r1) / scale) * ss
            let Y0 = max(0, Int(floor(fy0)) - margin), Y1 = min(base.height, Int(ceil(fy1)) + margin)
            // Fixed band size so the scratch textures are reused (extra rows are simply not read).
            let developed = try encodeBand(enc, p, X0: X0, Y0: Y0, width: max(1, X1 - X0), height: min(maxRows, base.height),
                                           full: full, slot: slot)
            _ = Y1
            let step = ss / scale
            let u: [SIMD4<Float>] = [
                SIMD4(Float(step), Float(step), Float(fx0 - Double(X0)), Float(fy0 - Double(Y0))),
                SIMD4(0, Float(r0), 0, 0),
            ]
            context.encode(enc, intoPSO, textures: [developed, out], uniforms: u, size: (out.width, r1 - r0))
            r0 = r1
            slot = 1 - slot
        }
    }

    /// Number of bands `encodeExact` splits an exact view of this height into.
    private func exactBandCount(outHeight: Int, scale: Double) -> Int {
        let bandRows = max(1, Int((512 * scale).rounded()))
        return (outHeight + bandRows - 1) / bandRows
    }

    /// Exact view rendered band by band, giving up (nil) as soon as `cancel` returns true — so a newer request
    /// (a slider moving again) never waits for a whole full-resolution render.
    public func renderExact(_ edit: EditState, view: ViewRequest, histogramSpace: OutputColorSpace? = nil, slot: Int = 0,
                            overlayTarget: Int? = nil, overlayMask: Int? = nil, cancel: () -> Bool) throws -> RenderedView? {
        guard view.scale < 1 else {
            return try render(edit, view: view, histogramSpace: histogramSpace, slot: slot, overlayTarget: overlayTarget, overlayMask: overlayMask)
        }
        guard let src = source else { throw GPUError.allocation("no source") }
        var p = DevelopParameters.resolve(edit, source: src, overlayTarget: overlayTarget, overlayMask: overlayMask)
        ensureDetectedMasks(p)
        let g = edit.geometry
        let full = outputSize(g)
        let scale = view.scale
        let ox = max(0, min(view.region.minX, full.width - 1)), oy = max(0, min(view.region.minY, full.height - 1))
        let w = max(1, Int(((min(full.width, view.region.maxX) - ox) * scale).rounded(.up)))
        let h = max(1, Int(((min(full.height, view.region.maxY) - oy) * scale).rounded(.up)))
        try ensureOriented(g)
        _ = try ensureComposite(p, fast: false)
        if p.needsDarkMap { p.airlight = airlight(p) }
        // A private texture (not the slot's ring): the half-finished result is never shown.
        let out = try scratchTexture("exact-\(slot)", w, h)
        try context.run { try encodeMaps($0, p); try encodeGlow($0, p); try updateMaskBitmaps($0, p) }
        for b in 0..<exactBandCount(outHeight: h, scale: scale) {
            if cancel() { return nil }
            try context.run { try encodeExact($0, p, origin: CGPoint(x: ox, y: oy), scale: scale, full: full, out: out, onlyBand: b) }
        }
        if cancel() { return nil }
        let final = try outputTexture(width: w, height: h, slot: slot)
        try context.run { enc in
            context.encode(enc, intoPSO, textures: [out, final], uniforms: [SIMD4(1, 1, 0, 0), SIMD4(0, 0, 0, 0)], size: (w, h))
            if let histogramSpace { encodeHistogram(enc, final, space: histogramSpace) }
        }
        return RenderedView(texture: final, origin: CGPoint(x: ox, y: oy), scale: scale, exact: true,
                            histogram: histogramSpace != nil ? readHistogram() : nil)
    }

    /// A small CPU copy of a rendered view (area-averaged), for thumbnails.
    public func snapshot(_ v: RenderedView, maxSize: Int) throws -> LinearImage {
        let t = v.texture
        let s = min(1, Double(maxSize) / Double(max(t.width, t.height)))
        let dst = try context.makeTexture(width: max(1, Int(Double(t.width) * s)), height: max(1, Int(Double(t.height) * s)))
        try context.run { context.encodeDownsample($0, src: t, dst: dst) }
        return context.download(dst)
    }

    /// The tone-curve table as a 4096×1 float texture (rebuilt only when the curves change).
    private func curveTexture(_ p: DevelopParameters) -> MTLTexture {
        guard let data = p.curveLUT else { return dummy }
        if let c = curveLUT, c.data == data { return c.texture }
        guard let t = try? context.makeTexture(width: data.count, height: 1) else { return dummy }
        data.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, data.count, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: data.count * 16) }
        curveLUT = (data, t)
        return t
    }

    // MARK: Export

    /// The whole picture at full resolution, exactly as the exact preview shows it (bands, no resampling).
    public func renderFull(_ edit: EditState) throws -> LinearImage {
        guard let src = source else { throw GPUError.allocation("no source") }
        var p = DevelopParameters.resolve(edit, source: src)
        ensureDetectedMasks(p)
        try loadLayerSources(for: edit.effective)
        let g = edit.geometry
        try ensureOriented(g)
        _ = try ensureComposite(p, fast: false)
        if p.needsDarkMap { p.airlight = airlight(p) }
        let full = outputSize(g)
        let W = pyramid[0].width, H = pyramid[0].height
        let margin = bandMargin(p, full: full)
        var pixels = [Float](repeating: 0, count: W * H * 4)
        let band = 512
        try context.run { try encodeMaps($0, p); try encodeGlow($0, p); try updateMaskBitmaps($0, p) }
        var y0 = 0
        let staging = try context.makeTexture(width: W, height: band)
        while y0 < H {
            let y1 = min(H, y0 + band)
            let Y0 = max(0, y0 - margin)
            let bh = min(H, y1 + margin) - Y0
            try context.run { enc in
                let developed = try encodeBand(enc, p, X0: 0, Y0: Y0, width: W, height: bh, full: full, slot: 0)
                context.encode(enc, intoPSO, textures: [developed, staging],
                               uniforms: [SIMD4(1, 1, 0, Float(y0 - Y0)), SIMD4(0, 0, 0, 0)], size: (W, y1 - y0))
            }
            pixels.withUnsafeMutableBytes { raw in
                staging.getBytes(raw.baseAddress!.advanced(by: y0 * W * 16), bytesPerRow: W * 16,
                                 from: MTLRegionMake2D(0, 0, W, y1 - y0), mipmapLevel: 0)
            }
            y0 = y1
        }
        scratch = scratch.filter { !$0.key.hasPrefix("band") }
        maskState.band = [:]
        return LinearImage(width: W, height: H, pixels: pixels)
    }

    // MARK: Histogram & sampling

    private func encodeHistogram(_ enc: MTLComputeCommandEncoder, _ t: MTLTexture, space: OutputColorSpace) {
        memset(histBuffer.contents(), 0, 771 * 4)
        let m = simd_float3x3(space.fromRec2020)
        context.encode(enc, histPSO, textures: [t], uniforms: [SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0)],
                       size: ((t.width + 1) / 2, (t.height + 1) / 2), buffers: [histBuffer])
    }

    private func readHistogram() -> Histogram {
        let p = histBuffer.contents().bindMemory(to: UInt32.self, capacity: 771)
        var bins = [SIMD3<Float>](repeating: .zero, count: 256)
        for i in 0..<256 { bins[i] = SIMD3(Float(p[i]), Float(p[256 + i]), Float(p[512 + i])) }
        let total = max(1, Double(p[770]))
        return Histogram(bins: bins, shadowClip: Double(p[768]) / total, highlightClip: Double(p[769]) / total)
    }

    /// The developed colour (display-linear Rec.2020) of a small square around an output pixel, as it is at the
    /// input of the curves (`beforeCurves`) or fully developed — for the curve and colour pickers.
    public func sampleDeveloped(_ edit: EditState, at point: CGPoint, radius: Int = 3, beforeCurves: Bool = false) throws -> SIMD3<Float> {
        var e = edit
        if beforeCurves {
            e.curves = ToneCurves(); e.mixer = ColorMixer(); e.targeted = []; e.grading = ColorGrading(); e.color = EditState.BasicColor()
        }
        let r = CGRect(x: point.x.rounded(.down) - CGFloat(radius), y: point.y.rounded(.down) - CGFloat(radius),
                       width: CGFloat(2 * radius + 1), height: CGFloat(2 * radius + 1))
        let v = try render(e, view: ViewRequest(region: r, scale: 1, exact: true), slot: 2)
        let img = try snapshot(v, maxSize: 64)
        var acc = SIMD3<Float>.zero
        for i in 0..<(img.width * img.height) { acc += SIMD3(img.pixels[i * 4], img.pixels[i * 4 + 1], img.pixels[i * 4 + 2]) }
        return acc / Float(img.width * img.height)
    }

    /// Mean native value (before white balance) of a small square around an output pixel — for the eyedropper.
    public func sampleNative(at point: CGPoint, geometry g: FrameGeometry, radius: Int = 3) throws -> SIMD3<Double>? {
        try ensureOriented(g)
        let base = pyramid[0]
        let ss = sourceScale
        let x = Int(point.x * ss), y = Int(point.y * ss)
        let staging = try context.makeTexture(width: 2 * radius + 1, height: 2 * radius + 1)
        try context.run { enc in
            context.encode(enc, fetchPSO, textures: [base, staging], uniforms: [SIMD4(Float(x - radius), Float(y - radius), 1, 1)],
                           size: (staging.width, staging.height))
        }
        let img = context.download(staging)
        var acc = SIMD3<Double>.zero
        for i in 0..<(img.width * img.height) {
            acc += SIMD3(Double(img.pixels[i * 4]), Double(img.pixels[i * 4 + 1]), Double(img.pixels[i * 4 + 2]))
        }
        return acc / Double(img.width * img.height)
    }
}

/// Area average of a source rectangle into a destination sub-rectangle.
/// u[0] = (scaleX, scaleY, srcOriginX, srcOriginY), u[1] = (dstOffsetX, dstOffsetY, -, -)
let resampleIntoSource = #"""

kernel void resample_into(texture2d<float, access::read>  src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float4 *u                  [[buffer(0)]],
                          uint2 gid                           [[thread_position_in_grid]])
{
    uint2 o = gid + uint2(u[1].xy);
    if (o.x >= dst.get_width() || o.y >= dst.get_height()) return;
    float2 a = u[0].zw + float2(gid) * u[0].xy;
    if (u[0].x == 1.0f && u[0].y == 1.0f && all(a == floor(a))) { dst.write(src.read(uint2(a)), o); return; }
    dst.write(box_average(src, a, a + u[0].xy), o);
}
"""#

// MARK: - Masks

/// A mask made by subject / people detection, in the photo's default orientation (any resolution).
public struct DetectedMask: Sendable {
    public var width: Int, height: Int
    /// Row-major 0…1 values.
    public var values: [Float]
    /// The orientation the mask was made in (default quarter turns / flips of the photo, no crop).
    public var orientation: FrameGeometry
    public init(width: Int, height: Int, values: [Float], orientation: FrameGeometry) {
        self.width = width; self.height = height; self.values = values; self.orientation = orientation
    }
}

/// GPU state of the masks: brush strokes and detected masks as bitmaps in sensor space at half resolution
/// (a 2D-array texture, one slice per bitmap part), and the masks' curve table.
final class MaskGPUState {
    var atlas: MTLTexture?
    var slots: [UUID: Int] = [:]
    var content: [UUID: [BrushStroke]] = [:]
    /// Version of the detected mask copied into a part's slice.
    var detectedIn: [UUID: Int] = [:]
    /// Committed strokes of a brush part and a copy of its slice after them (so only the stroke being
    /// painted is drawn again while painting).
    var base: [UUID: (strokes: [BrushStroke], texture: MTLTexture)] = [:]
    var alpha: MTLTexture?
    /// Bumped whenever a bitmap changes (invalidates cached mask weights).
    var version = 0
    var detected: [MaskComponent.Kind: (mask: DetectedMask, version: Int)] = [:]
    var curves: (data: [[Float]], texture: MTLTexture)?
    var dummyArray: MTLTexture?
    var band: [Int: MTLTexture] = [:]
}

extension RenderEngine {
    struct MaskKey: Equatable {
        var region: CGRect; var scale: Double; var geometry: FrameGeometry
        var shapes: [[MaskComponent]]; var inverts: [Bool]
        var range: [SIMD4<Float>]?; var bitmaps: Int
    }

    /// Sets (or clears) the detected subject / people mask of the current photo.
    public func setDetectedMask(_ m: DetectedMask?, kind: MaskComponent.Kind) {
        if let m { maskState.detected[kind] = (m, (maskState.detected[kind]?.version ?? 0) + 1) } else { maskState.detected[kind] = nil }
    }
    public func hasDetectedMask(_ kind: MaskComponent.Kind) -> Bool { maskState.detected[kind] != nil }

    /// Runs subject / people detection (Vision, cached per file) for the masks that need it.
    func ensureDetectedMasks(_ p: DevelopParameters) {
        guard let src = source else { return }
        for kind in Set(p.allMaskParts.map(\.kind)) where kind.isDetected && maskState.detected[kind] == nil {
            if let m = MaskDetector.detect(kind, source: src) { setDetectedMask(m, kind: kind) }
        }
    }

    func releaseMasks() {
        maskState = MaskGPUState()
    }

    func maskArrayTexture(width: Int, height: Int, slices: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .r32Float
        d.width = width; d.height = height; d.arrayLength = max(1, slices)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        guard let t = context.device.makeTexture(descriptor: d) else { throw GPUError.allocation("mask \(width)x\(height)x\(slices)") }
        return t
    }

    var dummyArray: MTLTexture {
        if let t = maskState.dummyArray { return t }
        let t = try! maskArrayTexture(width: 1, height: 1, slices: 1)
        maskState.dummyArray = t
        return t
    }

    /// Sensor size at full quality and the bitmap size (half).
    private var sensorSize: (w: Int, h: Int) { (source?.fullSize.width ?? 1, source?.fullSize.height ?? 1) }
    private var atlasSize: (w: Int, h: Int) { ((sensorSize.w + 1) / 2, (sensorSize.h + 1) / 2) }

    /// Brings the bitmap slices up to date with the edit's brush strokes and detected masks.
    func updateMaskBitmaps(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters) throws {
        let parts = p.allMaskParts.filter { $0.kind == .brush || $0.kind.isDetected }
        guard !parts.isEmpty else { return }
        let (aw, ah) = atlasSize
        let st = maskState
        if st.atlas == nil || st.atlas!.arrayLength < parts.count || st.atlas!.width != aw || st.atlas!.height != ah {
            st.atlas = try maskArrayTexture(width: aw, height: ah, slices: max(4, parts.count + 2))
            st.slots = [:]; st.content = [:]; st.detectedIn = [:]; st.base = [:]
            st.version += 1
        }
        let atlas = st.atlas!
        // Slots: keep the ones in use, give new parts free slices.
        let ids = Set(parts.map(\.id))
        st.slots = st.slots.filter { ids.contains($0.key) }
        st.base = st.base.filter { ids.contains($0.key) }
        var free = Array(Set(0..<atlas.arrayLength).subtracting(st.slots.values)).sorted()
        for c in parts where st.slots[c.id] == nil {
            st.slots[c.id] = free.removeFirst()
            st.content[c.id] = nil; st.detectedIn[c.id] = nil
            context.encode(enc, maskClearPSO, textures: [atlas], uniforms: [SIMD4(Float(st.slots[c.id]!), 0, 0, 0)], size: (aw, ah))
        }
        for c in parts {
            let slot = st.slots[c.id]!
            if c.kind == .brush {
                if st.content[c.id] != c.strokes {
                    try updateBrush(enc, id: c.id, slot: slot, strokes: c.strokes)
                    st.content[c.id] = c.strokes
                    st.version += 1
                }
            } else if let d = st.detected[c.kind], st.detectedIn[c.id] != d.version {
                try blitDetected(enc, d.mask, slot: slot)
                st.detectedIn[c.id] = d.version
                st.version += 1
            }
        }
    }

    private func blitDetected(_ enc: MTLComputeCommandEncoder, _ m: DetectedMask, slot: Int) throws {
        let (W, H) = sensorSize, (aw, ah) = atlasSize
        let src = try context.makeTexture(width: m.width, height: m.height, format: .r32Float)
        m.values.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, m.width, m.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: m.width * 4) }
        // atlas px -> sensor px -> oriented px -> uv of the mask
        let o = m.orientation.orientedSize(sourceWidth: W, sourceHeight: H)
        let toOriented = m.orientation.outputToSource(sourceWidth: W, sourceHeight: H).inverse
        let a = Affine2D(m: simd_double2x2(diagonal: [1 / Double(o.width), 1 / Double(o.height)]), t: .zero)
            .concatenating(toOriented).concatenating(Affine2D(m: simd_double2x2(diagonal: [Double(W) / Double(aw), Double(H) / Double(ah)]), t: .zero))
        let u: [SIMD4<Float>] = [SIMD4(Float(a.m.columns.0.x), Float(a.m.columns.0.y), Float(a.m.columns.1.x), Float(a.m.columns.1.y)),
                                 SIMD4(Float(a.t.x), Float(a.t.y), Float(slot), 0)]
        context.encode(enc, maskBlitPSO, textures: [src, maskState.atlas!], uniforms: u, size: (aw, ah))
    }

    /// Redraws a brush slice: committed strokes come from the saved copy; only new strokes are drawn.
    private func updateBrush(_ enc: MTLComputeCommandEncoder, id: UUID, slot: Int, strokes: [BrushStroke]) throws {
        let st = maskState, atlas = st.atlas!
        let (aw, ah) = atlasSize
        if st.alpha == nil || st.alpha!.width != aw || st.alpha!.height != ah {
            st.alpha = try context.makeTexture(width: aw, height: ah, format: .r32Float, gpuOnly: true)
            context.encode(enc, texClearPSO, textures: [st.alpha!], uniforms: [], size: (aw, ah))
        }
        let committed = Array(strokes.dropLast())
        var base = st.base[id]
        if base == nil || !committed.starts(with: base!.strokes) {
            let t = try base?.texture ?? maskArrayTexture(width: aw, height: ah, slices: 1)
            context.encode(enc, maskClearPSO, textures: [t], uniforms: [SIMD4(0, 0, 0, 0)], size: (aw, ah))
            base = ([], t)
        }
        if base!.strokes.count < committed.count {
            for s in committed[base!.strokes.count...] { rasterize(enc, s, into: base!.texture, slice: 0) }
            base!.strokes = committed
        }
        st.base[id] = base
        context.encode(enc, maskCopyPSO, textures: [base!.texture, atlas], uniforms: [SIMD4(0, Float(slot), 0, 0)], size: (aw, ah))
        if let last = strokes.last { rasterize(enc, last, into: atlas, slice: slot) }
    }

    /// One stroke into a slice: coverage (max over the tip along the path) in chunks of 16 segments, then
    /// composited (paint or erase).
    private func rasterize(_ enc: MTLComputeCommandEncoder, _ s: BrushStroke, into tex: MTLTexture, slice: Int) {
        guard let alpha = maskState.alpha, !s.points.isEmpty else { return }
        let (W, H) = sensorSize, (aw, ah) = atlasSize
        let L = Double(max(W, H))
        let k = SIMD2(L * Double(aw) / Double(W), L * Double(ah) / Double(H))
        let pts = s.points.map { SIMD2($0.x, $0.y) * k }
        let r = max(0.75, s.radius * k.x)
        let inner = max(0, min(r * (1 - s.feather / 100), r - 0.75))
        let segs: [(SIMD2<Double>, SIMD2<Double>)] = pts.count == 1 ? [(pts[0], pts[0])] : Array(zip(pts, pts.dropFirst()))
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        for start in stride(from: 0, to: segs.count, by: 16) {
            let chunk = segs[start..<min(start + 16, segs.count)]
            var cl = SIMD2<Double>(repeating: .infinity), ch = SIMD2<Double>(repeating: -.infinity)
            for (a, b) in chunk { cl = simd_min(cl, simd_min(a, b)); ch = simd_max(ch, simd_max(a, b)) }
            cl -= r + 1; ch += r + 1
            lo = simd_min(lo, cl); hi = simd_max(hi, ch)
            let x0 = max(0, Int(cl.x)), y0 = max(0, Int(cl.y)), x1 = min(aw, Int(ch.x) + 1), y1 = min(ah, Int(ch.y) + 1)
            guard x1 > x0, y1 > y0 else { continue }
            var u: [SIMD4<Float>] = [SIMD4(Float(x0), Float(y0), Float(r), Float(inner)), SIMD4(Float(s.flow / 100), Float(chunk.count), 0, 0)]
            for (a, b) in chunk { u.append(SIMD4(Float(a.x), Float(a.y), Float(b.x), Float(b.y))) }
            context.encode(enc, brushSegPSO, textures: [alpha], uniforms: u, size: (x1 - x0, y1 - y0))
        }
        let x0 = max(0, Int(lo.x)), y0 = max(0, Int(lo.y)), x1 = min(aw, Int(hi.x) + 1), y1 = min(ah, Int(hi.y) + 1)
        guard x1 > x0, y1 > y0 else { return }
        context.encode(enc, brushCompPSO, textures: [tex, alpha], uniforms: [SIMD4(Float(x0), Float(y0), s.erase ? 1 : 0, Float(slice))],
                       size: (x1 - x0, y1 - y0))
    }

    /// Mask uniforms for `mask_eval` (layout in Kernels.swift) for output pixels of a view.
    func maskUniforms(_ p: DevelopParameters, geometry g: FrameGeometry) -> [SIMD4<Float>] {
        let (W, H) = sensorSize
        let L = Double(max(W, H))
        let a = Affine2D.scale(1 / L).concatenating(g.outputToSource(sourceWidth: W, sourceHeight: H))
        var m = [SIMD4<Float>](repeating: .zero, count: 11)
        m[0] = SIMD4(Float(p.masks.count), 0, Float(L / Double(W)), Float(L / Double(H)))
        m[1] = SIMD4(Float(a.m.columns.0.x), Float(a.m.columns.0.y), Float(a.m.columns.1.x), Float(a.m.columns.1.y))
        m[2] = SIMD4(Float(a.t.x), Float(a.t.y), 0, 0)
        var parts: [SIMD4<Float>] = []
        var j = 0
        for (i, mask) in p.masks.enumerated() {
            let comps = Array(mask.components.prefix(max(0, LocalAdjustment.maximumComponents - j)))
            m[3 + i] = SIMD4(Float(j), Float(comps.count), mask.invert ? 1 : 0, 0)
            for c in comps {
                let kind: Float
                var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero
                switch c.kind {
                case .brush: kind = 0
                case .linear: kind = 1; a = SIMD4(Float(c.start.x), Float(c.start.y), Float(c.end.x), Float(c.end.y))
                case .radial:
                    kind = 2
                    let an = c.angle * .pi / 180
                    a = SIMD4(Float(c.center.x), Float(c.center.y), Float(c.radiusX), Float(c.radiusY))
                    b = SIMD4(Float(cos(an)), Float(sin(an)), Float(min(1 - c.feather / 100, 0.995)), 0)
                case .luminance: kind = 3; a = SIMD4(Float(c.low), Float(c.high), Float(c.smoothness), 0)
                case .color:
                    kind = 4
                    let t = MaskMath.colorTarget(c)
                    a = SIMD4(t.hue, t.chroma, t.core, t.edge)
                case .subject: kind = 5
                case .people: kind = 6
                case .sky: kind = 7
                }
                let mode: Float = c.mode == .add ? 0 : (c.mode == .subtract ? 1 : 2)
                parts += [SIMD4(kind, mode, c.invert ? 1 : 0, Float(maskState.slots[c.id] ?? 0)), a, b, .zero]
                j += 1
            }
        }
        return m + parts
    }

    func bandMaskTexture(width: Int, height: Int, slot: Int) throws -> MTLTexture {
        if let t = maskState.band[slot], t.width == width, t.height == height { return t }
        let t = try maskArrayTexture(width: width, height: height, slices: LocalAdjustment.maximumCount)
        maskState.band[slot] = t
        return t
    }

    /// Weights of every mask over a view (`develop`'s texture 16).
    func encodeMaskWeights(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, input: MTLTexture, out: MTLTexture,
                           geometry g: FrameGeometry, origin: CGPoint, step: Double, full: CGSize) {
        let du = Self.developUniforms(p, origin: origin, step: step, full: full)
        let mu = maskUniforms(p, geometry: g)
        guard let buf = context.device.makeBuffer(bytes: mu, length: mu.count * 16, options: .storageModeShared) else { return }
        context.encode(enc, maskEvalPSO, textures: [input, out, maskState.atlas ?? dummyArray], uniforms: du,
                       size: (out.width, out.height), buffers: [buf])
    }

    /// Cached mask weights for a view of slot `cache`.
    func viewMaskWeights(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, input: MTLTexture, region: CGRect, scale: Double,
                         geometry g: FrameGeometry, origin: CGPoint, full: CGSize, cached: inout (MaskKey, MTLTexture)?) throws -> MTLTexture? {
        guard p.hasLocals else { return nil }
        try updateMaskBitmaps(enc, p)
        let usesRange = p.masks.contains { $0.components.contains { $0.kind == .luminance || $0.kind == .color } }
        let key = MaskKey(region: region, scale: scale, geometry: g, shapes: p.masks.map(\.components), inverts: p.masks.map(\.invert),
                          range: usesRange ? Self.developUniforms(p, origin: origin, step: 1 / scale, full: full).prefix(11).map { $0 } : nil,
                          bitmaps: maskState.version)
        if let c = cached, c.0 == key, c.1.arrayLength >= p.masks.count { return c.1 }
        let t = (cached?.1.width == input.width && cached?.1.height == input.height && (cached?.1.arrayLength ?? 0) >= p.masks.count)
            ? cached!.1 : try maskArrayTexture(width: input.width, height: input.height, slices: LocalAdjustment.maximumCount)
        encodeMaskWeights(enc, p, input: input, out: t, geometry: g, origin: origin, step: 1 / scale, full: full)
        cached = (key, t)
        return t
    }

    /// u60…: masks' adjustments (layout in Kernels.swift).
    func localUniforms(_ p: DevelopParameters) -> [SIMD4<Float>] {
        var u: [SIMD4<Float>] = [SIMD4(Float(p.locals.count), Float(p.maskOverlay), p.needsLocalShape ? 1 : 0, 0)]
        for (i, l) in p.locals.enumerated() {
            let m = l.whiteBalance ?? matrix_identity_float3x3
            u += [SIMD4(l.exposureStops, l.dehaze, l.shadows, l.highlights),
                  SIMD4(l.clarityGain, l.contrast, l.saturation, l.grain),
                  SIMD4(l.cast.x, l.cast.y, l.curve != nil ? 1 : 0, l.whiteBalance != nil ? 1 : 0),
                  SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0)]
            _ = i
        }
        return u
    }

    /// The masks' curves as a 4096 × count table (`develop`'s texture 17).
    func localCurveTexture(_ p: DevelopParameters) -> MTLTexture {
        guard p.locals.contains(where: { $0.curve != nil }) else { return dummy }
        let n = CurveMath.lutSize
        let rows = p.locals.map { $0.curve ?? (0..<n).map { Float($0) / Float(n - 1) } }
        if let c = maskState.curves, c.data == rows { return c.texture }
        guard let t = try? context.makeTexture(width: n, height: rows.count, format: .r32Float) else { return dummy }
        let flat = rows.flatMap { $0 }
        flat.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, n, rows.count), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 4) }
        maskState.curves = (rows, t)
        return t
    }
}
