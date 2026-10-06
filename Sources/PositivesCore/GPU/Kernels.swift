import Foundation
import simd

// Metal source for the editor. Compiled at runtime with precise math (see MetalContext). Every image
// texture is rgba32Float, every map r32Float / rg32Float. The `develop` kernel is a line-by-line
// transcription of `Develop.pixel` (Develop.swift) — keep them in sync; tests compare them.

private func f(_ v: Float) -> String { String(format: "%.9ef", v) }
private func m3(_ m: simd_float3x3) -> String {
    "float3x3(float3(\(f(m.columns.0.x)), \(f(m.columns.0.y)), \(f(m.columns.0.z))), float3(\(f(m.columns.1.x)), \(f(m.columns.1.y)), \(f(m.columns.1.z))), float3(\(f(m.columns.2.x)), \(f(m.columns.2.y)), \(f(m.columns.2.z))))"
}

/// The film looks' input tone table (ToneMath.lookInputTable), as a Metal constant.
let lookInputSource = "constant float LOOK_IN[257] = {" + ToneMath.lookInputTable.map { String(format: "%.8ff", $0) }.joined(separator: ", ") + "};\n"

let positivesKernelSource: String = sharedMetalHelpers + lookInputSource + """

constant float3 LUMA = float3(\(f(ToneMath.luminance.x)), \(f(ToneMath.luminance.y)), \(f(ToneMath.luminance.z)));
constant float MID_GREY = \(f(ToneMath.middleGrey));
constant float KNEE = \(f(ToneMath.knee));
constant float GAMMA_P = \(f(ToneMath.gammaP));
constant float PIVOT = \(f(ToneMath.pivot));
constant float3x3 TO_LMS = \(m3(ToneMath.toLMS));
constant float3x3 FROM_LMS = \(m3(ToneMath.fromLMS));
constant float3x3 LMS_TO_LAB = \(m3(ToneMath.lmsToLab));
constant float3x3 LAB_TO_LMS = \(m3(ToneMath.labToLMS));
constant float MIX_C[8] = { \(ColorMath.mixerCentres.map { f($0) }.joined(separator: ", ")) };

""" + #"""

static inline float lum(float3 c) { return dot(c, LUMA); }

static inline float shoulder(float x) {
    return x <= KNEE ? x : 1.0f - (1.0f - KNEE) * precise::exp(-(x - KNEE) / (1.0f - KNEE));
}
static inline float shoulder_inv(float y) {
    return y <= KNEE ? y : KNEE - (1.0f - KNEE) * precise::log(max((1.0f - y) / (1.0f - KNEE), 5.96e-8f));
}
static inline float3 shoulder_inv3(float3 c) { return float3(shoulder_inv(c.x), shoulder_inv(c.y), shoulder_inv(c.z)); }

static inline float g_curve(float t, float k) { return t / fast::powr(1.0f + fast::powr(t, k), 1.0f / k); }

// u6 = (exposure, slope, y0, aHigh), u7 = (aLow, kShoulder, kToe, -)
static inline float print_curve(float v, float4 u6, float4 u7) {
    float a = fabs(v);
    float x = fast::log2(max(a, 1e-10f) / MID_GREY) + u6.x;
    float slope = u6.y, y0 = u6.z, aH = u6.w, aL = u7.x;
    float y = (x >= 0.0f) ? y0 + aH * g_curve(slope * x / aH, u7.y)
                          : y0 - aL * g_curve(-slope * x / aL, u7.z);
    float o = fast::exp10(y);
    return v < 0.0f ? -o : o;
}

static inline float to_p(float y) { return y < 0.0f ? -fast::powr(-y, 1.0f / GAMMA_P) : fast::powr(y, 1.0f / GAMMA_P); }
static inline float from_p(float p) { return p < 0.0f ? -fast::powr(-p, GAMMA_P) : fast::powr(p, GAMMA_P); }

static inline float contrast_p(float p, float k) {
    if (p <= 0.0f || p >= 1.0f) return p;
    return p <= PIVOT ? PIVOT * fast::powr(p / PIVOT, k) : 1.0f - (1.0f - PIVOT) * fast::powr((1.0f - p) / (1.0f - PIVOT), k);
}
static inline float whites_blacks(float p, float w, float b) {
    float q = clamp(p, 0.0f, 1.0f);
    float q2 = q * q, r = 1.0f - q, r2 = r * r;
    return p + 0.2f * w * q2 * q2 + 0.2f * b * r2 * r2;
}

static inline float shadows_highlights(float b, float s, float h) {
    float ws = 1.0f / (1.0f + fast::exp(1.2f * (b + 1.4f)));
    float wh = 1.0f / (1.0f + fast::exp(-1.2f * (b - 1.0f)));
    return 2.0f * s * ws + 1.6f * h * wh;
}
static inline float detail_boost(float d, float g) { return 2.0f * fast::tanh(g * d / 2.0f); }
static inline float clarity_weight(float b) { float t = b / 3.0f; return 0.4f + 0.6f / (1.0f + t * t * t * t); }

static inline float cbrt_s(float x) { return x < 0.0f ? -fast::powr(-x, 1.0f / 3.0f) : fast::powr(x, 1.0f / 3.0f); }
static inline float3 oklab(float3 rgb) {
    float3 l = TO_LMS * rgb;
    return LMS_TO_LAB * float3(cbrt_s(l.x), cbrt_s(l.y), cbrt_s(l.z));
}
static inline float3 from_oklab(float3 lab) {
    float3 l = LAB_TO_LMS * lab;
    return FROM_LMS * (l * l * l);
}
static inline float3 preserve_hue(float3 before, float3 after) {
    float3 a = oklab(before), b = oklab(after);
    float ca = length(a.yz), cb = length(b.yz);
    if (ca <= 1e-5f) return after;
    float2 dir = a.yz / ca;
    return from_oklab(float3(b.x, dir * cb));
}
static inline float chroma_gain(float c, float h, float s, float v) {
    float f = 1.0f;
    if (v > 0.0f) {
        float t = clamp(c / 0.22f, 0.0f, 1.0f), muted = 1.0f - t * t * (3.0f - 2.0f * t);
        float dh = (h - 0.87f) / 0.45f;
        float skin = fast::exp(-dh * dh);
        f += v * muted * (1.0f - 0.45f * skin);
    } else if (v < 0.0f) {
        float t = clamp(c / 0.2f, 0.0f, 1.0f);
        f += v * (0.5f + 0.5f * t * t * (3.0f - 2.0f * t));
    }
    return max(0.0f, f * (1.0f + s));
}

// Manual bilinear sample of a coarse map at normalised coordinates (pixel centres at +0.5).
static inline float4 bilinear(texture2d<float, access::read> t, float2 uv) {
    float2 sz = float2(t.get_width(), t.get_height());
    float2 p = uv * sz - 0.5f;
    float2 f0 = floor(p);
    float2 fr = p - f0;
    int2 a = int2(f0);
    int2 mx = int2(sz) - 1;
    float4 v00 = t.read(uint2(clamp(a, int2(0), mx)));
    float4 v10 = t.read(uint2(clamp(a + int2(1, 0), int2(0), mx)));
    float4 v01 = t.read(uint2(clamp(a + int2(0, 1), int2(0), mx)));
    float4 v11 = t.read(uint2(clamp(a + int2(1, 1), int2(0), mx)));
    return mix(mix(v00, v10, fr.x), mix(v01, v11, fr.x), fr.y);
}

// Log luminance (stops from middle grey) of native values through the input matrix. Pre-exposure.
// u0..u2 = matrix columns, u0.w = unrender
static inline float native_loglum(float3 n, constant float4 *u) {
    float3 c = u[0].w > 0.5f ? shoulder_inv3(n) : n;
    float3x3 M = float3x3(u[0].xyz, u[1].xyz, u[2].xyz);
    return fast::log2(max(lum(M * c), 1e-10f) / MID_GREY);
}

// ---------------------------------------------------------------------------------------------
// fetch: render-resolution input from a pyramid level. u[0] = (originX, originY, stepX, stepY) in level px.
// Exact copy when the grid is 1:1 and aligned, otherwise an exact area average of the footprint.
// ---------------------------------------------------------------------------------------------
kernel void fetch(texture2d<float, access::read>  src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant float4 *u                  [[buffer(0)]],
                  uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 a = u[0].xy + float2(gid) * u[0].zw;
    if (u[0].z == 1.0f && u[0].w == 1.0f && all(a == floor(a))) {
        int2 q = clamp(int2(a), int2(0), int2(src.get_width() - 1, src.get_height() - 1));
        dst.write(src.read(uint2(q)), gid);
    } else {
        dst.write(box_average(src, a, a + u[0].zw), gid);
    }
}

