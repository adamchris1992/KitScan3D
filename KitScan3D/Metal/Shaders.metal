#include <metal_stdlib>
using namespace metal;

struct ViewfinderVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct ViewfinderUniforms {
    float4x4 displayTransform;
    float nearClip;
    float farClip;
    uint showDepthPreview;
    uint showCoverageOverlay;
};

struct PointVertex {
    packed_float3 position;
    packed_float3 color;
};

struct LineVertex {
    packed_float3 position;
    packed_float4 color;
};

struct UnprojectUniforms {
    float4x4 cameraTransform;
    float fx;
    float fy;
    float cx;
    float cy;
    uint rgbWidth;
    uint rgbHeight;
    uint depthWidth;
    uint depthHeight;
    float nearClip;
    float farClip;
    uint minConfidence;
    uint stride;
    uint maxOutputPoints;
};

struct Scene3DUniforms {
    float4x4 viewProjection;
    float pointSize;
};

static inline float3 ycbcrToRGB(float y, float2 cbcr) {
    float cb = cbcr.x - 0.5;
    float cr = cbcr.y - 0.5;
    float r = y + 1.402 * cr;
    float g = y - 0.344136 * cb - 0.714136 * cr;
    float b = y + 1.772 * cb;
    return clamp(float3(r, g, b), 0.0, 1.0);
}

vertex ViewfinderVertexOut viewfinderVertex(uint vid [[vertex_id]],
                                            constant ViewfinderUniforms &u [[buffer(0)]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    ViewfinderVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    float4 transformedUV = u.displayTransform * float4(uvs[vid], 0.0, 1.0);
    out.texCoord = transformedUV.xy;
    return out;
}

fragment float4 viewfinderFragment(ViewfinderVertexOut in [[stage_in]],
                                   texture2d<float> yTexture [[texture(0)]],
                                   texture2d<float> cbcrTexture [[texture(1)]],
                                   texture2d<float> depthTexture [[texture(2)]],
                                   texture2d<float> coverageTexture [[texture(3)]],
                                   constant ViewfinderUniforms &u [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));

    float y = yTexture.sample(s, uv).r;
    float2 cbcr = cbcrTexture.sample(s, uv).rg;
    float3 rgb = ycbcrToRGB(y, cbcr);

    float depth = depthTexture.sample(s, uv).r;
    bool hasValidDepth = !isnan(depth) && depth > 0.0;

    if (u.showDepthPreview != 0 && hasValidDepth) {
        if (depth >= u.nearClip && depth <= u.farClip) {
            float t = clamp((depth - u.nearClip) / max(0.001, u.farClip - u.nearClip), 0.0, 1.0);
            float3 depthTint = mix(float3(0.0, 0.9, 0.8), float3(0.1, 0.45, 1.0), t);
            rgb = mix(rgb, depthTint, 0.22);
        } else {
            rgb = mix(rgb, float3(0.85, 0.2, 0.15), 0.35);
        }
    }

    if (u.showCoverageOverlay != 0) {
        float cov = coverageTexture.sample(s, uv).r;
        if (cov > 0.5) {
            rgb = mix(rgb, float3(0.15, 0.95, 0.45), 0.28);
        }
    }

    return float4(rgb, 1.0);
}

kernel void unprojectDepthKernel(texture2d<float, access::read> yTexture [[texture(0)]],
                                 texture2d<float, access::read> cbcrTexture [[texture(1)]],
                                 texture2d<float, access::read> depthTexture [[texture(2)]],
                                 texture2d<uint, access::read> confTexture [[texture(3)]],
                                 constant UnprojectUniforms &u [[buffer(0)]],
                                 device PointVertex *outPoints [[buffer(1)]],
                                 device atomic_uint *outCount [[buffer(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    uint dx = gid.x * u.stride;
    uint dy = gid.y * u.stride;
    if (dx >= u.depthWidth || dy >= u.depthHeight) {
        return;
    }

    float depth = depthTexture.read(uint2(dx, dy)).r;
    if (isnan(depth) || depth <= 0.0 || depth < u.nearClip || depth > u.farClip) {
        return;
    }

    uint conf = confTexture.read(uint2(dx, dy)).r;
    if (conf < u.minConfidence) {
        return;
    }

    float scaleX = float(u.rgbWidth) / float(u.depthWidth);
    float scaleY = float(u.rgbHeight) / float(u.depthHeight);
    float rgbX = (float(dx) + 0.5) * scaleX;
    float rgbY = (float(dy) + 0.5) * scaleY;

    uint ux = min(uint(rgbX), u.rgbWidth - 1);
    uint uy = min(uint(rgbY), u.rgbHeight - 1);

    float y = yTexture.read(uint2(ux, uy)).r;
    float2 cbcr = cbcrTexture.read(uint2(ux / 2, uy / 2)).rg;
    float3 color = ycbcrToRGB(y, cbcr);

    float xCam = (rgbX - u.cx) * depth / u.fx;
    float yCam = -(rgbY - u.cy) * depth / u.fy;
    float zCam = -depth;

    float4 worldPos = u.cameraTransform * float4(xCam, yCam, zCam, 1.0);

    uint idx = atomic_fetch_add_explicit(outCount, 1, memory_order_relaxed);
    if (idx < u.maxOutputPoints) {
        outPoints[idx].position = worldPos.xyz;
        outPoints[idx].color = color;
    }
}

struct PointVertexOut {
    float4 position [[position]];
    float3 color;
    float pointSize [[point_size]];
};

vertex PointVertexOut pointCloudVertex(uint vid [[vertex_id]],
                                       const device PointVertex *vertices [[buffer(0)]],
                                       constant Scene3DUniforms &u [[buffer(1)]]) {
    PointVertex v = vertices[vid];
    PointVertexOut out;
    out.position = u.viewProjection * float4(float3(v.position), 1.0);
    out.color = float3(v.color);
    out.pointSize = u.pointSize;
    return out;
}

fragment float4 pointCloudFragment(PointVertexOut in [[stage_in]],
                                   float2 pointCoord [[point_coord]]) {
    float2 centered = pointCoord - float2(0.5);
    if (dot(centered, centered) > 0.25) {
        discard_fragment();
    }
    return float4(in.color, 1.0);
}

struct LineVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex LineVertexOut lineVertex(uint vid [[vertex_id]],
                                const device LineVertex *vertices [[buffer(0)]],
                                constant Scene3DUniforms &u [[buffer(1)]]) {
    LineVertex v = vertices[vid];
    LineVertexOut out;
    out.position = u.viewProjection * float4(float3(v.position), 1.0);
    out.color = float4(v.color);
    return out;
}

fragment float4 lineFragment(LineVertexOut in [[stage_in]]) {
    return in.color;
}
