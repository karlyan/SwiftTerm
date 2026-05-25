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

// sRGB <-> linear (IEC 61966-2-1). Text is composited over the background in
// linear space so anti-aliased edges blend correctly (Ghostty-style), instead of
// the default hardware blend that mixes gamma-encoded sRGB values directly.
inline float3 srgbToLinear(float3 c) {
    return select(c / 12.92, pow((c + 0.055) / 1.055, 2.4), c > 0.04045);
}
inline float3 linearToSrgb(float3 c) {
    return select(c * 12.92, 1.055 * pow(max(c, 0.0), 1.0 / 2.4) - 0.055, c > 0.0031308);
}

// Color glyph (emoji): atlas holds premultiplied sRGB. Composite over the
// destination (read via framebuffer fetch) in linear space; blending is disabled
// on the text pipeline so we output the final straight-sRGB color directly.
fragment float4 terminal_text_fragment(GlyphOut in [[stage_in]],
                                       float4 dst [[color(0)]],
                                       texture2d<float> atlas [[texture(0)]],
                                       sampler samp [[sampler(0)]]) {
    float4 tex = atlas.sample(samp, in.texCoord);
    float a = tex.a * in.color.a;
    if (a <= 0.0) return dst;
    float3 glyphStraight = tex.a > 0.0 ? tex.rgb / tex.a : tex.rgb;
    float3 fgLin = srgbToLinear(glyphStraight) * srgbToLinear(in.color.rgb);
    float3 bgLin = srgbToLinear(dst.rgb);
    float outA = a + dst.a * (1.0 - a);
    float3 outLin = (fgLin * a + bgLin * dst.a * (1.0 - a)) / max(outA, 1e-4);
    return float4(linearToSrgb(outLin), outA);
}

// Grayscale glyph: atlas holds coverage in .r. Composite the foreground color
// over the destination in linear space.
fragment float4 terminal_text_fragment_gray(GlyphOut in [[stage_in]],
                                            float4 dst [[color(0)]],
                                            texture2d<float> atlas [[texture(0)]],
                                            sampler samp [[sampler(0)]]) {
    float coverage = atlas.sample(samp, in.texCoord).r;
    float a = coverage * in.color.a;
    if (a <= 0.0) return dst;
    float3 fgLin = srgbToLinear(in.color.rgb);
    float3 bgLin = srgbToLinear(dst.rgb);
    float outA = a + dst.a * (1.0 - a);
    float3 outLin = (fgLin * a + bgLin * dst.a * (1.0 - a)) / max(outA, 1e-4);
    return float4(linearToSrgb(outLin), outA);
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
