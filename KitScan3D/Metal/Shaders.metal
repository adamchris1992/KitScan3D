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
    uint frameIndex;
    float maxEdgeJumpMeters;
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
    if (in.texCoord.x < 0.0 || in.texCoord.x > 1.0 || in.texCoord.y < 0.0 || in.texCoord.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    constexpr sampler depthSampler(address::clamp_to_edge, filter::nearest);
    float2 uv = in.texCoord;

    float y = yTexture.sample(s, uv).r;
    float2 cbcr = cbcrTexture.sample(s, uv).rg;
    float3 rgb = ycbcrToRGB(y, cbcr);

    float depth = depthTexture.sample(depthSampler, uv).r;
    bool hasValidDepth = !isnan(depth) && depth > 0.0;

    if (u.showDepthPreview != 0 && hasValidDepth) {
        if (depth >= u.nearClip && depth <= u.farClip) {
            float t = clamp((depth - u.nearClip) / max(0.001, u.farClip - u.nearClip), 0.0, 1.0);
            float3 depthTint = mix(float3(0.0, 0.9, 0.8), float3(0.1, 0.45, 1.0), t);
            rgb = mix(rgb, depthTint, 0.28);
        } else {
            rgb = mix(rgb, float3(0.9, 0.25, 0.15), 0.35);
        }
    }

    if (u.showCoverageOverlay != 0) {
        float cov = coverageTexture.sample(s, uv).r;
        if (cov > 0.25) {
            rgb = mix(rgb, float3(0.15, 0.95, 0.45), clamp(cov, 0.0, 1.0) * 0.35);
        }
    }

    return float4(rgb, 1.0);
}

static inline uint pcgHash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

