// Instanced UI batch: rectangles, border rings and glyphs all share one draw.

uniform float2 viewport;
uniform float2 unit_range;
Sampler2D atlas;

struct VSIn {
    float2 corner : POSITION;
    float4 rect : RECT;
    float4 uv : TEXCOORD0;
    float4 color : COLOR;
    float4 clip : CLIP;
    float4 shape : SHAPE; // radius, border width, mode, unused
};

struct VSOut {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : COLOR;
    float2 local : TEXCOORD1;
    float2 size : TEXCOORD2;
    float4 clip : TEXCOORD3;
    float4 shape : TEXCOORD4;
    float2 screen : TEXCOORD5;
};

[shader("vertex")]
VSOut vsUi(VSIn v) {
    float2 pixel = v.rect.xy + v.corner * v.rect.zw;
    VSOut o;
    o.pos = float4(pixel.x / viewport.x * 2.0 - 1.0,
                   1.0 - pixel.y / viewport.y * 2.0, 0.0, 1.0);
    o.uv = lerp(v.uv.xy, v.uv.zw, v.corner);
    o.color = v.color;
    o.local = v.corner * v.rect.zw;
    o.size = v.rect.zw;
    o.clip = v.clip;
    o.shape = v.shape;
    o.screen = pixel;
    return o;
}

float roundedDistance(float2 p, float2 size, float radius) {
    float r = min(radius, min(size.x, size.y) * 0.5);
    float2 q = abs(p - size * 0.5) - (size * 0.5 - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

[shader("fragment")]
float4 fsUi(VSOut i) : SV_Target {
    if (i.screen.x < i.clip.x || i.screen.y < i.clip.y ||
        i.screen.x >= i.clip.z || i.screen.y >= i.clip.w) discard;

    // mode 2 is text. FreeType's R8 coverage is already antialiased.
    if (i.shape.z > 1.5) {
        float3 texel = atlas.Sample(i.uv).rgb;
        float sd = max(min(texel.r, texel.g), min(max(texel.r, texel.g), texel.b));
        float px_range = max(0.5 * dot(unit_range, 1.0 / fwidth(i.uv)), 1.0);
        float coverage = clamp((sd - 0.5) * px_range + 0.5, 0.0, 1.0);
        return float4(i.color.rgb, i.color.a * coverage);
    }

    float outer = roundedDistance(i.local, i.size, i.shape.x);
    float aa = max(fwidth(outer), 0.75);
    float alpha = 1.0 - smoothstep(-aa, aa, outer);
    // mode 1 is a border ring. Remove the inset rounded rectangle.
    if (i.shape.z > 0.5) {
        float b = max(i.shape.y, 1.0);
        float2 inner_size = i.size - b * 2.0;
        if (inner_size.x > 0.0 && inner_size.y > 0.0) {
            float inner = roundedDistance(i.local - b, inner_size, max(0.0, i.shape.x - b));
            alpha *= smoothstep(-aa, aa, inner);
        }
    }
    return float4(i.color.rgb, i.color.a * alpha);
}