// loglum: native rgba -> r32 log luminance (see native_loglum).
kernel void loglum(texture2d<float, access::read>  src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   constant float4 *u                  [[buffer(0)]],
                   uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(native_loglum(src.read(gid).rgb, u), 0, 0, 0), gid);
}

// Separable Gaussian on any float texture. u[0] = (sigma, radius, dx, dy)
kernel void gauss(texture2d<float, access::read>  src [[texture(0)]],
                  texture2d<float, access::write> dst [[texture(1)]],
                  constant float4 *u                  [[buffer(0)]],
                  uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float sigma = u[0].x;
    int r = int(u[0].y);
    int2 d = int2(u[0].zw);
    int2 mx = int2(src.get_width() - 1, src.get_height() - 1);
    float4 acc = 0; float ws = 0;
    for (int i = -r; i <= r; i++) {
        float w = fast::exp(-0.5f * float(i * i) / (sigma * sigma));
        acc += w * src.read(uint2(clamp(int2(gid) + d * i, int2(0), mx)));
        ws += w;
    }
    dst.write(acc / ws, gid);
}

// Box mean over in-bounds samples (He's N(x) normalisation). u[0] = (radius, dx, dy, -)
kernel void boxmean(texture2d<float, access::read>  src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float4 *u                  [[buffer(0)]],
                    uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int r = int(u[0].x);
    int2 d = int2(u[0].yz);
    int2 sz = int2(src.get_width(), src.get_height());
    float4 acc = 0; float n = 0;
    for (int i = -r; i <= r; i++) {
        int2 p = int2(gid) + d * i;
        if (p.x < 0 || p.y < 0 || p.x >= sz.x || p.y >= sz.y) continue;
        acc += src.read(uint2(p)); n += 1.0f;
    }
    dst.write(acc / n, gid);
}

// Separable minimum (dark-channel erosion). u[0] = (radius, dx, dy, -)
kernel void minfilter(texture2d<float, access::read>  src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float4 *u                  [[buffer(0)]],
                      uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int r = int(u[0].x);
    int2 d = int2(u[0].yz);
    int2 mx = int2(src.get_width() - 1, src.get_height() - 1);
    float m = INFINITY;
    for (int i = -r; i <= r; i++) m = min(m, src.read(uint2(clamp(int2(gid) + d * i, int2(0), mx))).x);
    dst.write(float4(m, 0, 0, 0), gid);
}

// Guided filter, step 1: (G, p, G·p, G·G) from guide G and input p (both r32).
kernel void gf_prep(texture2d<float, access::read>  g   [[texture(0)]],
                    texture2d<float, access::read>  p   [[texture(1)]],
                    texture2d<float, access::write> dst [[texture(2)]],
                    uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float G = g.read(gid).x, P = p.read(gid).x;
    dst.write(float4(G, P, G * P, G * G), gid);
}