kernel void unprojectDepthKernel(texture2d<float, access::sample> yTexture [[texture(0)]],
                                 texture2d<float, access::sample> cbcrTexture [[texture(1)]],
                                 texture2d<float, access::read> depthTexture [[texture(2)]],
                                 texture2d<uint, access::read> confTexture [[texture(3)]],
                                 constant UnprojectUniforms &u [[buffer(0)]],
                                 device PointVertex *outPoints [[buffer(1)]],
                                 device atomic_uint *outCount [[buffer(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    // Per-frame jittered stride offset breaks up regular grid Moire when stride > 1
    uint jx = (u.stride > 1) ? (pcgHash(gid.x * 73856093u ^ gid.y * 19349663u ^ u.frameIndex * 83492791u) % u.stride) : 0;
    uint jy = (u.stride > 1) ? (pcgHash(gid.x * 2971215073u ^ gid.y * 486187739u ^ u.frameIndex * 15485863u) % u.stride) : 0;
    uint dx = gid.x * u.stride + jx;
    uint dy = gid.y * u.stride + jy;
    if (dx >= u.depthWidth || dy >= u.depthHeight) {
        return;
    }

    float rawDepth = depthTexture.read(uint2(dx, dy)).r;
    if (isnan(rawDepth) || rawDepth <= 0.0 || rawDepth < u.nearClip || rawDepth > u.farClip) {
        return;
    }

    uint conf = confTexture.read(uint2(dx, dy)).r;
    if (conf < u.minConfidence) {
        return;
    }

    // Distance-scaled edge jump threshold to reject flying pixels at object silhouettes
    float edgeThreshold = min(u.maxEdgeJumpMeters, max(0.015, rawDepth * 0.035));

    // 3x3 confidence-aware edge-preserving bilateral smooth + discontinuity rejection
    float sumW = 1.0;
    float sumD = rawDepth;
    uint jumpCount = 0;
    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            if (ox == 0 && oy == 0) continue;
            int nx = int(dx) + ox;
            int ny = int(dy) + oy;
            if (nx < 0 || ny < 0 || nx >= int(u.depthWidth) || ny >= int(u.depthHeight)) {
                jumpCount++;
                continue;
            }
            uint2 nCoord = uint2(uint(nx), uint(ny));
            uint nConf = confTexture.read(nCoord).r;
            float nd = depthTexture.read(nCoord).r;
            if (nConf < u.minConfidence || isnan(nd) || nd <= 0.0) {
                jumpCount++;
                continue;
            }
            float diff = abs(nd - rawDepth);
            if (diff > edgeThreshold) {
                jumpCount++;
            } else {
                float sigma2 = max(0.0001, (edgeThreshold * 0.5) * (edgeThreshold * 0.5));
                float rangeW = exp(-(diff * diff) / sigma2);
                sumD += nd * rangeW;
                sumW += rangeW;
            }
        }
    }
    // Reject flying pixels sitting on sharp depth discontinuities or low-confidence borders
    if (jumpCount >= 2) {
        return;
    }
    float depth = sumD / sumW;

    float scaleX = float(u.rgbWidth) / float(u.depthWidth);
    float scaleY = float(u.rgbHeight) / float(u.depthHeight);

    // Reject steep grazing angles where LiDAR depth noise stretches into diagonal streaks
    if (dx > 0 && dx + 1 < u.depthWidth && dy > 0 && dy + 1 < u.depthHeight) {
        float dL = depthTexture.read(uint2(dx - 1, dy)).r;
        float dR = depthTexture.read(uint2(dx + 1, dy)).r;
        float dU = depthTexture.read(uint2(dx, dy - 1)).r;
        float dD = depthTexture.read(uint2(dx, dy + 1)).r;
        float dzdx = 0.5 * (dR - dL);
        float dzdy = 0.5 * (dD - dU);
        float dxCamStep = max(1e-4, depth * (scaleX / u.fx));
        float dyCamStep = max(1e-4, depth * (scaleY / u.fy));
        float slopeX = dzdx / dxCamStep;
        float slopeY = dzdy / dyCamStep;
        // cos(theta)^2 = 1 / (1 + slopeX^2 + slopeY^2); reject > ~72 deg incidence
        if (slopeX * slopeX + slopeY * slopeY > 9.0) {
            return;
        }
    }

    // Continuous sub-pixel stochastic jitter decouples samples from the integer depth lattice
    uint h1 = pcgHash(dx * 73856093u ^ dy * 19349663u ^ u.frameIndex * 83492791u);
    uint h2 = pcgHash(dx * 2971215073u ^ dy * 486187739u ^ u.frameIndex * 15485863u);
    float subX = (float(h1 & 0xFFFFu) / 65535.0 - 0.5) * 0.9;
    float subY = (float(h2 & 0xFFFFu) / 65535.0 - 0.5) * 0.9;

    float fxDepth = clamp(float(dx) + 0.5 + subX, 0.5, float(u.depthWidth) - 0.5);
    float fyDepth = clamp(float(dy) + 0.5 + subY, 0.5, float(u.depthHeight) - 0.5);

    // Edge-safe bilinear depth interpolation at the jittered sub-pixel location
    float px = fxDepth - 0.5;
    float py = fyDepth - 0.5;
    uint x0 = uint(floor(px));
    uint y0 = uint(floor(py));
    uint x1 = min(x0 + 1, u.depthWidth - 1);
    uint y1 = min(y0 + 1, u.depthHeight - 1);
    float tx = px - float(x0);
    float ty = py - float(y0);

    float d00 = depthTexture.read(uint2(x0, y0)).r;
    float d10 = depthTexture.read(uint2(x1, y0)).r;
    float d01 = depthTexture.read(uint2(x0, y1)).r;
    float d11 = depthTexture.read(uint2(x1, y1)).r;
    if (!isnan(d00) && !isnan(d10) && !isnan(d01) && !isnan(d11) &&
        abs(d00 - depth) <= edgeThreshold && abs(d10 - depth) <= edgeThreshold &&
        abs(d01 - depth) <= edgeThreshold && abs(d11 - depth) <= edgeThreshold) {
        float dTop = mix(d00, d10, tx);
        float dBot = mix(d01, d11, tx);
        depth = mix(dTop, dBot, ty);
    }

    float rgbX = fxDepth * scaleX;
    float rgbY = fyDepth * scaleY;

    constexpr sampler rgbSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = float2(rgbX / float(u.rgbWidth), rgbY / float(u.rgbHeight));
    float y = yTexture.sample(rgbSampler, uv).r;
    float2 cbcr = cbcrTexture.sample(rgbSampler, uv).rg;
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
    // Crisp, distance-attenuated point size without darkening or diagonal stripe overlap
    float dist = max(0.35, out.position.w);
    out.pointSize = clamp(u.pointSize * 2.2 / dist, 2.2, 8.5);
    return out;
}

fragment float4 pointCloudFragment(PointVertexOut in [[stage_in]],
                                   float2 pointCoord [[point_coord]]) {
    float2 centered = pointCoord - float2(0.5);
    float r2 = dot(centered, centered);
    if (r2 > 0.25) {
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
