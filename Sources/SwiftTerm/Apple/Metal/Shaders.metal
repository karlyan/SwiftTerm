#include <metal_stdlib>
using namespace metal;

struct GlyphVertex {
    float2 position;
    float2 texCoord;
    float4 color;
};

struct TextCell {
    float2 position;
    float2 size;
    float2 texOrigin;
    float2 texSize;
    float4 color;
};

struct ColorCell {
    float2 position;
    float2 size;
    float4 color;
};

struct GlyphOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

constant float2 kQuadCorners[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(1.0, 1.0),
    float2(0.0, 1.0),
};

vertex GlyphOut terminal_text_vertex(uint vid [[vertex_id]],
                                     const device GlyphVertex *vertices [[buffer(0)]],
                                     constant float2 &viewport [[buffer(1)]]) {
    GlyphVertex v = vertices[vid];
    float2 ndc = float2((v.position.x / viewport.x) * 2.0 - 1.0,
                        (v.position.y / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = v.texCoord;
    out.color = v.color;
    return out;
}

vertex GlyphOut terminal_cell_text_vertex(uint vid [[vertex_id]],
                                          const device TextCell *cells [[buffer(0)]],
                                          constant float2 &viewport [[buffer(1)]]) {
    uint cellIndex = vid / 6;
    uint cornerIndex = vid % 6;
    TextCell cell = cells[cellIndex];
    float2 corner = kQuadCorners[cornerIndex];
    float2 position = cell.position + cell.size * corner;
    float2 ndc = float2((position.x / viewport.x) * 2.0 - 1.0,
                        (position.y / viewport.y) * 2.0 - 1.0);
    GlyphOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = cell.texOrigin + cell.texSize * corner;
    out.color = cell.color;
    return out;
}

// sRGB <-> linear (IEC 61966-2-1).
inline float3 srgbToLinear(float3 c) {
    return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
}
inline float3 linearToSrgb(float3 c) {
    return select(c * 12.92, 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055, c > 0.0031308);
}
inline float relLuma(float3 lin) { return dot(lin, float3(0.2126, 0.7152, 0.0722)); }

// Live-tunable text rendering knobs (set per-frame from AppSettings → Graphics tab).
struct TextTuning {
    float gammaAmount;   // 0 = legacy sRGB-space blend, 1 = full linear-space blend
    float coverageGamma; // power on AA coverage; <1 thicker, >1 thinner strokes
    float minContrast;   // 0 = off .. 1 = strong; lifts low-contrast text vs its bg
};

// Composite a glyph (foreground color `fg`, coverage-scaled alpha) over the
// destination `dst` (read via framebuffer fetch; blending is disabled on the text
// pipeline). gammaAmount lerps between the legacy sRGB-space blend and a
// gamma-correct linear-space blend so the look is tunable at runtime.
inline float4 compositeGlyph(float3 fg, float coverage, float fgA, float4 dst, constant TextTuning &t) {
    coverage = pow(saturate(coverage), t.coverageGamma);
    float a = coverage * fgA;
    if (a <= 0.0) return dst;

    if (t.minContrast > 0.0) {
        float lb = relLuma(srgbToLinear(dst.rgb));
        float lf = relLuma(srgbToLinear(fg));
        float target = lb < 0.5 ? 1.0 : 0.0;            // toward white on dark, black on light
        float push = t.minContrast * saturate(1.0 - abs(lf - lb));
        fg = mix(fg, float3(target), push);
    }

    float outA = a + dst.a * (1.0 - a);
    float inv = 1.0 / max(outA, 1e-4);
    float3 linResult = linearToSrgb((srgbToLinear(fg) * a + srgbToLinear(dst.rgb) * dst.a * (1.0 - a)) * inv);
    float3 srgbResult = (fg * a + dst.rgb * dst.a * (1.0 - a)) * inv;
    return float4(mix(srgbResult, linResult, t.gammaAmount), outA);
}

// Color glyph (emoji): atlas holds premultiplied sRGB.
fragment float4 terminal_text_fragment(GlyphOut in [[stage_in]],
                                       float4 dst [[color(0)]],
                                       constant TextTuning &tuning [[buffer(0)]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler samp [[sampler(0)]]) {
    float4 tex = atlas.sample(samp, in.texCoord);
    if (tex.a <= 0.0) return dst;
    float3 glyphStraight = tex.rgb / tex.a;
    return compositeGlyph(glyphStraight * in.color.rgb, tex.a, in.color.a, dst, tuning);
}

// Grayscale glyph: atlas holds coverage in .r.
fragment float4 terminal_text_fragment_gray(GlyphOut in [[stage_in]],
                                            float4 dst [[color(0)]],
                                            constant TextTuning &tuning [[buffer(0)]],
                                            texture2d<float> atlas [[texture(0)]],
                                            sampler samp [[sampler(0)]]) {
    float coverage = atlas.sample(samp, in.texCoord).r;
    return compositeGlyph(in.color.rgb, coverage, in.color.a, dst, tuning);
}

struct ColorVertex {
    float2 position;
    float4 color;
};

struct ColorOut {
    float4 position [[position]];
    float4 color;
};

vertex ColorOut terminal_color_vertex(uint vid [[vertex_id]],
                                      const device ColorVertex *vertices [[buffer(0)]],
                                      constant float2 &viewport [[buffer(1)]]) {
    ColorVertex v = vertices[vid];
    float2 ndc = float2((v.position.x / viewport.x) * 2.0 - 1.0,
                        (v.position.y / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = v.color;
    return out;
}

vertex ColorOut terminal_cell_color_vertex(uint vid [[vertex_id]],
                                           const device ColorCell *cells [[buffer(0)]],
                                           constant float2 &viewport [[buffer(1)]]) {
    uint cellIndex = vid / 6;
    uint cornerIndex = vid % 6;
    ColorCell cell = cells[cellIndex];
    float2 corner = kQuadCorners[cornerIndex];
    float2 position = cell.position + cell.size * corner;
    float2 ndc = float2((position.x / viewport.x) * 2.0 - 1.0,
                        (position.y / viewport.y) * 2.0 - 1.0);
    ColorOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = cell.color;
    return out;
}

fragment float4 terminal_color_fragment(ColorOut in [[stage_in]]) {
    return in.color;
}
