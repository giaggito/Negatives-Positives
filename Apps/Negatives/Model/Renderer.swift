import CoreGraphics
import Foundation
import Metal
import NegativesCore

/// Everything needed to produce one picture on screen.
struct RenderJob {
    var frame: DecodedFrame
    var parameters: ConversionParameters
    var geometry: FrameGeometry
    var stage: OutputStage
    /// Fit the whole image into this many pixels…
    var fit: CGSize
    /// …or, when set, show a 1:1 region of this size centred on `zoomCentre` (output pixels).
    var zoomCentre: CGPoint?
    var flat: FlatField?
    var flatVersion: Int
}

struct RenderResult {
    var image: CGImage
    var histogram: [SIMD3<Float>]
    /// Full-resolution output size of the displayed geometry.
    var outputSize: CGSize
    /// For zoomed views: the output-pixel rectangle shown.
    var region: CGRect?
}

/// GPU renderer for the editor. Caches the uploaded sensor image, the oriented (geometry + flat-field)
/// image and the full-resolution output buffer, so a slider change only re-runs the per-pixel conversion.
/// The display image is the full-resolution result area-averaged to screen size: exactly the export, smaller.
/// Not thread-safe: use from one serial queue.
final class EditorRenderer {
    let gpu: GPUPipeline
    private var sourceFrame: ObjectIdentifier?
    private var source: MTLTexture?
    private var oriented: MTLTexture?
    private var orientedKey: (FrameGeometry, Int)?
    private var output: MTLTexture?
    private var display: MTLTexture?
    private var flatTexture: MTLTexture?
    private var flatVersion = -1

    init(gpu: GPUPipeline) { self.gpu = gpu }

    func release() {
        source = nil; oriented = nil; output = nil; display = nil
        sourceFrame = nil; orientedKey = nil
    }

    func render(_ job: RenderJob) throws -> RenderResult {
        if sourceFrame != ObjectIdentifier(job.frame) {
            release()
            source = try gpu.upload(job.frame.raw.image)
            sourceFrame = ObjectIdentifier(job.frame)
        }
        if flatVersion != job.flatVersion {
            flatTexture = try job.flat.map { try gpu.upload($0.gain) }
            flatVersion = job.flatVersion
            orientedKey = nil
        }
        if orientedKey == nil || orientedKey!.0 != job.geometry || orientedKey!.1 != job.flatVersion {
            oriented = nil
            oriented = try gpu.orient(source!, geometry: job.geometry, flatField: flatTexture)
            orientedKey = (job.geometry, job.flatVersion)
        }
        let o = oriented!
        if output == nil || output!.width != o.width || output!.height != o.height { output = nil; output = try gpu.makeTexture(width: o.width, height: o.height) }
        let out = try gpu.convert(o, parameters: job.parameters, stage: job.stage, into: output)
        let size = CGSize(width: out.width, height: out.height)

        let img: LinearImage
        var region: CGRect?
        if let c = job.zoomCentre {
            let w = min(out.width, Int(job.fit.width)), h = min(out.height, Int(job.fit.height))
            let x = min(max(0, Int(c.x) - w / 2), out.width - w), y = min(max(0, Int(c.y) - h / 2), out.height - h)
            img = gpu.download(out, x: x, y: y, width: w, height: h)
            region = CGRect(x: x, y: y, width: w, height: h)
        } else {
            let s = min(1, min(job.fit.width / size.width, job.fit.height / size.height))
            let w = max(1, Int((size.width * s).rounded())), h = max(1, Int((size.height * s).rounded()))
            if s < 1 {
                display = try gpu.downsample(out, width: w, height: h, into: display)
                img = gpu.download(display!)
            } else {
                img = gpu.download(out)
            }
        }
        guard let cg = img.makeCGImage() else { throw GPUError.allocation("display image") }
        return RenderResult(image: cg, histogram: img.histogram(), outputSize: size, region: region)
    }

    /// Small positive for the filmstrip, from the analysis proxy (same conversion, lower resolution).
    func thumbnail(proxy: AnalysisProxy, parameters: ConversionParameters, geometry: FrameGeometry, maxSize: Int) throws -> CGImage? {
        let src = try gpu.upload(proxy.image)
        let flat = try proxy.flat.map { try gpu.upload($0.gain) }
        let o = try gpu.orient(src, geometry: geometry, flatField: flat)
        let c = try gpu.convert(o, parameters: parameters)
        let s = min(1, Double(maxSize) / Double(max(c.width, c.height)))
        let d = s < 1 ? try gpu.downsample(c, width: max(1, Int(Double(c.width) * s)), height: max(1, Int(Double(c.height) * s))) : c
        return gpu.download(d).makeCGImage()
    }
}
