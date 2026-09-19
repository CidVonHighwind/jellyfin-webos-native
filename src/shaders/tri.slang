// 1000 rotating triangles, one draw call.
//
// Per-vertex:   position
// Per-instance: offset, direction, speed, phase, size
// Uniform:      time (seconds), aspect (height/width)
//
// Each instance scales with sin(time + phase) * size and spins at its own
// speed and direction, so no two triangles peak at the same moment or the
// same size.

uniform float time;
uniform float aspect;

struct VSIn {
    float2 position  : POSITION;   // per-vertex   (attribute 0)
    float2 offset    : OFFSET;     // per-instance (attribute 1)
    float direction  : DIRECTION;  // per-instance (attribute 2)
    float speed      : SPEED;      // per-instance (attribute 3)
    float phase      : PHASE;      // per-instance (attribute 4) time offset
    float size       : SIZE;       // per-instance (attribute 5) scale offset
};

struct VSOut {
    float4 pos : SV_Position;
    float3 colour : COLOR;
};

[shader("vertex")]
VSOut vsMain(VSIn v) {
    float scale = sin(time + v.phase) * v.size;
    float angle = v.direction + time * v.speed;
    float s = sin(angle);
    float c = cos(angle);
    // Aspect correction belongs to the triangle's own shape, not to where it
    // sits: scaling the offset too would squeeze the field into the middle.
    float2 local = float2(v.position.x * c - v.position.y * s,
                          v.position.x * s + v.position.y * c) * scale;
    local.x *= aspect;

    VSOut o;
    o.pos = float4(local + v.offset, 0.0, 1.0);
    // Hue from the instance's direction, brightness from its current scale.
    float3 tint = 0.5 + 0.5 * cos(v.direction + float3(0.0, 2.094, 4.188));
    o.colour = tint * (0.35 + 0.65 * abs(scale));
    return o;
}

[shader("fragment")]
float4 fsMain(float3 colour : COLOR) : SV_Target {
    return float4(colour, 1.0);
}
