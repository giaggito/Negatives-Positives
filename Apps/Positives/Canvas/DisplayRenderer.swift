import Metal
import PositivesCore
import QuartzCore
import simd

/// Draws rendered pieces of the picture into the window's Metal layer.
///
/// The layer is half-float, tagged extended-linear Rec.2020, so the pipeline's float values reach the screen
/// without any 8-bit step on our side (macOS colour-manages them to the display). Above 100 % the image is
/// shown with nearest-neighbour sampling, so single pixels and grain can be judged; at or below 100 % the
/// rendered texture matches the screen grid one to one.
final class DisplayRenderer {
    let context: MetalContext
    private let pipeline: MTLRenderPipelineState

    init(context: MetalContext) throws {
        self.context = context
        let lib = try context.compile(displaySource)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "display_vertex")
        d.fragmentFunction = lib.makeFunction(name: "display_fragment")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try context.device.makeRenderPipelineState(descriptor: d)
    }

    struct Frame {
        /// Drawable pixels of image pixel (0, 0), and drawable pixels per image pixel.
        var origin: SIMD2<Float>
        var magnification: Float
        var imageSize: SIMD2<Float>
        var main: RenderedView?
        var overview: RenderedView?
        var background: SIMD3<Float>
        var showClipping: Bool
        var outputMatrix: simd_float3x3
    }

    func draw(_ f: Frame, in layer: CAMetalLayer) {
        guard let drawable = layer.nextDrawable() else { return }
        encode(f, target: drawable.texture) { $0.present(drawable) }
    }

    /// Same picture into an offscreen half-float texture (self-test snapshots).
    func drawOffscreen(_ f: Frame, width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let t = context.device.makeTexture(descriptor: d) else { return nil }
        encode(f, target: t, wait: true) { _ in }
        return t
    }

    private func encode(_ f: Frame, target: MTLTexture, wait: Bool = false, finish: (MTLCommandBuffer) -> Void) {
        guard let cb = context.queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: Double(f.background.x), green: Double(f.background.y), blue: Double(f.background.z), alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        let m = f.main, o = f.overview
        var u: [SIMD4<Float>] = [
            SIMD4(f.origin.x, f.origin.y, f.magnification, 0),
            SIMD4(f.imageSize.x, f.imageSize.y, m != nil ? 1 : 0, o != nil ? 1 : 0),
            SIMD4(Float(m?.origin.x ?? 0), Float(m?.origin.y ?? 0), Float(m?.scale ?? 1), 0),
            SIMD4(Float(o?.origin.x ?? 0), Float(o?.origin.y ?? 0), Float(o?.scale ?? 1), f.showClipping ? 1 : 0),
            SIMD4(f.background, 0),
            SIMD4(f.outputMatrix.columns.0, 0), SIMD4(f.outputMatrix.columns.1, 0), SIMD4(f.outputMatrix.columns.2, 0),
        ]
        enc.setFragmentBytes(&u, length: MemoryLayout<SIMD4<Float>>.stride * u.count, index: 0)
        enc.setFragmentTexture(m?.texture, index: 0)
        enc.setFragmentTexture(o?.texture, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        finish(cb)
        cb.commit()
        if wait { cb.waitUntilCompleted() }
    }
}

private let displaySource = #"""
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; };

vertex VOut display_vertex(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VOut o; o.pos = float4(p[vid], 0, 1); return o;
}

static inline float4 bilinear(texture2d<float, access::read> t, float2 p) {
    float2 sz = float2(t.get_width(), t.get_height());
    float2 q = p - 0.5f;
    float2 f0 = floor(q), fr = q - f0;
    int2 a = int2(f0), mx = int2(sz) - 1;
    float4 v00 = t.read(uint2(clamp(a, int2(0), mx)));
    float4 v10 = t.read(uint2(clamp(a + int2(1, 0), int2(0), mx)));
    float4 v01 = t.read(uint2(clamp(a + int2(0, 1), int2(0), mx)));
    float4 v11 = t.read(uint2(clamp(a + int2(1, 1), int2(0), mx)));
    return mix(mix(v00, v10, fr.x), mix(v01, v11, fr.x), fr.y);
}

// Samples a rendered piece at image coordinate q; returns false when q is outside it.
static inline bool sample_piece(texture2d<float, access::read> t, float2 org, float s, float m, float2 q, thread float3 &c) {
    float2 p = (q - org) * s;                          // texture pixel coordinates
    float2 sz = float2(t.get_width(), t.get_height());
    if (p.x < 0.0f || p.y < 0.0f || p.x >= sz.x || p.y >= sz.y) return false;
    // One texture pixel per screen pixel or more: exact / nearest. A draft (rendered below the resolution
    // of the view while a slider moves) and the overview are interpolated instead.
    bool draft = s < 0.98f * min(1.0f, m);
    if (!draft && m / s >= 0.999f) c = t.read(uint2(floor(p))).rgb;
    else c = bilinear(t, p).rgb;
    return true;
}

// u0 = (originX, originY, m, -), u1 = (imageW, imageH, hasMain, hasOverview), u2 = main (ox, oy, s, -),
// u3 = overview (ox, oy, s, clipping), u4 = background, u5..u7 = Rec.2020 -> output space (clipping test)
fragment float4 display_fragment(VOut in [[stage_in]],
                                 texture2d<float, access::read> mainTex [[texture(0)]],
                                 texture2d<float, access::read> ovTex   [[texture(1)]],
                                 constant float4 *u                     [[buffer(0)]])
{
    float m = u[0].z;
    float2 q = (in.pos.xy - u[0].xy) / m;
    if (q.x < 0.0f || q.y < 0.0f || q.x >= u[1].x || q.y >= u[1].y) return float4(u[4].rgb, 1);
    float3 c = u[4].rgb * 1.6f;   // not rendered yet: slightly lighter than the canvas
    bool got = false;
    if (u[1].z > 0.5f) got = sample_piece(mainTex, u[2].xy, u[2].z, m, q, c);
    if (!got && u[1].w > 0.5f) got = sample_piece(ovTex, u[3].xy, u[3].z, m, q, c);
    if (u[3].w > 0.5f) {
        float3x3 M = float3x3(u[5].xyz, u[6].xyz, u[7].xyz);
        float3 v = M * c;
        if (max(v.x, max(v.y, v.z)) >= 1.0f) c = float3(1.0f, 0.05f, 0.02f);
        else if (max(v.x, max(v.y, v.z)) <= 1.0f / 4096.0f) c = float3(0.02f, 0.12f, 1.0f);   // crushed to black
    }
    return float4(c, 1);
}
"""#
