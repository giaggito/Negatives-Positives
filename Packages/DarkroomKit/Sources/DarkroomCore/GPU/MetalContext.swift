import Foundation
import Metal
import simd

public enum GPUError: Error, CustomStringConvertible {
    case noDevice, compile(String), allocation(String)
    public var description: String {
        switch self {
        case .noDevice: return "No Metal device"
        case .compile(let s): return "Metal compile error: \(s)"
        case .allocation(let s): return "GPU allocation failed: \(s)"
        }
    }
}

/// The Metal device shared by every app in the family, plus the kernels they all use (high-quality
/// geometry resampling and exact area-average downsampling).
///
/// Rules that hold for every texture made here:
/// - image data is `rgba32Float` (asserted on every pass); single-channel helpers are `r32Float`,
/// - kernels are compiled at runtime with precise (non-fast) math, so log/exp/pow are accurate to float32.
public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let orientPSO, downsamplePSO: MTLComputePipelineState
    /// The geometry kernel, for callers that encode it with their own affine map (see `encodeOrient` for the layout).
    public var orientPipeline: MTLComputePipelineState { orientPSO }

    public static let pixelFormat = MTLPixelFormat.rgba32Float
    /// GPU execution time of the last `run` (seconds), for profiling.
    public private(set) var lastGPUTime: Double = 0
    public static let shared: MetalContext? = try? MetalContext()

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw GPUError.noDevice }
        self.device = device
        self.queue = queue
        let lib = try Self.compile(sharedMetalSource, device: device)
        orientPSO = try Self.pipeline(lib, "orient", device: device)
        downsamplePSO = try Self.pipeline(lib, "downsample", device: device)
    }

    // MARK: Compilation

    /// Compiles Metal source with precise math. Prepend `sharedMetalHelpers` to reuse the common functions.
    public func compile(_ source: String) throws -> MTLLibrary { try Self.compile(source, device: device) }

    public func pipeline(_ lib: MTLLibrary, _ name: String) throws -> MTLComputePipelineState {
        try Self.pipeline(lib, name, device: device)
    }

    static func compile(_ source: String, device: MTLDevice) throws -> MTLLibrary {
        let opts = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            opts.mathMode = .safe
            opts.mathFloatingPointFunctions = .precise
        } else {
            opts.fastMathEnabled = false
        }
        do { return try device.makeLibrary(source: source, options: opts) } catch { throw GPUError.compile("\(error)") }
    }

    static func pipeline(_ lib: MTLLibrary, _ name: String, device: MTLDevice) throws -> MTLComputePipelineState {
        guard let f = lib.makeFunction(name: name) else { throw GPUError.compile("missing \(name)") }
        return try device.makeComputePipelineState(function: f)
    }

    // MARK: Textures

    /// A float texture. `format` must be `rgba32Float` (images) or `r32Float` (single-channel maps).
    public func makeTexture(width: Int, height: Int, format: MTLPixelFormat = MetalContext.pixelFormat,
                            gpuOnly: Bool = false) throws -> MTLTexture {
        precondition(format == .rgba32Float || format == .r32Float || format == .rg32Float, "Only 32-bit float textures are allowed")
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = gpuOnly ? .private : .shared
        guard let t = device.makeTexture(descriptor: d) else { throw GPUError.allocation("\(width)x\(height)") }
        return t
    }

    public func upload(_ image: LinearImage) throws -> MTLTexture {
        let t = try makeTexture(width: image.width, height: image.height)
        image.pixels.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: image.width * 16)
        }
        return t
    }

    public func download(_ t: MTLTexture) -> LinearImage {
        download(t, x: 0, y: 0, width: t.width, height: t.height)
    }

    /// Downloads a sub-rectangle (clamped to the texture).
    public func download(_ t: MTLTexture, x: Int, y: Int, width: Int, height: Int) -> LinearImage {
        precondition(t.pixelFormat == Self.pixelFormat, "Pipeline texture is not 32-bit float RGBA")
        precondition(t.storageMode != .private, "Cannot read a GPU-only texture")
        let x0 = max(0, min(x, t.width - 1)), y0 = max(0, min(y, t.height - 1))
        let w = max(1, min(width, t.width - x0)), h = max(1, min(height, t.height - y0))
        var px = [Float](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            t.getBytes(raw.baseAddress!, bytesPerRow: w * 16, from: MTLRegionMake2D(x0, y0, w, h), mipmapLevel: 0)
        }
        return LinearImage(width: w, height: h, pixels: px)
    }

    // MARK: Encoding

    /// Encodes one compute pass: textures bound in order, `uniforms` at buffer 0, one thread per output pixel.
    public func encode(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, textures: [MTLTexture?],
                       uniforms: [SIMD4<Float>], size: (Int, Int), buffers: [MTLBuffer] = []) {
        for t in textures.compactMap({ $0 }) {
            precondition(t.pixelFormat == .rgba32Float || t.pixelFormat == .r32Float || t.pixelFormat == .rg32Float,
                         "Pipeline texture is not 32-bit float")
        }
        enc.setComputePipelineState(pso)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        var u = uniforms.isEmpty ? [SIMD4<Float>.zero] : uniforms
        enc.setBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * u.count, index: 0)
        for (i, b) in buffers.enumerated() { enc.setBuffer(b, offset: 0, index: i + 1) }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (size.0 + 15) / 16, height: (size.1 + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
    }

    /// Runs `body` with a fresh command buffer + compute encoder, then commits and waits.
    @discardableResult
    public func run<T>(_ body: (MTLComputeCommandEncoder) throws -> T) throws -> T {
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw GPUError.noDevice }
        let r = try body(enc)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw GPUError.allocation("command buffer: \(e)") }
        lastGPUTime = cb.gpuEndTime - cb.gpuStartTime
        return r
    }

    // MARK: Shared passes

    /// Geometry (flip / rotate / straighten / crop / scale) with an optional per-channel gain map
    /// (`flatField`, sampled smoothly over the source). Pixel-exact geometry copies; anything else is
    /// Lanczos-3 with an anti-ringing clamp.
    public func encodeOrient(_ enc: MTLComputeCommandEncoder, src: MTLTexture, dst: MTLTexture, geometry: FrameGeometry,
                             scale: Double = 1, flatField: MTLTexture? = nil, emptyOutside: Bool = false, dummy: MTLTexture) {
        let a = geometry.outputToSource(sourceWidth: src.width, sourceHeight: src.height, scale: scale)
        let exact = geometry.isPixelExact(scale: scale, sourceWidth: src.width, sourceHeight: src.height)
        let u: [SIMD4<Float>] = [
            SIMD4(Float(a.m.columns.0.x), Float(a.m.columns.0.y), Float(a.m.columns.1.x), Float(a.m.columns.1.y)),
            SIMD4(Float(a.t.x), Float(a.t.y), Float(src.width), Float(src.height)),
            SIMD4(exact ? 1 : 0, flatField != nil ? 1 : 0, emptyOutside ? 1 : 0, 0),
        ]
        encode(enc, orientPSO, textures: [src, flatField ?? dummy, dst], uniforms: u, size: (dst.width, dst.height))
    }

    /// - Parameter emptyOutside: pixels that fall outside the source (straightened corners) are black instead of
    ///   repeating the edge.
    public func orient(_ src: MTLTexture, geometry: FrameGeometry, scale: Double = 1, flatField: MTLTexture? = nil,
                       emptyOutside: Bool = false) throws -> MTLTexture {
        let size = geometry.outputSize(sourceWidth: src.width, sourceHeight: src.height)
        let w = max(1, Int((Double(size.width) * scale).rounded())), h = max(1, Int((Double(size.height) * scale).rounded()))
        let dst = try makeTexture(width: w, height: h)
        let dummy = try makeTexture(width: 1, height: 1)
        try run { encodeOrient($0, src: src, dst: dst, geometry: geometry, scale: scale, flatField: flatField, emptyOutside: emptyOutside, dummy: dummy) }
        return dst
    }

    /// Exact area average of the source rectangle `region` (source pixels; default: whole texture) into `dst`.
    public func encodeDownsample(_ enc: MTLComputeCommandEncoder, src: MTLTexture, dst: MTLTexture, region: CGRectLike? = nil) {
        let r = region ?? CGRectLike(x: 0, y: 0, width: Double(src.width), height: Double(src.height))
        let u = [SIMD4<Float>(Float(r.width / Double(dst.width)), Float(r.height / Double(dst.height)), Float(r.x), Float(r.y))]
        encode(enc, downsamplePSO, textures: [src, dst], uniforms: u, size: (dst.width, dst.height))
    }

    /// Exact area-average downsample to `width` × `height`.
    public func downsample(_ src: MTLTexture, width: Int, height: Int, into existing: MTLTexture? = nil) throws -> MTLTexture {
        let dst = try (existing.flatMap { $0.width == width && $0.height == height ? $0 : nil }) ?? makeTexture(width: width, height: height)
        try run { encodeDownsample($0, src: src, dst: dst) }
        return dst
    }
}

/// A rectangle in Double precision without pulling CoreGraphics types into GPU code.
public struct CGRectLike: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