// Guided filter, step 2: coefficients a = cov(G,p) / (var(G) + eps), b = mean(p) − a·mean(G). u[0].x = eps
kernel void gf_coef(texture2d<float, access::read>  m   [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float4 *u                  [[buffer(0)]],
                    uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 v = m.read(gid);
    float var = max(v.w - v.x * v.x, 0.0f), cov = v.z - v.x * v.y;
    float a = cov / (var + u[0].x);
    dst.write(float4(a, v.y - a * v.x, 0, 0), gid);
}

// Dark channel of the white-balanced scene: min_c(c / A_c). u0..u2 = input matrix (u0.w unrender), u3 = A
kernel void darkchannel(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float4 *u                  [[buffer(0)]],
                        uint2 gid                           [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 n = src.read(gid).rgb;
    float3 c = u[0].w > 0.5f ? shoulder_inv3(n) : n;
    float3x3 M = float3x3(u[0].xyz, u[1].xyz, u[2].xyz);
    float3 v = (M * c) / max(u[3].xyz, float3(1e-6f));
    dst.write(float4(clamp(min(v.x, min(v.y, v.z)), 0.0f, 1.0f), 0, 0, 0), gid);
}

// ---------------------------------------------------------------------------------------------
// Curves and colour tools (ColorMath.swift / CurveMath.swift)
// ---------------------------------------------------------------------------------------------
static inline float curve_lookup(texture2d<float, access::read> lut, float x, int c) {
    int n = int(lut.get_width());
    if (x < 0.0f) return lut.read(uint2(0, 0))[c] + x;
    if (x > 1.0f) return lut.read(uint2(n - 1, 0))[c] + (x - 1.0f);
    float f = x * float(n - 1);
    int i = min(int(f), n - 2);
    float t = f - float(i);
    float a = lut.read(uint2(i, 0))[c], b = lut.read(uint2(i + 1, 0))[c];
    return a + (b - a) * t;
}

static inline float smooth_step(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}
static inline float wrap_angle(float a) {
    while (a > M_PI_F) a -= 2.0f * M_PI_F;
    while (a <= -M_PI_F) a += 2.0f * M_PI_F;
    return a;
}

// u[13 + i] = (hue shift, saturation, luminance, -) for range i
static inline float3 apply_mixer(float3 lab, constant float4 *u) {
    float c = length(lab.yz);
    if (c <= 1e-6f) return lab;
    float h = fast::atan2(lab.z, lab.y);
    float hp = h < 0.0f ? h + 2.0f * M_PI_F : h;
    int i = 7;
    for (int k = 0; k < 7; k++) if (hp >= MIX_C[k] && hp < MIX_C[k + 1]) i = k;
    int j = (i + 1) % 8;
    float span = MIX_C[j] - MIX_C[i];
    float d = hp - MIX_C[i];
    if (span <= 0.0f) span += 2.0f * M_PI_F;
    if (d < 0.0f) d += 2.0f * M_PI_F;
    float t = clamp(d / span, 0.0f, 1.0f);
    float ct = fast::cos(t * M_PI_F / 2.0f);
    float wi = ct * ct;
    float3 adj = u[13 + i].xyz * wi + u[13 + j].xyz * (1.0f - wi);
    float cw = smooth_step(0.0f, 0.06f, c);
    h += adj.x * cw;
    c *= max(0.0f, 1.0f + adj.y);
    float l = lab.x * (1.0f + 0.3f * adj.z * cw);
    return float3(l, c * fast::cos(h), c * fast::sin(h));
}

// target t: u[21 + 2t] = (hue, chroma, core, edge), u[22 + 2t] = (hueShift, saturation, luminance, isolate)
static inline float target_weight(float3 lab, float4 a) {
    float c = length(lab.yz);
    float d = fabs(wrap_angle(fast::atan2(lab.z, lab.y) - a.x));
    float wh = 1.0f - smooth_step(a.z, a.w, d);
    float wc = smooth_step(0.15f * a.y, 0.5f * a.y, c);
    return wh * wc;
}

static inline float3 apply_targets(float3 lab0, int n, constant float4 *u) {
    float3 lab = lab0;
    float selected = 0.0f, isolate = 0.0f;
    for (int t = 0; t < n; t++) {
        float4 a = u[21 + 2 * t], b = u[22 + 2 * t];
        float w = target_weight(lab0, a);
        if (b.w > 0.0f) { selected = max(selected, w); isolate = max(isolate, b.w); }
        if (w <= 0.0f || (b.x == 0.0f && b.y == 0.0f && b.z == 0.0f)) continue;
        float c = length(lab.yz);
        float h = fast::atan2(lab.z, lab.y);
        h += b.x * w;
        c *= max(0.0f, 1.0f + b.y * w);
        lab = float3(lab.x * (1.0f + 0.3f * b.z * w), c * fast::cos(h), c * fast::sin(h));
    }
    if (isolate > 0.0f) lab.yz *= 1.0f - isolate * (1.0f - selected);
    return lab;
}

// u[29..32] = shadows, midtones, highlights, global (a, b, L, -); u[33] = (shadowCentre, highlightCentre, halfWidth, -)
static inline float3 apply_grading(float3 lab, constant float4 *u) {
    float l = lab.x;
    float4 z = u[33];
    float ws = 1.0f - smooth_step(z.x - z.z, z.x + z.z, l);
    float wh = smooth_step(z.y - z.z, z.y + z.z, l);
    float wm = max(0.0f, 1.0f - ws - wh);
    float3 o = u[29].xyz * ws + u[30].xyz * wm + u[31].xyz * wh + u[32].xyz;
    float fade = min(1.0f, max(l, 0.0f) / 0.15f);
    return float3(l + o.z, lab.y + o.x * fade, lab.z + o.y * fade);
}

// ---------------------------------------------------------------------------------------------
// develop: the per-pixel chain (Develop.pixel). Textures: native, fine blur (log lum), base coef,
// mid coef, dark coef, output.
// u0..u2 = input matrix cols; u0.w unrender, u1.w exposureGain, u2.w exposureStops
// u3 = (shadows, highlights, clarityGain, textureGain)
// u4 = (dehaze, A.r, A.g, A.b)
// u5 = (profileKind, contrastSlope, whites, blacks)
// u6, u7 = print curve; u7.w = flags bits: 1 identity, 2 tone, 4 colour, 8 local, 16 clarity, 32 texture
// u8 = (saturation, vibrance, -, -)
// u9 = (originX, originY, stepX, stepY) full-res px of render pixel 0 / per render pixel
// u10 = (fullW, fullH, -, -)
// ---------------------------------------------------------------------------------------------
// ---------------------------------------------------------------------------------------------
// Film simulation (FilmModel.swift has the documented CPU reference).
// Spectral buffer: [0,41) film dye (c,m,y) + base, [41,82) print weights, [82,123) paper dye + base,
// [123,164) viewing weights (X,Y,Z), [164,205) scanner bands (R,G,B).
// u34 = (filmKind 0 none / 1 negative / 2 slide / 3 B&W, intensity, paperGamma, hasBloom)
// u35 = (logEMin, logEStep, paperLogEMin, paperLogEStep)
// u36..u38 = coupler matrix transposed (columns); u39 = (log10 k, gain); u40 = (paper mid, hasHalation)
// u41..u43 = XYZ -> Rec.2020 (columns); u44 = (densityMax, grainActive); u45 = halation strength;
// u46 = bloom tint × amount; u47 = (k, -, -, colourMix); u48 = (field correlation, normalisation, softness, -)
// u49 = vignette (amount, midpoint, feather, roundness); u50 = (highlights, aspect, hasVignette, -)
// ---------------------------------------------------------------------------------------------
static inline float3 film_exposure(texture2d<float, access::read> t, float3 rgb) {
    float3 c = max(rgb, 0.0f);
    float s = c.x + c.y + c.z;
    if (s <= 1e-10f) return 0.0f;
    int n = int(t.get_width());
    float g = float(n - 1);
    float x = c.x / s * g, y = c.y / s * g;
    int i = min(int(x), n - 2), j = min(int(y), n - 2);
    float tx = x - float(i), ty = y - float(j);
    float3 v00 = t.read(uint2(j, i)).rgb, v01 = t.read(uint2(j + 1, i)).rgb;
    float3 v10 = t.read(uint2(j, i + 1)).rgb, v11 = t.read(uint2(j + 1, i + 1)).rgb;
    return ((v00 * (1.0f - ty) + v01 * ty) * (1.0f - tx) + (v10 * (1.0f - ty) + v11 * ty) * tx) * s;
}

static inline float table_lookup(texture2d<float, access::read> t, int row, float x, float mn, float step, int c) {
    int n = int(t.get_width());
    float f = (x - mn) / step;
    if (f <= 0.0f) return t.read(uint2(0, row))[c];
    if (f >= float(n - 1)) return t.read(uint2(n - 1, row))[c];
    int i = int(f);
    float tt = f - float(i);
    float a = t.read(uint2(i, row))[c], b = t.read(uint2(i + 1, row))[c];
    return a + (b - a) * tt;
}

static inline float3 film_develop(texture2d<float, access::read> curves, float3 e, constant float4 *u) {
    float3 logE = float3(precise::log10(max(e.x, 1e-10f)), precise::log10(max(e.y, 1e-10f)), precise::log10(max(e.z, 1e-10f)));
    float3 d0;
    for (int c = 0; c < 3; c++) d0[c] = table_lookup(curves, 0, logE[c], u[35].x, u[35].y, c);
    float3 silver = int(u[34].x) == 2 ? u[44].xyz - d0 : d0;
    float3x3 MT = float3x3(u[36].xyz, u[37].xyz, u[38].xyz);
    logE -= MT * silver;
    float3 d;
    for (int c = 0; c < 3; c++) d[c] = table_lookup(curves, 1, logE[c], u[35].x, u[35].y, c);
    return d;
}

static inline float3 spectral_view(constant float4 *spec, int dye, float3 dens, constant float4 *u) {
    float3 xyz = 0;
    for (int i = 0; i < 41; i++) {
        float4 dy = spec[dye + i];
        float r = fast::exp10(-(dot(dens, dy.xyz) + dy.w));
        xyz += r * spec[123 + i].xyz;
    }
    return float3x3(u[41].xyz, u[42].xyz, u[43].xyz) * xyz;
}

static inline float3 film_print(constant float4 *spec, texture2d<float, access::read> paper, float3 d, constant float4 *u) {
    float3 p = 0;
    for (int i = 0; i < 41; i++) {
        float4 dy = spec[i];
        float t = fast::exp10(-(dot(d, dy.xyz) + dy.w));
        p += t * spec[41 + i].xyz;
    }
    p *= float3(fast::exp10(u[39].x), fast::exp10(u[39].y), fast::exp10(u[39].z));
    float3 dp;
    for (int c = 0; c < 3; c++) {
        float lp = precise::log10(max(p[c], 1e-10f));
        lp = (lp - u[40][c]) * u[34].z + u[40][c];
        dp[c] = table_lookup(paper, 0, lp, u[35].z, u[35].w, c);
    }
    return spectral_view(spec, 82, dp, u);
}

// Lab scan of a negative: u51 = (density of middle grey, isScan), u52 = (1 / mid gamma), u53..u55 = film
// exposure -> scene Rec.2020 (columns), u56/u57 = the scanner's tone curve (print_curve layout).
static inline float3 film_scan(constant float4 *spec, float3 dye, constant float4 *u) {
    float3 r = 0;
    for (int i = 0; i < 41; i++) {
        float4 dy = spec[i];
        r += fast::exp10(-(dot(dye, dy.xyz) + dy.w)) * spec[164 + i].xyz;
    }
    float3 d = float3(-precise::log10(max(r.x, 1e-10f)), -precise::log10(max(r.y, 1e-10f)), -precise::log10(max(r.z, 1e-10f)));
    float3 ex = float3(fast::exp10((d.x - u[51].x) * u[52].x), fast::exp10((d.y - u[51].y) * u[52].y), fast::exp10((d.z - u[51].z) * u[52].z));
    float3 rgb = float3x3(u[53].xyz, u[54].xyz, u[55].xyz) * ex;
    float3 t = float3(print_curve(rgb.x, u[56], u[57]), print_curve(rgb.y, u[56], u[57]), print_curve(rgb.z, u[56], u[57]));
    if (u[52].w == 1.0f) return t;
    float3 lab = oklab(t);
    lab.yz *= u[52].w;
    return from_oklab(lab);
}

// Slides: colour fades out towards black (projection flare / adaptation), see FilmModel.neutralBlacks.
static inline float3 neutral_blacks(float3 c) {
    float3 lab = oklab(max(c, 0.0f));
    float t = clamp((lab.x - 0.15f) / 0.3f, 0.0f, 1.0f);
    lab.yz *= t * t * (3.0f - 2.0f * t);
    return from_oklab(lab);
}

// Grain on a density. Two grain fields of the same grains (`grain_boolean`): a sparse population, used in
// thin parts of the film, and a dense one (a superset), used where the film is dense; each normalised to zero
// mean and unit variance (u48.x = their correlation, u48.y = extra normalisation of the Gaussian fallback).
// x is shared by the three dye layers, yzw are each layer's own grains; u47.w = how independent they are.
// The density fluctuation has variance D·k (shot noise; k for this render pixel size, u47.x), times g (masks).
static inline float3 add_grain(float3 D, float4 ns, float4 nd, constant float4 *u, float g) {
    float m = u[47].w;
    float a = sqrt(max(1.0f - m, 0.0f)), b = sqrt(m);
    // u48.w: correlation of a layer's own grains with all grains (they are part of them).
    float k = rsqrt(1.0f + 2.0f * a * b * u[48].w);
    float3 Ns = (a * ns.x + b * ns.yzw) * k;
    float3 Nd = (a * nd.x + b * nd.yzw) * k;
    float3 Dp = max(D, 0.0f);
    float3 w = smoothstep(0.2f, 1.4f, Dp);
    float rho = u[48].x;
    float3 nrm = rsqrt(max((1.0f - w) * (1.0f - w) + w * w + 2.0f * rho * w * (1.0f - w), 1e-4f));
    float3 N = (Ns * (1.0f - w) + Nd * w) * nrm * u[48].y;
    return D + g * sqrt(Dp * u[47].x) * N;
}

// Film looks: colour tables in sRGB (u58 = (active, table size, grain curve, grain visibility), u59.xyz = print
// filtration gains). See FilmLooks.swift and LookRender.apply.
constant float3x3 SRGB_TO_REC2020 = float3x3(float3(0.6274040f, 0.0690970f, 0.0163916f), float3(0.3292820f, 0.9195400f, 0.0880132f), float3(0.0433136f, 0.0113612f, 0.8955950f));
constant float3x3 REC2020_TO_SRGB = float3x3(float3(1.6604903f, -0.1245500f, -0.0181511f), float3(-0.5876391f, 1.1328999f, -0.1005787f), float3(-0.0728516f, -0.0083480f, 1.1187299f));
static inline float lk_enc(float x) { return x <= 0.0031308f ? 12.92f * x : 1.055f * powr(x, 1.0f / 2.4f) - 0.055f; }
static inline float lk_dec(float x) { return x <= 0.04045f ? x / 12.92f : powr((x + 0.055f) / 1.055f, 2.4f); }

static inline float3 look_table(texture3d<float, access::read> t, float3 e) {
    int n = int(t.get_width());
    float3 x = clamp(e, 0.0f, 1.0f) * float(n - 1);
    int3 i = min(int3(x), int3(n - 2));
    float3 f = x - float3(i);
    uint3 a = uint3(i);
    float3 c000 = t.read(a).rgb, c100 = t.read(a + uint3(1, 0, 0)).rgb;
    float3 c010 = t.read(a + uint3(0, 1, 0)).rgb, c110 = t.read(a + uint3(1, 1, 0)).rgb;
    float3 c001 = t.read(a + uint3(0, 0, 1)).rgb, c101 = t.read(a + uint3(1, 0, 1)).rgb;
    float3 c011 = t.read(a + uint3(0, 1, 1)).rgb, c111 = t.read(a + uint3(1, 1, 1)).rgb;
    float3 c00 = mix(c000, c100, f.x), c10 = mix(c010, c110, f.x), c01 = mix(c001, c101, f.x), c11 = mix(c011, c111, f.x);
    return mix(mix(c00, c10, f.y), mix(c01, c11, f.y), f.z);
}

// ToneMath.lookInput: camera-like tone for the tables (perceptual units, per channel).
static inline float look_in1(float y) {
    float q = to_p(y);
    if (q <= 0.0f || q >= 1.0f) return y;
    float f = q * 256.0f;
    int i = min(int(f), 255);
    return from_p(LOOK_IN[i] + (LOOK_IN[i + 1] - LOOK_IN[i]) * (f - float(i)));
}
static inline float3 look_input(float3 c) { return float3(look_in1(c.x), look_in1(c.y), look_in1(c.z)); }

static inline float3 look_apply(texture3d<float, access::read> t, float3 c) {
    float3 l = REC2020_TO_SRGB * c;
    float y = lum(c);
    float lo = min(l.x, min(l.y, l.z));
    if (lo < 0.0f) {
        float k = y > 0.0f ? min(1.0f, y / (y - lo)) : 0.0f;
        l = float3(max(y, 0.0f)) + (l - float3(y)) * k;
    }
    l = clamp(l, 0.0f, 1.0f);
    float3 o = look_table(t, float3(lk_enc(l.x), lk_enc(l.y), lk_enc(l.z)));
    return SRGB_TO_REC2020 * float3(lk_dec(o.x), lk_dec(o.y), lk_dec(o.z));
}

// Grain for film looks: grain lives in the negative's (or slide's) density, so it is added there and
// carried back to exposure through the slope of a typical characteristic curve of the film type — the
// look's tone curve then shapes it as the print would. x = log10 exposure relative to middle grey.
static inline float3 look_grain(float3 c, float4 nc, float4 nf, constant float4 *u, float g) {
    int type = int(u[58].z);
    float3 x = type == 2 ? float3(fast::log10(max(lum(c), 1e-6f) / 0.184f))
                         : float3(fast::log10(max(c.x, 1e-6f) / 0.184f), fast::log10(max(c.y, 1e-6f) / 0.184f), fast::log10(max(c.z, 1e-6f) / 0.184f));
    float3 D, slope;
    float floorSlope;
    if (type == 1) {
        float k = 1.9f, x0 = -0.45f;
        float3 sg = 1.0f / (1.0f + fast::exp(-k * (x - x0)));
        D = 0.15f + 3.35f * (1.0f - sg);
        slope = -3.35f * k * sg * (1.0f - sg);
        floorSlope = 0.3f * 1.6f;
    } else {
        float g = type == 2 ? 0.65f : 0.6f;
        float3 z = 3.0f * (x + 1.25f);
        float3 sp = select(fast::log(1.0f + fast::exp(z)), z, z > 20.0f) / 3.0f;
        D = 0.25f + g * sp;
        slope = g / (1.0f + fast::exp(-z));
        floorSlope = 0.3f * g;
    }
    float3 dD = add_grain(D, nc, nf, u, g) - D;
    float3 s = sign(slope) * max(fabs(slope), floorSlope);
    float3 dx = dD / s * u[58].w;
    if (type == 2) dx = float3(dx.x);
    return max(c, 0.0f) * float3(fast::exp10(dx.x), fast::exp10(dx.y), fast::exp10(dx.z));
}

// Fujifilm-style Color Chrome effects (ColorMath.colorChrome).
static inline float cc_smooth(float a, float b, float x) { float t = clamp((x - a) / (b - a), 0.0f, 1.0f); return t * t * (3.0f - 2.0f * t); }
static inline float3 color_chrome(float3 l, float strength, float blue) {
    float c = length(l.yz);
    if (c <= 1e-5f) return l;
    float dark = 0.0f, boost = 0.0f;
    if (strength > 0.0f) {
        float w = cc_smooth(0.07f, 0.2f, c) * cc_smooth(0.12f, 0.35f, l.x);
        dark += 0.14f * strength * w; boost += 0.06f * strength * w;
    }
    if (blue > 0.0f) {
        float h = atan2(l.z, l.y);
        float dh = atan2(sin(h + 1.85f), cos(h + 1.85f));
        float wh = max(0.0f, cos(dh * 1.6f));
        float w = wh * wh * cc_smooth(0.025f, 0.1f, c) * cc_smooth(0.12f, 0.35f, l.x);
        dark += 0.18f * blue * w; boost += 0.1f * blue * w;
    }
    l.x *= 1.0f - dark;
    l.yz *= 1.0f + boost;
    return l;
}


static inline float3 vignette(float3 d, float2 uv, constant float4 *u) {
    float amount = u[49].x, r = u[49].w, aspect = u[50].y;
    float2 p = (uv - 0.5f) * 2.0f;
    float sx = r > 0.0f ? mix(1.0f, aspect, r) : 1.0f;
    float e = 2.0f + 6.0f * max(0.0f, -r);
    float2 q = float2(fabs(p.x) * sx, fabs(p.y));
    float dist = powr(powr(q.x, e) + powr(q.y, e), 1.0f / e) / powr(powr(sx, e) + 1.0f, 1.0f / e);
    float m0 = u[49].y, fw = u[49].z;
    float w = smooth_step(m0, m0 + fw, dist);
    float k = fast::exp2(1.6f * amount * w);
    if (amount < 0.0f && u[50].x > 0.0f) k = mix(k, 1.0f, u[50].x * smooth_step(0.3f, 1.0f, lum(d)));
    return d * k;
}

static inline uint pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
static inline float gauss_rand(int2 cell, uint seed, uint k) {
    uint h1 = pcg(uint(cell.x + 1048576) ^ pcg(uint(cell.y + 1048576) ^ pcg(seed * 16u + k)));
    uint h2 = pcg(h1 ^ 0x9E3779B9u);
    float a = (float(h1 >> 8) + 0.5f) / 16777216.0f, b = (float(h2 >> 8) + 0.5f) / 16777216.0f;
    return sqrt(-2.0f * fast::log(a)) * fast::cos(2.0f * M_PI_F * b);
}

// White Gaussian grain noise, one value per grain cell (= render pixel), keyed on film position so it is the
// same in every view and export. u0 = (originX, originY, step, scale), u1 = (seed, -, -, -)
kernel void grain_noise(texture2d<float, access::write> coarse [[texture(0)]],
                        texture2d<float, access::write> fine   [[texture(1)]],
                        constant float4 *u                     [[buffer(0)]],
                        uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= coarse.get_width() || gid.y >= coarse.get_height()) return;
    float2 x = u[0].xy + (float2(gid) + 0.5f) * u[0].z;
    int2 cell = int2(floor(x * u[0].w));
    uint seed = uint(u[1].x);
    coarse.write(float4(gauss_rand(cell, seed, 0), gauss_rand(cell, seed, 1), gauss_rand(cell, seed, 2), gauss_rand(cell, seed, 3)), gid);
    fine.write(float4(gauss_rand(cell, seed, 4), gauss_rand(cell, seed, 5), gauss_rand(cell, seed, 6), gauss_rand(cell, seed, 7)), gid);
}

// Grain as it physically is (Newson et al. 2017, "Realistic film grain rendering"): a Boolean model — discs
// of log-normal radius placed by a Poisson process on the film (micrometres, so every view and the export
// show the same grains) — seen through a Gaussian of the scan / pixel blur. Each layer's transmittance is the
// product of (1 − coverage) of the grains near the pixel. Dense grains have intensity λd; the sparse
// population keeps each of them with probability λs/λd (same grains, fewer). Written normalised.
// u0 = (originX, originY, step, µm per output px); u1 = (seed, median radius, σ of ln radius, filter σ);
// u2 = (λs, λd per µm², cell size, reach); u3 = (mean s, 1/std s, mean d, 1/std d); u4 = (layers, max radius)
static inline float disc_cov(float d, float r, float sf) {
    float edge = 1.0f / (1.0f + fast::exp(1.702f * (d - r) / sf));
    float s2 = sf * sf + 0.25f * r * r;
    float blob = min(1.0f, 0.5f * r * r / s2) * fast::exp(-0.5f * d * d / s2);
    return mix(blob, edge, smoothstep(0.6f, 1.6f, r / sf));
}

static inline float urand(thread uint &h) { h = pcg(h + 0x9E3779B9u); return (float(h >> 8) + 0.5f) / 16777216.0f; }

// Pass 1 — the grains of each cell of a grid (absolute film cells, so every view and band agrees): a Poisson
// number (≤ 8) of grains, each (centre x, y in µm, radius, kept in the sparse population (1 / 0) + 2 × its dye
// layer 0…2).
// u0 = (first cell x, first cell y, cells across, cells down), u1 = (seed, median radius, σ ln radius, cell µm),
// u2 = (mean grains per cell, sparse keep probability, max radius, -).
kernel void grain_cells(constant float4 *u     [[buffer(0)]],
                        device float4 *grains  [[buffer(1)]],
                        device uint *counts    [[buffer(2)]],
                        uint2 gid              [[thread_position_in_grid]])
{
    if (gid.x >= uint(u[0].z) || gid.y >= uint(u[0].w)) return;
    int cx = int(u[0].x) + int(gid.x), cy = int(u[0].y) + int(gid.y);
    uint seed = uint(u[1].x);
    float rmed = u[1].y, sl = u[1].z, cell = u[1].w;
    uint ls = pcg(seed * 2654435761u + 83492791u);
    uint h = pcg(uint(cx) * 73856093u ^ pcg(uint(cy) * 19349663u ^ ls));
    float L = fast::exp(-u[2].x);
    int n = 0;
    float prod = urand(h);
    while (prod > L && n < 8) { n++; prod *= urand(h); }
    uint idx = gid.y * uint(u[0].z) + gid.x;
    counts[idx] = uint(n);
    for (int k = 0; k < n; k++) {
        uint g = pcg(h + uint(k) * 0x632BE5ABu);
        float2 c = (float2(cx, cy) + float2(float(g >> 8), float(pcg(g) >> 8)) / 16777216.0f) * cell;
        uint g2 = pcg(g ^ 0xA511E9B3u), g3 = pcg(g2);
        float z = sqrt(-2.0f * fast::log((float(g2 >> 8) + 0.5f) / 16777216.0f)) * fast::cos(6.2831853f * float(g3 >> 8) / 16777216.0f);
        float r = min(rmed * fast::exp(sl * z), u[2].z);
        uint g4 = pcg(g3);
        float keep = float(g4 >> 8) / 16777216.0f < u[2].y ? 1.0f : 0.0f;
        float layer = float(pcg(g4) % 3u);   // the dye layer the grain belongs to
        grains[idx * 8u + uint(k)] = float4(c, r, keep + 2.0f * layer);
    }
}

// Pass 2 — each pixel's transmittance through the grains near it, normalised: x = all grains (sparse / dense
// population), yzw = the grains of each dye layer (colour grain: each layer has its own dye clouds).
// u0 = (originX, originY, step, µm per output px), u1 = (first cell x, first cell y, cells across, cells down),
// u2 = (cell µm, filter σ µm, reach µm, layers 1 / 3), u3 = (mean s, 1/std s, mean d, 1/std d),
// u4 = (mean of one layer, 1/std, -, -).
kernel void grain_boolean(texture2d<float, access::write> sparse [[texture(0)]],
                          texture2d<float, access::write> dense  [[texture(1)]],
                          constant float4 *u                          [[buffer(0)]],
                          device const float4 *grains                 [[buffer(1)]],
                          device const uint *counts                   [[buffer(2)]],
                          uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= sparse.get_width() || gid.y >= sparse.get_height()) return;
    float2 p = (u[0].xy + (float2(gid) + 0.5f) * u[0].z) * u[0].w;
    float cell = u[2].x, sf = u[2].y, reach = u[2].z;
    int2 g0 = int2(u[1].xy), gn = int2(u[1].zw);
    int2 c0 = max(int2(floor((p - reach) / cell)) - g0, int2(0)), c1 = min(int2(floor((p + reach) / cell)) - g0, gn - 1);
    float Ts = 1.0f, Td = 1.0f;
    float3 Tl = 1.0f;
    for (int cy = c0.y; cy <= c1.y; cy++) {
        for (int cx = c0.x; cx <= c1.x; cx++) {
            uint idx = uint(cy * gn.x + cx);
            uint n = counts[idx];
            for (uint k = 0; k < n; k++) {
                float4 gr = grains[idx * 8u + k];
                float2 dv = p - gr.xy;
                float lim = gr.z + 2.5f * sf;
                float d2 = dot(dv, dv);
                if (d2 > lim * lim) continue;
                float t = 1.0f - disc_cov(sqrt(d2), gr.z, sf);
                Td *= t;
                float kl = floor(gr.w * 0.5f);
                if (gr.w - 2.0f * kl > 0.5f) Ts *= t;
                if (kl < 0.5f) Tl.x *= t; else if (kl < 1.5f) Tl.y *= t; else Tl.z *= t;
            }
        }
    }
    // x: the grain structure; yzw: each dye layer's own (Gaussian, already blurred) noise, normalised.
    float3 own = u[2].w > 1.5f ? (Tl - u[4].x) * u[4].y : float3(0.0f);
    sparse.write(float4((Ts - u[3].x) * u[3].y, own), gid);
    dense.write(float4((Td - u[3].z) * u[3].w, own), gid);
}

