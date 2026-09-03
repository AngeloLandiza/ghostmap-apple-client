//  ShaderTypes.h
//  Types shared between Swift (via the bridging header) and Metal shaders.
//  Every struct here is laid out identically in C, Swift and MSL.

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

#ifdef __METAL_VERSION__
#define RM_UINT32 uint
#else
#include <stdint.h>
#define RM_UINT32 uint32_t
#endif

/// One colored point. Byte-for-byte identical to MapCore.PackedPoint (16 bytes, 4-byte aligned).
/// color packs RGBA as r | g << 8 | b << 16 | a << 24.
typedef struct {
    float x;
    float y;
    float z;
    RM_UINT32 color;
} RMPointVertex;

/// Buffer / texture slots used by every pipeline.
typedef enum {
    RMBufferIndexPoints = 0,
    RMBufferIndexUniforms = 1,
    RMBufferIndexLines = 2
} RMBufferIndex;

typedef enum {
    RMTextureIndexY = 0,
    RMTextureIndexCbCr = 1,
    RMTextureIndexDepth = 2,
    RMTextureIndexConfidence = 3
} RMTextureIndex;

/// Per-frame uniforms for the camera feed quad and the live depth point cloud.
typedef struct {
    matrix_float4x4 viewProjection;     // world → clip for the current interface orientation
    matrix_float4x4 cameraToWorld;      // ARCamera.transform (camera frame is landscapeRight-native)
    matrix_float3x3 intrinsicsInverse;  // K⁻¹ scaled to the depth map resolution
    matrix_float3x3 displayTransform;   // normalized image coords → normalized view coords (frame.displayTransform)
    RM_UINT32 depthWidth;
    RM_UINT32 depthHeight;
    float pointSize;
    float confidenceThreshold;          // keep pixels whose confidence >= threshold (0, 1, 2)
    float minDepth;
    float maxDepth;
    float alpha;
} RMLiveUniforms;

/// Uniforms for drawing the accumulated global cloud from a RMPointVertex buffer.
typedef struct {
    matrix_float4x4 viewProjection;
    float pointSize;
    float alpha;
    RM_UINT32 stride;                   // draw every stride-th point (vertex i reads point i * stride)
    RM_UINT32 count;                    // number of source points in the buffer
} RMCloudUniforms;

/// Uniforms for line primitives (trajectory polyline, camera frustum).
typedef struct {
    matrix_float4x4 viewProjection;
    vector_float4 color;
} RMLineUniforms;

/// A line vertex: packed position, 12 bytes.
typedef struct {
    float x;
    float y;
    float z;
} RMLineVertex;

#endif /* ShaderTypes_h */
