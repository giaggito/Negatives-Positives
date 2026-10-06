// Metal source shared by both apps. Compiled at runtime with precise (non-fast) math.
// Every image texture is rgba32Float; there is no lower-precision format anywhere in either pipeline.

/// Helper functions any app kernel source may prepend.
public let sharedMetalHelpers = #"""
#include <metal_stdlib>
using namespace metal;

static inline float lanczos3(float x) {
    x = fabs(x);
    if (x < 1e-6f) return 1.0f;
    if (x >= 3.0f) return 0.0f;
    float px = M_PI_F * x;
    return 3.0f * precise::sin(px) * precise::sin(px / 3.0f) / (px * px);
}

// Exact area average of the source rectangle [a, b) (source pixel units), edges clamped.
static inline float4 box_average(texture2d<float, access::read> src, float2 a, float2 b) {
    int W = int(src.get_width()), H = int(src.get_height());
    float4 acc = 0; float wsum = 0;
    int y0 = int(floor(a.y)), y1 = int(ceil(b.y)), x0 = int(floor(a.x)), x1 = int(ceil(b.x));
    for (int y = y0; y < y1; y++) {
        float wy = min(b.y, float(y + 1)) - max(a.y, float(y));
        int yy = clamp(y, 0, H - 1);
        for (int x = x0; x < x1; x++) {
            float wx = min(b.x, float(x + 1)) - max(a.x, float(x));
            float w = wx * wy;
            acc += w * src.read(uint2(clamp(x, 0, W - 1), yy));
            wsum += w;
        }
    }
    return acc / max(wsum, 1e-20f);
}
"""#

let sharedMetalSource = sharedMetalHelpers + #"""

// ---------------------------------------------------------------------------------------------
// Geometry: output pixel -> source pixel through an affine map, optional gain-map multiply.
// u[0] = (m00, m10, m01, m11)   column-major 2x2
// u[1] = (tx, ty, srcW, srcH)
// u[2] = (exact, hasGain, emptyOutside, 0)
// Lanczos-3 with an anti-ringing clamp to the 2x2 neighbourhood: sharp, never overshoots the local range.
// ---------------------------------------------------------------------------------------------
kernel void orient(texture2d<float, access::read>   src   [[texture(0)]],
                   texture2d<float, access::sample> flat  [[texture(1)]],
                   texture2d<float, access::write>  dst   [[texture(2)]],
                   constant float4 *u                     [[buffer(0)]],
                   uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 p = float2(gid) + 0.5f;
    float2 s = float2(u[0].x * p.x + u[0].z * p.y + u[1].x,
                      u[0].y * p.x + u[0].w * p.y + u[1].y);
    int W = int(u[1].z), H = int(u[1].w);
    // Optionally, outside the source (corners of a straightened frame) is empty instead of the clamped edge.
    if (u[2].z > 0.5f) if (s.x < 0.0f || s.y < 0.0f || s.x > float(W) || s.y > float(H)) { dst.write(float4(0, 0, 0, 1), gid); return; }
    float3 c;
    if (u[2].x > 0.5f) {
        int2 q = clamp(int2(floor(s)), int2(0), int2(W - 1, H - 1));
        c = src.read(uint2(q)).rgb;
    } else {
        float2 f = s - 0.5f;
        int2 b = int2(floor(f));
        float2 t = f - float2(b);
        float wx[6], wy[6];
        float sx = 0, sy = 0;
        for (int i = 0; i < 6; i++) {
            wx[i] = lanczos3(t.x - float(i - 2)); sx += wx[i];
            wy[i] = lanczos3(t.y - float(i - 2)); sy += wy[i];
        }
        float3 acc = 0;
        float3 lo = float3(INFINITY), hi = float3(-INFINITY);
        for (int j = 0; j < 6; j++) {
            int yy = clamp(b.y + j - 2, 0, H - 1);
            float3 row = 0;
            for (int i = 0; i < 6; i++) {
                int xx = clamp(b.x + i - 2, 0, W - 1);
                float3 v = src.read(uint2(xx, yy)).rgb;
                row += wx[i] * v;
                if ((i == 2 || i == 3) && (j == 2 || j == 3)) { lo = min(lo, v); hi = max(hi, v); }
            }
            acc += wy[j] * row;
        }
        c = clamp(acc / (sx * sy), lo, hi);
    }
    if (u[2].y > 0.5f) {
        constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);
        c *= flat.sample(bilinear, s / float2(W, H)).rgb;
    }
    dst.write(float4(c, 1.0f), gid);
}

// ---------------------------------------------------------------------------------------------
// Area-average downsample, linear light. u[0] = (scaleX, scaleY, originX, originY): source pixels per
// destination pixel and the source origin. Exact box filter with fractional edge weights.
// ---------------------------------------------------------------------------------------------
kernel void downsample(texture2d<float, access::read>  src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float4 *u                  [[buffer(0)]],
                       uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 a = u[0].zw + float2(gid) * u[0].xy;
    dst.write(box_average(src, a, a + u[0].xy), gid);
}
"""#