// Sources of the light effects at a coarse pyramid level. mode 1: bloom (scene light above a threshold);
// mode 2: halation (film exposure). u0..u2 = input matrix (u0.w unrender), u3 = (exposureGain, threshold, filmGain, mode)
kernel void glow_source(texture2d<float, access::read>  src  [[texture(0)]],
                        texture2d<float, access::read>  elut [[texture(1)]],
                        texture2d<float, access::write> o    [[texture(2)]],
                        constant float4 *u                   [[buffer(0)]],
                        uint2 gid                            [[thread_position_in_grid]])
{
    if (gid.x >= o.get_width() || gid.y >= o.get_height()) return;
    float3 n = src.read(gid).rgb;
    float3 c = u[0].w > 0.5f ? shoulder_inv3(n) : n;
    c = float3x3(u[0].xyz, u[1].xyz, u[2].xyz) * c * u[3].x;
    if (int(u[3].w) == 1) {
        float y = max(lum(c), 0.0f), t = u[3].y;
        o.write(float4(max(c, 0.0f) * smooth_step(t, 2.0f * t, y), 1.0f), gid);
    } else if (int(u[3].w) == 3) {
        o.write(float4(max(c, 0.0f), 1.0f), gid);
    } else {
        o.write(float4(film_exposure(elut, c) * u[3].z, 1.0f), gid);
    }
}

