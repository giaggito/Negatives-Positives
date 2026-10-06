import Foundation
import Metal
import simd

/// GPU state of the double-exposure layers: each layer's photo as a mipmapped texture (kept across photos
/// and proxy → full upgrades), and the photo's own oriented pyramid while `pyramid` holds the composite.
final class LayerGPUState {
    struct Entry {
        /// The layer's photo without its pixels (they live in `texture`).
        var source: SourceImage
        var texture: MTLTexture
        var frame: LayerMath.Frame
        var used: Date
    }
    var entries: [String: Entry] = [:]
    var base: [MTLTexture] = []
    var key: CompositeKey?
}

struct CompositeKey: Equatable {
    var geometry: FrameGeometry
    var layers: [PhotoLayer]
    var textures: [ObjectIdentifier]
    var range: [SIMD4<Float>]?
    var bitmaps: Int
}

extension RenderEngine {
    // MARK: Layer photos

    /// Uploads a layer's photo (replacing a proxy or an older copy of the same file).
    public func setLayerSource(_ s: SourceImage) throws {
        let path = s.url.path
        if let e = layerState.entries[path], !e.source.isProxy || s.isProxy { return }
        guard context.device.supports32BitFloatFiltering else { throw GPUError.allocation("layers need 32-bit float filtering") }
        let img = s.image
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: img.width, height: img.height, mipmapped: true)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        guard let t = context.device.makeTexture(descriptor: d) else { throw GPUError.allocation("layer \(img.width)x\(img.height)") }
        img.pixels.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.width * 16)
        }
        // Mip levels by area averaging (as the photo's own pyramid).
        try context.run { enc in
            for k in 1..<t.mipmapLevelCount {
                guard let src = t.makeTextureView(pixelFormat: .rgba32Float, textureType: .type2D, levels: (k - 1)..<k, slices: 0..<1),
                      let dst = t.makeTextureView(pixelFormat: .rgba32Float, textureType: .type2D, levels: k..<(k + 1), slices: 0..<1) else { continue }
                context.encodeDownsample(enc, src: src, dst: dst,
                                         region: CGRectLike(x: 0, y: 0, width: Double(dst.width * 2), height: Double(dst.height * 2)))
            }
        }
        layerState.entries[path] = .init(source: s.withoutPixels(), texture: t, frame: LayerMath.Frame(s), used: Date())
        // Keep at most five layer photos (each full-size one is ~0.5 GB of GPU memory).
        while layerState.entries.count > 5, let old = layerState.entries.min(by: { $0.value.used < $1.value.used })?.key { layerState.entries[old] = nil }
    }

    /// Whether the layer photo at `path` is ready (at full quality when `full`).
    public func hasLayerSource(_ path: String, full: Bool = false) -> Bool {
        guard let e = layerState.entries[path] else { return false }
        return !full || !e.source.isProxy
    }

    /// Loads every layer photo the edit needs at full quality (export; blocks).
    public func loadLayerSources(for edit: EditState) throws {
        for l in edit.layers where !hasLayerSource(l.path, full: true) {
            try setLayerSource(try SourceLoader.load(url: l.url))
        }
    }

    func activeLayers(_ p: DevelopParameters) -> [(layer: PhotoLayer, entry: LayerGPUState.Entry)] {
        p.layers.compactMap { l in
            guard var e = layerState.entries[l.path] else { return nil }
            e.used = Date()
            layerState.entries[l.path] = e
            return (l, e)
        }
    }

    // MARK: Compositing

    /// Brings `pyramid` up to date with the layers: the photo alone, or the photo with its layers composited
    /// at full resolution. With `fast` (something is being dragged) a changed composite is not rebuilt —
    /// the caller composites the view on the fly instead (returns true).
    func ensureComposite(_ p: DevelopParameters, fast: Bool) throws -> Bool {
        let active = activeLayers(p)
        if active.isEmpty {
            if !layerState.base.isEmpty {
                pyramid = layerState.base
                layerState.base = []
                layerState.key = nil
                invalidateDerived()
            }
            return false
        }
        if layerState.base.isEmpty { layerState.base = pyramid; layerState.key = nil }
        let key = compositeKey(p, active)
        if key == layerState.key { return false }
        if fast { return true }
        let base = layerState.base[0]
        let comp = try context.makeTexture(width: base.width, height: base.height, gpuOnly: true)
        let ss = sourceScale
        try context.run { enc in
            // Masks are evaluated on the photo at half resolution (they are smooth or come from half-resolution bitmaps).
            let k = layerState.base.count > 1 ? 1 : 0
            let lvl = layerState.base[k]
            let masks = try encodeLayerMasks(enc, p, active, input: lvl, origin: .zero, step: pow(2, Double(k)) / ss)
            encodeLayerComposite(enc, p, active, base: base, out: comp, origin: .zero, step: 1 / ss, masks: masks)
        }
        pyramid = try buildPyramid(comp)
        layerState.key = key
        invalidateDerived()
        return false
    }

    private func compositeKey(_ p: DevelopParameters, _ active: [(layer: PhotoLayer, entry: LayerGPUState.Entry)]) -> CompositeKey {
        let parts = active.flatMap(\.layer.mask.components)
        let usesRange = parts.contains { $0.kind == .luminance || $0.kind == .color }
        let usesBitmaps = parts.contains { $0.kind == .brush || $0.kind.isDetected }
        return CompositeKey(geometry: orientedGeometry ?? FrameGeometry(), layers: active.map(\.layer),
                            textures: active.map { ObjectIdentifier($0.entry.texture) },
                            range: usesRange ? Self.developUniforms(p, origin: .zero, step: 1, full: outputSize(orientedGeometry ?? FrameGeometry())).prefix(11).map { $0 } : nil,
                            bitmaps: usesBitmaps ? maskState.version : 0)
    }

    /// The layer masks over `input` (photo native values; its pixel (i, j) is output px origin + (i + ½, j + ½)·step),
    /// one slice per masked layer.
    func encodeLayerMasks(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, _ active: [(layer: PhotoLayer, entry: LayerGPUState.Entry)],
                          input: MTLTexture, origin: CGPoint, step: Double, geometry: FrameGeometry? = nil) throws -> MTLTexture? {
        let masked = active.map(\.layer).filter(\.isMasked)
        guard !masked.isEmpty, let g = geometry ?? orientedGeometry else { return nil }
        try updateMaskBitmaps(enc, p)
        var pm = p
        pm.masks = masked.map(\.mask)
        let t = try maskArrayTexture(width: input.width, height: input.height, slices: masked.count)
        encodeMaskWeights(enc, pm, input: input, out: t, geometry: g, origin: origin, step: step, full: outputSize(g))
        return t
    }

    /// Composites the layers into `out` (same size as `base`, whose pixel (i, j) is output px
    /// origin + (i + ½, j + ½)·step).
    func encodeLayerComposite(_ enc: MTLComputeCommandEncoder, _ p: DevelopParameters, _ active: [(layer: PhotoLayer, entry: LayerGPUState.Entry)],
                              base: MTLTexture, out: MTLTexture, origin: CGPoint, step: Double, masks: MTLTexture?,
                              geometry: FrameGeometry? = nil) {
        guard let src = source, let g = geometry ?? orientedGeometry else { return }
        let sensor = (src.fullSize.width, src.fullSize.height)
        let toSensor = g.outputToSource(sourceWidth: sensor.0, sourceHeight: sensor.1)
            .concatenating(.translation([origin.x, origin.y])).concatenating(.scale(step))
        let ref = simd_float3x3(src.inputMatrix(whiteBalance: nil))
        let inv = ref.inverse
        var u: [SIMD4<Float>] = [SIMD4(Float(active.count), src.kind == .display ? 1 : 0, Float(pow(2, src.baselineExposure)), 0),
                                 SIMD4(ref.columns.0, 0), SIMD4(ref.columns.1, 0), SIMD4(ref.columns.2, 0),
                                 SIMD4(inv.columns.0, 0), SIMD4(inv.columns.1, 0), SIMD4(inv.columns.2, 0)]
        var slice = 0
        var textures: [MTLTexture] = []
        for (l, e) in active {
            let a = LayerMath.sensorToLayerUV(l, frame: e.frame, photoSensor: sensor).concatenating(toSensor)
            let tw = Double(e.texture.width), th = Double(e.texture.height)
            let texels = max(simd_length(a.m.columns.0 * SIMD2(tw, th)), simd_length(a.m.columns.1 * SIMD2(tw, th)))
            let lod = max(0, log2(max(texels, 1e-6)))
            let ai = a.inverse
            let m = LayerMath.colourMatrix(l, layerSource: e.source, photoBaseline: src.baselineExposure)
            u += [SIMD4(Float(a.m.columns.0.x), Float(a.m.columns.0.y), Float(a.m.columns.1.x), Float(a.m.columns.1.y)),
                  SIMD4(Float(a.t.x), Float(a.t.y), Float(lod), Float(l.blend.code)),
                  SIMD4(Float(l.amount / 100), e.source.kind == .display ? 1 : 0, l.isMasked ? Float(slice) : -1, 0),
                  SIMD4(Float(simd_length(ai.m.columns.0)), Float(simd_length(ai.m.columns.1)), 0, 0),
                  SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0), .zero]
            if l.isMasked { slice += 1 }
            textures.append(e.texture)
        }
        while textures.count < 3 { textures.append(textures[0]) }
        context.encode(enc, layerPSO, textures: [base, out] + textures + [masks ?? dummyArray], uniforms: u, size: (out.width, out.height))
    }
}

extension SourceImage {
    /// The same photo's description without its pixels (for layers, whose pixels live on the GPU).
    public func withoutPixels() -> SourceImage {
        SourceImage(url: url, kind: kind, image: LinearImage(width: 1, height: 1, pixels: [0, 0, 0, 0]), cameraToRec2020: cameraToRec2020,
                    asShotWhiteBalance: asShotWhiteBalance, defaultOrientation: defaultOrientation, baselineExposure: baselineExposure,
                    isProxy: isProxy, fullSize: fullSize, bitsPerComponent: bitsPerComponent, cameraDescription: cameraDescription)
    }
}
