// Metal source for the pipeline kernels. Compiled at runtime with precise (non-fast) math so that
// log/exp/pow match the Double reference in NegativeModel to float32 accuracy.
// Every texture is rgba32Float; there is no lower-precision format anywhere in the chain.

let metalKernelSource = sharedMetalHelpers + #"""

// ---------------------------------------------------------------------------------------------
// Conversion: the per-pixel negative model (see NegativeModel.swift for the documented formulas).
// u[0] = (1/base.r, 1/base.g, 1/base.b, eRef)
// u[1] = (1/r.r, 1/r.g, 1/r.b, 1/filmGamma)
// u[2] = (o.r, o.g, o.b, monochrome)
// u[3] = (w.r, w.g, w.b, stage)          stage 0 = display positive, 1 = scene-linear, 2 = equivalent density
// u[4..6] = colour matrix columns (xyz)
// u[7] = (exposure, slope, y0, aHigh)
// u[8] = (aLow, kShoulder, kToe, negativeViewScale)
// stage 3 = the untouched negative, camera RGB through the colour matrix (the "before" view)
// u[9..11] = colour model columns, u[12] = (neutral path points n, -, -, -), u[13 + k] = (x_R, x_B, D_G, -):
// FilmCalibration.throughPath
// ---------------------------------------------------------------------------------------------

static inline float through_path(float d, constant float4 *u, int n, int c) {
    int k = 0;
    while (k < n - 2 && d > (c == 0 ? u[14 + k].x : u[14 + k].y)) k++;
    float x0 = c == 0 ? u[13 + k].x : u[13 + k].y, x1 = c == 0 ? u[14 + k].x : u[14 + k].y;
    float t = (d - x0) / max(x1 - x0, 1e-9f);
    return u[13 + k].z + t * (u[14 + k].z - u[13 + k].z);
}

static inline float g_curve(float t, float k) {
    return t / precise::powr(1.0f + precise::powr(t, k), 1.0f / k);
}

static inline float print_curve(float l, constant float4 *u) {
    float x = precise::log2(max(l, 1e-10f) / 0.18f) + u[7].x;
    float slope = u[7].y, y0 = u[7].z, aH = u[7].w, aL = u[8].x;
    float y = (x >= 0.0f) ? y0 + aH * g_curve(slope * x / aH, u[8].y)
                          : y0 - aL * g_curve(-slope * x / aL, u[8].z);
    return precise::exp10(y);
}

kernel void convert(texture2d<float, access::read>  src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float4 *u                  [[buffer(0)]],
                    uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 cam = src.read(gid).rgb;
    if (int(u[3].w) == 3) {
        float3x3 M = float3x3(u[4].xyz, u[5].xyz, u[6].xyz);
        dst.write(float4(M * (cam * u[8].w), 1.0f), gid);
        return;
    }
    float3 T = max(cam * u[0].xyz, float3(1e-4f));   // NegativeModel.transmittanceFloor
    float3 D = -float3(precise::log10(T.x), precise::log10(T.y), precise::log10(T.z));
    float3 e = D * u[1].xyz - u[2].xyz;
    int np = int(u[12].x);
    if (np >= 2) { e.x = through_path(D.x, u, np, 0); e.z = through_path(D.z, u, np, 2); }
    if (u[2].w > 0.5f) e = float3(dot(e, u[3].xyz));
    else e = float3x3(u[9].xyz, u[10].xyz, u[11].xyz) * e;
    int stage = int(u[3].w);
    if (stage == 2) { dst.write(float4(e, 1.0f), gid); return; }
    float3 k = (e - u[0].w) * u[1].w;
    float3 L = float3(precise::exp10(k.x), precise::exp10(k.y), precise::exp10(k.z));
    float3 P = L;
    if (u[2].w < 0.5f) {
        float3x3 M = float3x3(u[4].xyz, u[5].xyz, u[6].xyz);
        P = M * L;
    }
    if (stage == 1) { dst.write(float4(P, 1.0f), gid); return; }
    dst.write(float4(print_curve(P.x, u), print_curve(P.y, u), print_curve(P.z, u), 1.0f), gid);
}
"""#