// out = (w.x·a + w.y·b + w.z·c) / (w.x + w.y + w.z)
kernel void combine3(texture2d<float, access::read>  a [[texture(0)]],
                     texture2d<float, access::read>  b [[texture(1)]],
                     texture2d<float, access::read>  c [[texture(2)]],
                     texture2d<float, access::write> o [[texture(3)]],
                     constant float4 *u                [[buffer(0)]],
                     uint2 gid                         [[thread_position_in_grid]])
{
    if (gid.x >= o.get_width() || gid.y >= o.get_height()) return;
    o.write((u[0].x * a.read(gid) + u[0].y * b.read(gid) + u[0].z * c.read(gid)) / (u[0].x + u[0].y + u[0].z), gid);
}

// The digital rendering: tone profile per channel, hue restored to the scene colour.
static inline float3 digital_render(float3 c, int kind, constant float4 *u) {
    float3 s = c;
    for (int k = 0; k < 3; k++) {
        if (kind == 1) s[k] = print_curve(s[k], u[6], u[7]);
        else if (kind == 2) s[k] = s[k] < 0.0f ? s[k] : shoulder(s[k]);
    }
    if (any(s != c)) {
        float3 ls = oklab(s), a = oklab(c);
        float ca = length(a.yz);
        if (ca > 1e-5f) ls.yz = a.yz / ca * length(ls.yz);
        s = from_oklab(ls);
    }
    return s;
}


