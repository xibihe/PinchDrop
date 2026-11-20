#include <metal_stdlib>
using namespace metal;

struct Glow {
    float4 center;
    float radius;
    uint color;
    float softness;
    float lift;
};

struct GlowView {
    float4x4 vp;
    float4 right;
    float4 up;
    float4 pixelScale;
};

struct PhotoSurface {
    float4 center, halfRight, halfUp, peel;
};

struct SurfaceVertex {
    float4 position [[position]];
    float2 uv;
    float4 peel [[flat]];
};

vertex SurfaceVertex surfaceVertex(constant PhotoSurface& surface [[buffer(0)]],
    constant GlowView* views [[buffer(1)]], uint vertexID [[vertex_id]], ushort eye [[amplification_id]]) {
    constexpr float2 corners[6] = {{-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1}};
    float2 p = corners[vertexID];
    float4 world = surface.center + p.x * surface.halfRight + p.y * surface.halfUp;
    return {views[eye].vp * world, float2(0.5 + 0.5*p.x, 0.5 - 0.5*p.y), surface.peel};
}

fragment half4 surfaceFragment(SurfaceVertex in [[stage_in]]) {
    float u = mix(in.uv.x, 1.0 - in.uv.x, in.peel.y);
    float wave = 0.89 * u + 0.11 * in.uv.y;
    float leftScreen = smoothstep(-0.035, 0.095, in.peel.x - wave);
    float2 margin = min(in.uv, 1.0 - in.uv);
    float edge = smoothstep(0.0, 0.018, min(margin.x, margin.y));
    float alpha = (0.48 + 0.50 * leftScreen) * edge * in.peel.z * in.peel.w;
    if (alpha < 0.002) discard_fragment();
    return half4(half3(0.004, 0.004, 0.0045) * half(alpha), half(alpha));
}

struct GlowVertex {
    float4 position [[position]];
    float2 local;
    float opacity [[flat]];
    uint color [[flat]];
    float softness [[flat]];
    float lift [[flat]];
};

vertex GlowVertex glowVertex(const device Glow* glows [[buffer(0)]],
    constant GlowView* views [[buffer(1)]], uint vertexID [[vertex_id]],
    uint instance [[instance_id]], ushort eye [[amplification_id]]) {
    constexpr float2 corners[6] = {{-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1}};
    Glow particle = glows[instance];
    GlowView view = views[eye];

    float4 clipCenter = view.vp * float4(particle.center.xyz, 1.0);
    float metersPerPixel = max(0.0, clipCenter.w) * view.pixelScale.x;
    float radius = max(particle.radius, metersPerPixel * 0.68);
    float coverage = sqrt(min(1.0, particle.radius / radius));
    float2 local = corners[vertexID] * 3.35;
    float2 offset = local * radius;
    float3 world = particle.center.xyz + view.right.xyz * offset.x + view.up.xyz * offset.y;
    return {view.vp * float4(world, 1), local, coverage * particle.center.w,
            particle.color, particle.softness, particle.lift};
}

fragment half4 glowFragment(GlowVertex in [[stage_in]]) {
    float r2 = dot(in.local, in.local);
    float fidelity = float((in.color >> 24) & 255u) / 255.0;
    float3 srgb = float3(in.color & 255, (in.color >> 8) & 255, (in.color >> 16) & 255) / 255.0;
    float3 premul = float3(0);
    float alpha = 0;

    // 有实心的照片颗粒，导数只软化不足一个像素的圆形边缘。
    float r = sqrt(r2);
    float aa = clamp(0.55 * fwidth(r), 0.048, 0.33);
    if (fidelity > 0.0) {
        float cover = 1.0 - smoothstep(0.79 - aa, 0.79 + aa, r);
        float border = smoothstep(0.48, 0.83, r);
        float3 contrast = clamp((srgb - 0.5) * 1.15 + 0.53, 0.0, 1.0);
        float3 photo = pow(contrast, float3(2.2)) * (1.0 - 0.20 * border);
        // 剥离前沿只提亮颗粒的实心部分，树叶与暗部各保留自己的色相。
        float glint = in.lift * fidelity * (1.0 - 0.65 * border);
        photo = min(float3(1.0), photo + glint * (photo * 1.35 + srgb * 0.10));
        float weight = in.opacity * cover * fidelity;
        alpha += weight;
        premul += photo * weight;
    }

    if (fidelity < 1.0) {
        // 掌心接收和释放仍使用原来的柔边、色光和透明度。
        float core = exp(-1.87 * r2);
        float mist = exp(-0.61 * r2) * (0.28 * in.softness);
        float weight = in.opacity * min(1.0, core + mist) * (1.0 - fidelity);
        float3 linear = pow(srgb, float3(1.62));
        float luma = dot(linear, float3(0.2126, 0.7152, 0.0722));
        float3 tone = mix(linear, float3(luma), 0.22);
        float3 neutral = float3(0.61, 0.57, 0.46);
        float3 color = mix(float3(0.13, 0.14, 0.12) + tone * 0.77, neutral, in.lift * 0.29);
        alpha += weight;
        premul += color * weight;
    }
    if (alpha < 0.002) discard_fragment();
    return half4(half3(premul), half(alpha));
}
