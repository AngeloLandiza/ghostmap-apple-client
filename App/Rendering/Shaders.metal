//  Shaders.metal
//  RoomMapper rendering: camera feed quad, live depth point cloud (Apple's "Displaying a point
//  cloud using scene depth" approach), accumulated global cloud, and line primitives.

#include <metal_stdlib>
#include <simd/simd.h>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Shared helpers

/// Full-range BT.601 YCbCr → RGB, the conversion ARKit's captured image (420f) expects.
static inline float3 rm_ycbcr_to_rgb(float y, float2 cbcr) {
    const float4x4 ycbcrToRGB = float4x4(
        float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));
    return (ycbcrToRGB * float4(y, cbcr, 1.0f)).rgb;
}

static inline float4 rm_unpack_color(uint packed) {
    return float4(float(packed & 0xFFu),
                  float((packed >> 8) & 0xFFu),
                  float((packed >> 16) & 0xFFu),
                  float((packed >> 24) & 0xFFu)) / 255.0f;
}

struct PointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

/// Round point sprite; discards fragments outside the disc.
fragment float4 rm_point_fragment(PointOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
    const float2 d = pointCoord - float2(0.5f);
    if (dot(d, d) > 0.25f) {
        discard_fragment();
    }
    return in.color;
}

// MARK: - Camera feed quad

struct QuadOut {
    float4 position [[position]];
    float2 texCoord;
};

constant float2 rm_quad_positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
constant float2 rm_quad_texcoords[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };

vertex QuadOut rm_camera_vertex(uint vid [[vertex_id]],
                                constant RMLiveUniforms &u [[buffer(RMBufferIndexUniforms)]]) {
    QuadOut out;
    out.position = float4(rm_quad_positions[vid], 0.0f, 1.0f);
    // displayTransform maps normalized *image* coordinates to normalized *view* coordinates; we need
    // the inverse (view → image) to look up the texture for each screen position. The CPU passes the
    // inverse already, as a 3×3 affine matrix.
    const float3 tc = u.displayTransform * float3(rm_quad_texcoords[vid], 1.0f);
    out.texCoord = tc.xy;
    return out;
}

fragment float4 rm_camera_fragment(QuadOut in [[stage_in]],
                                   texture2d<float, access::sample> yTex [[texture(RMTextureIndexY)]],
                                   texture2d<float, access::sample> cbcrTex [[texture(RMTextureIndexCbCr)]]) {
    constexpr sampler s(mip_filter::linear, mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float y = yTex.sample(s, in.texCoord).r;
    const float2 cbcr = cbcrTex.sample(s, in.texCoord).rg;
    return float4(rm_ycbcr_to_rgb(y, cbcr), 1.0f);
}

// MARK: - Live depth point cloud (one vertex per depth pixel)

vertex PointOut rm_live_point_vertex(uint vid [[vertex_id]],
                                     constant RMLiveUniforms &u [[buffer(RMBufferIndexUniforms)]],
                                     texture2d<float, access::sample> yTex [[texture(RMTextureIndexY)]],
                                     texture2d<float, access::sample> cbcrTex [[texture(RMTextureIndexCbCr)]],
                                     texture2d<float, access::read> depthTex [[texture(RMTextureIndexDepth)]],
                                     texture2d<uint, access::read> confTex [[texture(RMTextureIndexConfidence)]]) {
    PointOut out;
    const uint px = vid % u.depthWidth;
    const uint py = vid / u.depthWidth;
    const float depth = depthTex.read(uint2(px, py)).r;
    const uint confidence = confTex.read(uint2(px, py)).r;

    const bool keep = (float(confidence) >= u.confidenceThreshold) && depth >= u.minDepth && depth <= u.maxDepth;
    if (!keep) {
        out.position = float4(0.0f, 0.0f, -2.0f, 1.0f); // outside clip space → culled
        out.pointSize = 0.0f;
        out.color = float4(0.0f);
        return out;
    }

    // Pixel center → image-space camera point (x right, y down, z forward) → ARKit camera (x right, y up, −z forward).
    const float3 imagePoint = u.intrinsicsInverse * float3(float(px) + 0.5f, float(py) + 0.5f, 1.0f) * depth;
    const float4 cameraPoint = float4(imagePoint.x, -imagePoint.y, -imagePoint.z, 1.0f);
    const float4 worldPoint = u.cameraToWorld * cameraPoint;
    out.position = u.viewProjection * worldPoint;
    out.pointSize = clamp(u.pointSize * 1.2f / max(out.position.w, 0.05f), 2.0f, u.pointSize * 2.5f);

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 tc = float2((float(px) + 0.5f) / float(u.depthWidth), (float(py) + 0.5f) / float(u.depthHeight));
    const float y = yTex.sample(s, tc).r;
    const float2 cbcr = cbcrTex.sample(s, tc).rg;
    out.color = float4(rm_ycbcr_to_rgb(y, cbcr), u.alpha);
    return out;
}

// MARK: - Global cloud (RMPointVertex buffer, strided)

vertex PointOut rm_cloud_vertex(uint vid [[vertex_id]],
                                device const RMPointVertex *points [[buffer(RMBufferIndexPoints)]],
                                constant RMCloudUniforms &u [[buffer(RMBufferIndexUniforms)]]) {
    PointOut out;
    const uint index = vid * max(u.stride, 1u);
    if (index >= u.count) {
        out.position = float4(0.0f, 0.0f, -2.0f, 1.0f);
        out.pointSize = 0.0f;
        out.color = float4(0.0f);
        return out;
    }
    const RMPointVertex p = points[index];
    out.position = u.viewProjection * float4(p.x, p.y, p.z, 1.0f);
    out.pointSize = u.perspective ? clamp(u.pointSize * 1.6f / max(out.position.w, 0.05f), 1.5f, u.pointSize * 3.0f) : u.pointSize;
    float4 c = rm_unpack_color(p.color);
    c.a = u.alpha;
    out.color = c;
    return out;
}

// MARK: - Lines (trajectory, frustum)

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut rm_line_vertex(uint vid [[vertex_id]],
                              device const RMLineVertex *vertices [[buffer(RMBufferIndexLines)]],
                              constant RMLineUniforms &u [[buffer(RMBufferIndexUniforms)]]) {
    LineOut out;
    const RMLineVertex v = vertices[vid];
    out.position = u.viewProjection * float4(v.x, v.y, v.z, 1.0f);
    out.color = u.color;
    return out;
}

fragment float4 rm_line_fragment(LineOut in [[stage_in]]) {
    return in.color;
}