// MARK: Masks
// Mask weights for a view: m0 = (mask count, -, bitmap u scale, bitmap v scale) (sensor/long side -> bitmap uv),
// m1 = output px -> sensor/long side matrix columns (a, b), m2 = (tx, ty, -, -); per mask i: m[3 + i] =
// (first part, part count, invert, -); per part j (base 11 + 4j): (kind, mode, invert, bitmap slice), then
// parameters: linear (ax, ay, bx, by); radial (cx, cy, rx, ry), (cos, sin, inner, -); luminance (low, high,
// smoothness); colour target (hue, chroma, core, edge). Kinds: 0 brush, 1 linear, 2 radial, 3 luminance,
// 4 colour, 5 subject, 6 people. Modes: 0 add, 1 subtract, 2 intersect. See MaskMath.
static inline float mk_smooth(float a, float b, float x) {
    if (b <= a) return x >= b ? 1.0f : 0.0f;
    float t = clamp((x - a) / (b - a), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

kernel void mask_eval(texture2d<float, access::read>       nat   [[texture(0)]],
                      texture2d_array<float, access::write> outw  [[texture(1)]],
                      texture2d_array<float, access::sample> bmp  [[texture(2)]],
                      constant float4 *u                         [[buffer(0)]],
                      constant float4 *m                         [[buffer(1)]],
                      uint2 gid                                  [[thread_position_in_grid]])
{
    if (gid.x >= outw.get_width() || gid.y >= outw.get_height()) return;
    constexpr sampler bs(coord::normalized, address::clamp_to_edge, filter::linear);
    // The pixel as the default rendering shows it (for luminance / colour ranges).
    float3 n = nat.read(gid).rgb;
    float3 c = u[0].w > 0.5f ? shoulder_inv3(n) : n;
    c = float3x3(u[0].xyz, u[1].xyz, u[2].xyz) * c * u[1].w;
    float3 lab = oklab(digital_render(c, int(u[5].x), u));
    float2 po = u[9].xy + (float2(gid) + 0.5f) * u[9].zw;
    float2 sp = float2(dot(float2(m[1].x, m[1].z), po), dot(float2(m[1].y, m[1].w), po)) + m[2].xy;
    int nm = int(m[0].x);
    for (int i = 0; i < nm; i++) {
        float w = 0.0f;
        int first = int(m[3 + i].x), count = int(m[3 + i].y);
        for (int j = first; j < first + count; j++) {
            float4 h = m[11 + 4 * j], a = m[12 + 4 * j], b = m[13 + 4 * j];
            int kind = int(h.x);
            float v = 0.0f;
            if (kind == 1) {
                float2 d = a.zw - a.xy;
                float t = dot(sp - a.xy, d) / max(dot(d, d), 1e-12f);
                v = 1.0f - mk_smooth(0.0f, 1.0f, t);
            } else if (kind == 2) {
                float2 q = sp - a.xy;
                float2 r2 = float2(q.x * b.x + q.y * b.y, -q.x * b.y + q.y * b.x);
                float r = length(r2 / max(a.zw, float2(1e-6f)));
                v = 1.0f - mk_smooth(b.z, 1.0f, r);
            } else if (kind == 3) {
                float l = lab.x * 100.0f, sm = max(a.z, 0.5f);
                v = mk_smooth(a.x - sm, a.x, l) * (1.0f - mk_smooth(a.y, a.y + sm, l));
            } else if (kind == 4) {
                v = target_weight(lab, a);
            } else {
                v = bmp.sample(bs, sp * m[0].zw, uint(h.w)).x;
            }
            if (h.z > 0.5f) v = 1.0f - v;
            int mode = int(h.y);
            w = mode == 0 ? max(w, v) : (mode == 1 ? w * (1.0f - v) : w * v);
        }
        if (m[3 + i].z > 0.5f) w = 1.0f - w;
        outw.write(float4(w), gid, uint(i));
    }
}

// Brush: coverage of up to 16 stroke segments (a round tip, feathered from `inner` to `radius`, in bitmap px)
// over a box, kept as the maximum in `alpha`. u0 = (box x, box y, radius, inner), u1 = (flow, segments, -, -),
// u2… = segments (ax, ay, bx, by).
kernel void brush_segments(texture2d<float, access::read_write> alpha [[texture(0)]],
                           constant float4 *u                         [[buffer(0)]],
                           uint2 gid                                  [[thread_position_in_grid]])
{
    uint2 q = uint2(u[0].xy) + gid;
    if (q.x >= alpha.get_width() || q.y >= alpha.get_height()) return;
    float2 p = float2(q) + 0.5f;
    float d = 1e30f;
    int ns = int(u[1].y);
    for (int i = 0; i < ns; i++) {
        float2 a = u[2 + i].xy, b = u[2 + i].zw, ab = b - a;
        float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-9f), 0.0f, 1.0f);
        d = min(d, length(p - (a + t * ab)));
    }
    float cov = u[1].x * (1.0f - mk_smooth(u[0].w, u[0].z, d));
    if (cov > 0.0f) alpha.write(float4(max(alpha.read(q).x, cov)), q);
}

// Puts a stroke's coverage into the mask: painting m + (1 − m)·a, erasing m·(1 − a). u0 = (box x, box y, erase, slice).
kernel void brush_composite(texture2d_array<float, access::read_write> mask  [[texture(0)]],
                            texture2d<float, access::read_write>       alpha [[texture(1)]],
                            constant float4 *u                               [[buffer(0)]],
                            uint2 gid                                        [[thread_position_in_grid]])
{
    uint2 q = uint2(u[0].xy) + gid;
    if (q.x >= alpha.get_width() || q.y >= alpha.get_height()) return;
    float a = alpha.read(q).x;
    if (a <= 0.0f) return;
    alpha.write(float4(0.0f), q);
    uint s = uint(u[0].w);
    float v = mask.read(q, s).x;
    v = u[0].z > 0.5f ? v * (1.0f - a) : v + (1.0f - v) * a;
    mask.write(float4(v), q, s);
}

