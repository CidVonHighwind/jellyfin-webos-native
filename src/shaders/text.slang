// Screen-space text overlay: one triangle strip, no vertex buffer.
// `atlas` is an R8 coverage bitmap rasterised on the CPU (src/text.zig).

uniform float4 rect;  // destination in NDC: x0, y0, x1, y1
Sampler2D atlas;

struct TOut {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
};

// `corner` is a 4-vertex triangle strip: (0,0) (1,0) (0,1) (1,1).
// Slang's GLSL is the Vulkan flavour, where SV_VertexID lowers to
// gl_VertexIndex - gl_BaseVertex and an ARB extension GLSL ES does not have,
// so the corners come from a vertex buffer instead. See docs/opengl.md.
[shader("vertex")]
TOut vsText(float2 corner : POSITION) {
    float2 c = corner;
    TOut o;
    o.pos = float4(lerp(rect.x, rect.z, c.x), lerp(rect.y, rect.w, c.y), 0.0, 1.0);
    o.uv = float2(c.x, 1.0 - c.y);  // atlas row 0 is the top line
    return o;
}

[shader("fragment")]
float4 fsText(float2 uv : TEXCOORD0) : SV_Target {
    float coverage = atlas.Sample(uv).r;
    return float4(coverage, coverage, coverage, coverage);
}
