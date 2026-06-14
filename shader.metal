#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct v2f {
    float4 position [[position]];
    float3 normal;
};

vertex v2f vertex_main(
    VertexIn in [[stage_in]],
    constant float4x4 &mvp [[buffer(1)]]
) {
    v2f out;
    out.position = mvp * float4(in.position, 1.0);
    out.normal   = in.normal;
    return out;
}

fragment half4 fragment_main(v2f in [[stage_in]]) {
    float3 light_dir = normalize(float3(-1.0, -1.0, -1.0));

    float ndotl = saturate(dot(normalize(in.normal), light_dir));

    float3 base = float3(0.7, 0.55, 0.4);
    float3 lit  = base * (0.25 + 0.75 * ndotl);

    return half4(half3(lit), 1.0);
}
