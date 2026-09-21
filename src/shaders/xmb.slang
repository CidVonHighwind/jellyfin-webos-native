/*
    I'm too lazy to copy the MIT license so like just do whatever you want with this shader
    but like if you can leave a comment or something or hit me up, that'd be dope. thxxx

    -- int_45h
*/

// Slang port of the XMB background shader from xmb.glsl.

uniform float time;
uniform float2 resolution;

static const float THRESHOLD = 0.99;
static const float MIN_DIST = 0.13;
static const float MAX_DIST = 40.0;
static const int MAX_DRAWS = 40;

struct VSOut {
    float4 pos : SV_Position;
    float2 fragCoord : TEXCOORD0;
};

// `corner` is a 4-vertex triangle strip: (0,0) (1,0) (0,1) (1,1).
// Passing the corners in a buffer avoids the Vulkan-only GLSL that Slang emits
// for SV_VertexID (see docs/opengl.md).
[shader("vertex")]
VSOut vsMain(float2 corner : POSITION) {
    VSOut o;
    o.pos = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    o.fragCoord = corner * resolution;
    return o;
}

// https://www.shadertoy.com/view/XdGfRR
float hash12(float2 p) {
    uint2 q = uint2(int2(p)) * uint2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    return float(n) * 2.328306437080797e-10;
}

float value2d(float2 p);

// Based on xaot88's starfield: https://www.shadertoy.com/view/Md2SR3
float getStarsRough(float2 p) {
    float s = smoothstep(THRESHOLD, 1.0, hash12(p));
    if (s >= THRESHOLD)
        s = pow((s - THRESHOLD) / (1.0 - THRESHOLD), 10.0);
    return s;
}

// Cubic Hermite interpolation rather than the original's linear interpolation.
float getStars(float2 p, float a, float t) {
    float2 pg = floor(p);
    float2 pc = p - pg;
    float2 k = float2(0.0, 1.0);
    pc *= pc * pc * (3.0 - 2.0 * pc);

    float s = lerp(
        lerp(getStarsRough(pg + k.xx), getStarsRough(pg + k.yx), pc.x),
        lerp(getStarsRough(pg + k.xy), getStarsRough(pg + k.yy), pc.x),
        pc.y
    );
    return smoothstep(a, a + t, s) * pow(value2d(p * 0.1 + time) * 0.5 + 0.5, 8.3);
}

float value2d(float2 p) {
    float2 pg = floor(p);
    float2 pc = p - pg;
    float2 k = float2(0.0, 1.0);
    pc *= pc * pc * (3.0 - 2.0 * pc);
    return lerp(
        lerp(hash12(pg + k.xx), hash12(pg + k.yx), pc.x),
        lerp(hash12(pg + k.xy), hash12(pg + k.yy), pc.x),
        pc.y
    );
}

// Sample the starfield at different sizes to fake depth.
float getDust(float2 p, float2 size, float f) {
    float2 ar = float2(resolution.x / resolution.y, 1.0);
    float2 pp = p * size * ar;
    return pow(0.64 + 0.46 * cos(p.x * 6.28), 1.7) * f *
        (getStars(0.1 * pp + time * float2(20.0, -10.1), 0.11, 0.71) * 4.0 +
         getStars(0.2 * pp + time * float2(30.0, -10.1), 0.10, 0.31) * 5.0 +
         getStars(0.32 * pp + time * float2(40.0, -10.1), 0.10, 0.91) * 2.0);
}

float sdf(float3 p) {
    p *= 2.0;
    float o =
        4.2 * sin(0.05 * p.x + time * 0.25) +
        (0.04 * p.z) *
        sin(p.x * 0.11 + time) *
        2.0 * sin(p.z * 0.2 + time) *
        value2d(float2(0.03, 0.4) * p.xz + float2(time * 0.5, 0.0));
    return abs(dot(p, normalize(float3(0.0, 1.0, 0.05))) + 2.5 + o * 0.5);
}

float3 normalAt(float3 p) {
    const float2 k = float2(1.0, -1.0);
    const float t = 0.001;
    return normalize(
        k.xyy * sdf(p + t * k.xyy) +
        k.yyx * sdf(p + t * k.yyx) +
        k.yxy * sdf(p + t * k.yxy) +
        k.xxx * sdf(p + t * k.xxx)
    );
}

// Only alpha and glow are needed by the caller.
float2 raymarch(float3 origin, float3 direction, float omega) {
    float t = 0.0;
    float alpha = 0.0;
    float glow = MAX_DIST;
    float delta = 0.0;
    float stepLength = 0.0;
    float minEpsilon = 0.03;
    float epsilon = minEpsilon;
    int draws = 0;
    bool hit = false;

    // Enhanced sphere tracing: https://kev.town/raymarching/media/enhanced_sphere_tracing.pdf
    for (int i = 0; i < 100; i++) {
        float3 p = origin + direction * t;
        float nextDelta = sdf(p);
        if (abs(delta) + abs(nextDelta) < stepLength) {
            stepLength -= omega * stepLength;
            omega = 1.0;
        } else {
            stepLength = nextDelta * omega;
        }

        delta = nextDelta;
        t += stepLength;
        glow = t > 10.0 ? min(glow, abs(delta)) : MAX_DIST;

        t += delta;
        if (t >= MAX_DIST) break;
        if (delta < MIN_DIST) {
            if (draws > MAX_DRAWS) break;
            draws++;

            float fade = smoothstep(0.09, 0.11, (p.z * 0.9) / 100.0);
            if (!hit) {
                alpha = 0.01;
                hit = true;
            }
            epsilon = 2.0 * max(minEpsilon, abs(nextDelta));
            alpha += 0.0135 * fade;
            t += epsilon;
        }
    }

    glow /= 3.0;
    return float2(alpha, max(1.0 - glow, 0.0));
}

[shader("fragment")]
float4 fsMain(float2 fragCoord : TEXCOORD0) : SV_Target {
    float2 uv = fragCoord / resolution;
    float3 origin = float3(0.0);
    float3 direction = float3((fragCoord - 0.5 * resolution) / resolution.y, 1.0);
    float2 wave = raymarch(origin, direction, 1.2);

    float3 colour = lerp(
        lerp(float3(0.7, 0.2, 0.2), float3(0.4, 0.1, 0.1), uv.x),
        lerp(float3(0.45, 0.1, 0.1), float3(0.8, 0.3, 0.5), uv.x),
        uv.y
    );
    colour = lerp(colour, float3(1.0), wave.x);
    colour += getDust(uv, float2(2000.0), wave.y) * 0.3;
    return float4(colour, 1.0);
}