// Copies a detected mask (oriented, any size) into a bitmap slice (sensor). u0 = sensor px -> source uv
// columns (a, b), u1 = (tx, ty, slice, -).
kernel void mask_blit(texture2d<float, access::sample>          src  [[texture(0)]],
                      texture2d_array<float, access::read_write> dst  [[texture(1)]],
                      constant float4 *u                              [[buffer(0)]],
                      uint2 gid                                       [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler bs(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 p = float2(gid) + 0.5f;
    float2 uv = float2(dot(float2(u[0].x, u[0].z), p), dot(float2(u[0].y, u[0].w), p)) + u[1].xy;
    dst.write(float4(src.sample(bs, uv).x), gid, uint(u[1].z));
}

// Clears a bitmap slice (u0.x = slice).
kernel void mask_clear(texture2d_array<float, access::read_write> dst [[texture(0)]],
                       constant float4 *u                             [[buffer(0)]],
                       uint2 gid                                      [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(0.0f), gid, uint(u[0].x));
}

// Double exposure (LayerMath): how a layer's light l combines with the photo's b, k = amount × mask × coverage,
// d = display units per scene unit. Modes: 0 film, 1 screen, 2 lighten, 3 darken, 4 multiply, 5 normal.
static inline float3 layer_compress(float3 x) { float3 p = max(x, 0.0f); return p / (1.0f + p); }
static inline float3 layer_blend(float3 b, float3 l, float k, int mode, float d) {
    if (k <= 0.0f) return b;
    l = max(l, 0.0f);
    if (mode == 0) return b * (1.0f - 0.5f * k) + l * (0.5f * k);
    if (mode == 1) {
        float3 r = min(1.0f - (1.0f - layer_compress(b * d)) * (1.0f - layer_compress(l * d)), float3(0.9999f));
        return mix(b, r / (1.0f - r) / d, k);
    }
    if (mode == 2) return mix(b, max(b, l), k);
    if (mode == 3) return mix(b, min(b, l), k);
    if (mode == 4) return mix(b, b * l * d, k);
    return mix(b, l, k);
}

// Composites up to three layers into the photo's native values (target pixels = `base` pixels).
// u0 = (layers, photo display-referred, d, -), u1–u3 = photo native -> scene (columns), u4–u6 = scene -> native.
// Layer i at 7 + 8i: [0] target px -> uv matrix (columns), [1] = (uv offset, mip level, mode),
// [2] = (amount, layer display-referred, mask slice or −1, -), [3] = target px per uv unit (x, y) for the
// anti-aliased edge, [4–6] = layer native -> scene in the photo's units (columns).
// Masks (`mk`) cover the same area as the target, at any resolution.
kernel void layer_composite(texture2d<float, access::read>         base [[texture(0)]],
                            texture2d<float, access::write>        out  [[texture(1)]],
                            texture2d<float, access::sample>       l0   [[texture(2)]],
                            texture2d<float, access::sample>       l1   [[texture(3)]],
                            texture2d<float, access::sample>       l2   [[texture(4)]],
                            texture2d_array<float, access::sample> mk   [[texture(5)]],
                            constant float4 *u                          [[buffer(0)]],
                            uint2 gid                                   [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler ls(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    constexpr sampler ms(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 n = base.read(gid);
    bool unr = u[0].y > 0.5f;
    float3 b = float3x3(u[1].xyz, u[2].xyz, u[3].xyz) * (unr ? shoulder_inv3(n.rgb) : n.rgb);
    float2 p = float2(gid) + 0.5f;
    float2 muv = p / float2(out.get_width(), out.get_height());
    int count = int(u[0].x);
    for (int i = 0; i < count; i++) {
        int o = 7 + 8 * i;
        float2 uv = float2x2(u[o].xy, u[o].zw) * p + u[o + 1].xy;
        float2 e = saturate(min(uv, 1.0f - uv) * u[o + 3].xy + 0.5f);
        float cov = e.x * e.y;
        if (cov <= 0.0f) continue;
        float lod = u[o + 1].z;
        float3 ln = i == 0 ? l0.sample(ls, uv, level(lod)).rgb : (i == 1 ? l1.sample(ls, uv, level(lod)).rgb : l2.sample(ls, uv, level(lod)).rgb);
        if (u[o + 2].y > 0.5f) ln = shoulder_inv3(ln);
        float3 l = float3x3(u[o + 4].xyz, u[o + 5].xyz, u[o + 6].xyz) * ln;
        float k = u[o + 2].x * cov;
        if (u[o + 2].z >= 0.0f) k *= mk.sample(ms, muv, uint(u[o + 2].z)).x;
        b = layer_blend(b, l, k, int(u[o + 1].w), u[0].z);
    }
    float3 r = float3x3(u[4].xyz, u[5].xyz, u[6].xyz) * b;
    if (unr) r = float3(shoulder(r.x), shoulder(r.y), shoulder(r.z));
    out.write(float4(r, n.a), gid);
}

// Copies slice u0.x of `src` into slice u0.y of `dst`.
kernel void mask_copy(texture2d_array<float, access::read>       src [[texture(0)]],
                      texture2d_array<float, access::read_write> dst [[texture(1)]],
                      constant float4 *u                             [[buffer(0)]],
                      uint2 gid                                      [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(src.read(gid, uint(u[0].x)), gid, uint(u[0].y));
}

kernel void tex_clear(texture2d<float, access::write> dst [[texture(0)]], uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(0.0f), gid);
}

// Recipe highlight / shadow tone (ToneMath.recipeTone).
static inline float recipe_tone(float p, float h, float s) {
    if (p <= 0.0f || p >= 1.0f || (h == 0.0f && s == 0.0f)) return p;
    if (p > 0.5f) { float t = (p - 0.5f) * 2.0f; return p + 0.035f * h * 4.0f * t * (1.0f - t); }
    float t = p * 2.0f;
    return p - 0.035f * s * 4.0f * t * (1.0f - t);
}

static inline float lcurve_lookup(texture2d<float, access::read> t, float x, int row) {
    int n = int(t.get_width());
    if (x < 0.0f) return t.read(uint2(0, row)).x + x;
    if (x > 1.0f) return t.read(uint2(n - 1, row)).x + (x - 1.0f);
    float f = x * float(n - 1);
    int i = min(int(f), n - 2);
    float tt = f - float(i);
    float a = t.read(uint2(i, row)).x, b = t.read(uint2(i + 1, row)).x;
    return a + (b - a) * tt;
}

kernel void develop(texture2d<float, access::read>  nat  [[texture(0)]],
                    texture2d<float, access::read>  fine [[texture(1)]],
                    texture2d<float, access::read>  cb   [[texture(2)]],
                    texture2d<float, access::read>  cm   [[texture(3)]],
                    texture2d<float, access::read>  cd   [[texture(4)]],
                    texture2d<float, access::write> dst  [[texture(5)]],
                    texture2d<float, access::read>  lut  [[texture(6)]],
                    texture2d<float, access::read>  elut [[texture(7)]],
                    texture2d<float, access::read>  fcur [[texture(8)]],
                    texture2d<float, access::read>  pcur [[texture(9)]],
                    texture2d<float, access::read>  noc  [[texture(10)]],
                    texture2d<float, access::read>  nof  [[texture(11)]],
                    texture2d<float, access::read>  bmap [[texture(12)]],
                    texture2d<float, access::read>  hmap [[texture(13)]],
                    texture2d<float, access::read>  soft [[texture(14)]],
                    texture3d<float, access::read>  look [[texture(15)]],
                    texture2d_array<float, access::read> mw [[texture(16)]],
                    texture2d<float, access::read>  lcur [[texture(17)]],
                    constant float4 *u                   [[buffer(0)]],
                    constant float4 *spec                [[buffer(1)]],
                    uint2 gid                            [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 native = nat.read(gid).rgb;
    if (u[48].z > 0.0f) native = mix(native, soft.read(gid).rgb, u[48].z);   // emulsion light scatter
    int flags = int(u[7].w);
    if (flags & 1) { dst.write(float4(native, 1.0f), gid); return; }

    float3 c = u[0].w > 0.5f ? shoulder_inv3(native) : native;
    float3x3 M = float3x3(u[0].xyz, u[1].xyz, u[2].xyz);
    float G = fast::log2(max(lum(M * c), 1e-10f) / MID_GREY);   // guide: pre-exposure log luminance
    c = M * c;
    if (!(flags & 6)) { dst.write(float4(c, 1.0f), gid); return; }

    float2 uv = (u[9].xy + (float2(gid) + 0.5f) * u[9].zw) / u[10].xy;

    // Masks (u60 = (count, overlay mask, any local contrast / curve, -); mask i at u[61 + 6i]: (EV, dehaze,
    // shadows, highlights), (clarity gain, contrast, saturation, grain), (cast a, cast b, has curve, has white
    // balance), white-balance matrix columns). Their weights here; additive controls summed (LocalRender).
    int nm = int(u[60].x);
    float wts[8];
    float lev = 0.0f, dehaze = u[4].x, lsh = u[3].x, lhl = u[3].y, lcg = u[3].z, lcs = 0.0f, lsat = 0.0f, lgr = 1.0f;
    float2 lcast = 0.0f;
    for (int i = 0; i < nm; i++) {
        float w = mw.read(gid, uint(i)).x;
        wts[i] = w;
        if (w <= 0.0f) continue;
        int b = 61 + 6 * i;
        if (u[b + 2].w > 0.5f) c = mix(c, float3x3(u[b + 3].xyz, u[b + 4].xyz, u[b + 5].xyz) * c, w);
        lev += w * u[b].x; dehaze += w * u[b].y; lsh += w * u[b].z; lhl += w * u[b].w;
        lcg += w * u[b + 1].x; lcs += w * u[b + 1].y; lsat += w * u[b + 1].z; lgr += w * u[b + 1].w;
        lcast += w * u[b + 2].xy;
    }
    lgr = max(lgr, 0.0f);

    float3 A = u[4].yzw;
    if (dehaze > 0.0f) {
        float2 ab = bilinear(cd, uv).xy;
        float dark = clamp(ab.x * G + ab.y, 0.0f, 1.0f);
        float t = max(1.0f - 0.95f * dehaze * dark, 0.15f);
        c = (c - A) / t + A;
    } else if (dehaze < 0.0f) {
        float t = 1.0f + 0.55f * dehaze;
        c = c * t + A * (1.0f - t);
    }

    c *= u[1].w * fast::exp2(lev);
    float ev = u[2].w + lev;

    if (flags & 8) {
        float y = max(lum(c), 1e-10f);
        float l = fast::log2(y / MID_GREY);
        float2 abB = bilinear(cb, uv).xy;
        float b = abB.x * G + abB.y + ev;
        float dl = shadows_highlights(b, lsh, lhl);
        if ((flags & 16) && lcg != 0.0f) {
            float2 abM = bilinear(cm, uv).xy;
            float mid = abM.x * G + abM.y;
            dl += detail_boost(l - (mid + ev), lcg) * clarity_weight(b);
        }
        if (flags & 32) {
            dl += detail_boost(l - (fine.read(gid).x + ev), u[3].w);
        }
        c *= fast::exp2(dl);
    }

    // Bloom: scene light spilling around bright areas (lens / diffusion), before the film sees it.
    if (u[34].w > 0.5f) c += u[46].xyz * bilinear(bmap, uv).rgb;
    // Recipe dynamic range (u12.z): highlights above +1.5 EV compressed (ToneMath.dynamicRange).
    if (u[12].z != 0.0f) {
        float x = log2(max(lum(c), 1e-6f) / MID_GREY);
        float z = 3.0f * (x - 1.5f);
        float sp = (z > 20.0f ? z : log(1.0f + exp(z))) / 3.0f;
        c *= exp2(-u[12].z * sp);
    }

    // u11 = (masterCurve, rgbCurves, hasMixer, targetCount), u12 = (overlayTarget, hasGrading, -, -)
    bool masterCurve = u[11].x > 0.5f, rgbCurves = u[11].y > 0.5f;
    int filmKind = int(u[34].x);
    float3 scene = c;
    float3 d = c;
    int kind = int(u[5].x);
    bool shape = u[5].y != 1.0f || u[5].z != 0.0f || u[5].w != 0.0f || masterCurve || u[60].z > 0.5f || u[10].z != 0.0f || u[10].w != 0.0f;
    float ck = u[5].y * fast::exp2(0.9f * lcs);
    if (filmKind > 0) {
        float intensity = u[34].y;
        float3 f, s;
        if (filmKind == 4) {
            // Film look: halation, grain in exposure, print filtration, digital rendering, the film's table.
            float3 cl = c;
            if (u[40].w > 0.5f) cl = (cl + u[45].xyz * bilinear(hmap, uv).rgb * u[45].w) / (1.0f + u[45].xyz);
            if (u[44].w > 0.5f) cl = look_grain(cl, noc.read(gid), nof.read(gid), u, lgr);
            cl *= u[59].xyz;
            s = digital_render(cl, kind, u);
            f = look_apply(look, look_input(s));
        } else {
            // Physical film: expose, develop (couplers, grain), print or project.
            float3 e = film_exposure(elut, c * u[59].xyz) * u[39].w;
            if (u[40].w > 0.5f) e = (e + u[45].xyz * bilinear(hmap, uv).rgb * u[45].w) / (1.0f + u[45].xyz);
            float3 D = film_develop(fcur, e, u);
            if (u[44].w > 0.5f) D = add_grain(D, noc.read(gid), nof.read(gid), u, lgr);
            f = filmKind == 2 ? neutral_blacks(spectral_view(spec, 0, D, u))
              : (u[51].w > 0.5f ? film_scan(spec, D, u) : film_print(spec, pcur, D, u));
            s = intensity < 1.0f ? digital_render(c, kind, u) : f;
        }
        // Blend with the digital rendering (its hue-restored tone profile).
        if (intensity < 1.0f) f = mix(s, f, intensity);
        scene = f;
        d = f;
        if (shape) {
            for (int k = 0; k < 3; k++) {
                float q = to_p(d[k]);
                q = contrast_p(q, ck);
                q = whites_blacks(q, u[5].z, u[5].w);
                q = recipe_tone(q, u[10].z, u[10].w);
                if (masterCurve) q = curve_lookup(lut, q, 0);
                for (int i = 0; i < nm; i++) if (wts[i] > 0.0f && u[63 + 6 * i].z > 0.5f) q += (lcurve_lookup(lcur, q, i) - q) * wts[i];
                d[k] = from_p(q);
            }
        }
    } else {
        for (int k = 0; k < 3; k++) {
            float y = d[k];
            if (kind == 1) y = print_curve(y, u[6], u[7]);
            else if (kind == 2) y = y < 0.0f ? y : shoulder(y);
            if (shape) {
                float q = to_p(y);
                q = contrast_p(q, ck);
                q = whites_blacks(q, u[5].z, u[5].w);
                q = recipe_tone(q, u[10].z, u[10].w);
                if (masterCurve) q = curve_lookup(lut, q, 0);
                for (int i = 0; i < nm; i++) if (wts[i] > 0.0f && u[63 + 6 * i].z > 0.5f) q += (lcurve_lookup(lcur, q, i) - q) * wts[i];
                y = from_p(q);
            }
            d[k] = y;
        }
    }
    bool haveLab = false;
    float3 lab = 0;
    if (any(d != scene)) {
        // keep lightness and chroma of the toned colour, restore the hue of the scene (or film) colour
        lab = oklab(d);
        float3 a = oklab(scene);
        float ca = length(a.yz);
        if (ca > 1e-5f) lab.yz = a.yz / ca * length(lab.yz);
        haveLab = true;
    }
    if (rgbCurves) {
        if (haveLab) { d = from_oklab(lab); haveLab = false; }
        for (int k = 0; k < 3; k++) d[k] = from_p(curve_lookup(lut, to_p(d[k]), k + 1));
    }
    float overlay = -1.0f;
    if (flags & 4) {
        if (!haveLab) lab = oklab(d);
        if (u[8].x != 0.0f || u[8].y != 0.0f) {
            float ch = length(lab.yz);
            lab.yz *= chroma_gain(ch, fast::atan2(lab.z, lab.y), u[8].x, u[8].y);
        }
        if (lsat != 0.0f || lcast.x != 0.0f || lcast.y != 0.0f) lab.yz = lab.yz * max(0.0f, 1.0f + lsat) + lcast;
        if (u[8].z != 0.0f || u[8].w != 0.0f) lab = color_chrome(lab, u[8].z, u[8].w);
        if (u[11].z > 0.5f) lab = apply_mixer(lab, u);
        int ov = int(u[12].x);
        if (ov >= 0) overlay = target_weight(lab, u[21 + 2 * ov]);
        int nt = int(u[11].w);
        if (nt > 0) lab = apply_targets(lab, nt, u);
        if (u[12].y > 0.5f) lab = apply_grading(lab, u);
        haveLab = true;
    }
    if (haveLab) d = from_oklab(lab);
    if (u[50].z > 0.5f) d = vignette(d, uv, u);
    // Grain without a film stock: a neutral virtual film on the finished picture.
    if (filmKind == 0 && u[44].w > 0.5f) {
        float3 D = float3(-fast::log10(max(d.x, 1e-4f)), -fast::log10(max(d.y, 1e-4f)), -fast::log10(max(d.z, 1e-4f)));
        float3 Dg = add_grain(D, noc.read(gid), nof.read(gid), u, lgr);
        d = d * float3(fast::exp10(D.x - Dg.x), fast::exp10(D.y - Dg.y), fast::exp10(D.z - Dg.z));
    }
    if (overlay >= 0.0f) {
        float3 grey = float3(max(0.0f, lum(d)) * 0.3f);
        d = grey + (d - grey) * overlay;
    }
    // Mask overlay: the selected mask in red.
    int om = int(u[60].y);
    if (om >= 0 && om < nm) d = mix(d, float3(0.75f, 0.02f, 0.02f), 0.55f * wts[om]);
    dst.write(float4(d, 1.0f), gid);
}

// ---------------------------------------------------------------------------------------------
// Histogram of display-linear Rec.2020 in an output space (sRGB-encoded bins) + clipping counts.
// u0..u2 = Rec.2020 -> output matrix columns. Buffer: 3 × 256 bins, then [shadowClip, highlightClip, total]
// ---------------------------------------------------------------------------------------------
static inline float srgb_enc(float v) { return v <= 0.0031308f ? 12.92f * v : 1.055f * precise::pow(v, 1.0f / 2.4f) - 0.055f; }

// Threadgroup-local bins (16×16 threads, each thread 2×2 pixels), merged into the global buffer once.
kernel void histogram(texture2d<float, access::read> src [[texture(0)]],
                      constant float4 *u                 [[buffer(0)]],
                      device atomic_uint *bins           [[buffer(1)]],
                      uint2 gid                          [[thread_position_in_grid]],
                      uint lid                           [[thread_index_in_threadgroup]])
{
    threadgroup atomic_uint local[771];
    for (uint i = lid; i < 771; i += 256) atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float3x3 M = float3x3(u[0].xyz, u[1].xyz, u[2].xyz);
    for (uint dy = 0; dy < 2; dy++) {
        for (uint dx = 0; dx < 2; dx++) {
            uint2 p = gid * 2 + uint2(dx, dy);
            if (p.x >= src.get_width() || p.y >= src.get_height()) continue;
            float3 v = M * src.read(p).rgb;
            for (int k = 0; k < 3; k++) {
                float e = srgb_enc(clamp(v[k], 0.0f, 1.0f));
                int b = clamp(int(e * 256.0f), 0, 255);
                atomic_fetch_add_explicit(&local[k * 256 + b], 1u, memory_order_relaxed);
            }
            if (max(v.x, max(v.y, v.z)) <= 1.0f / 4096.0f) atomic_fetch_add_explicit(&local[768], 1u, memory_order_relaxed);
            if (max(v.x, max(v.y, v.z)) >= 1.0f) atomic_fetch_add_explicit(&local[769], 1u, memory_order_relaxed);
            atomic_fetch_add_explicit(&local[770], 1u, memory_order_relaxed);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = lid; i < 771; i += 256) {
        uint c = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (c) atomic_fetch_add_explicit(&bins[i], c, memory_order_relaxed);
    }
}
"""#
