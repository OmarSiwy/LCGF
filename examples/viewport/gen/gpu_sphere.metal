// language: metal1.0
#include <metal_stdlib>
#include <simd/simd.h>

using metal::uint;

struct Params {
    metal::float4 sphere;
    metal::float4 bands;
};

struct vsInput {
};
struct vsOutput {
    metal::float4 member [[position]];
};
vertex vsOutput vs(
  uint i [[vertex_id]]
) {
    return vsOutput { metal::float4((static_cast<float>(i & 1u) * 4.0) - 1.0, (static_cast<float>(i >> 1u) * 4.0) - 1.0, 0.0, 1.0) };
}


struct fsInput {
};
struct fsOutput {
    metal::float4 member_1 [[color(0)]];
};
fragment fsOutput fs(
  metal::float4 p [[position]]
, constant Params& params [[user(fake0)]]
) {
    bool local = {};
    metal::float4 s = params.sphere;
    metal::float2 n = (metal::floor(p.xy) - s.xy) / metal::float2(s.z);
    float d = 1.0 - metal::dot(n, n);
    if (d < 0.0) {
        return fsOutput { metal::float4(0.0627451, 0.09411765, 0.15686275, 1.0) };
    }
    metal::float3 l = metal::float3(metal::cos(s.w) * 0.8, -0.4, (metal::sin(s.w) * 0.8) + 0.6);
    float lit = metal::max(metal::dot(metal::float3(n, metal::sqrt(d)), l) / metal::length(l), 0.0);
    float _e43 = params.bands.x;
    if (_e43 > 0.5) {
        local = metal::fract(metal::asin(n.y) * 8.0) < 0.15;
    } else {
        local = false;
    }
    bool band = local;
    float k = band ? 0.2 : (0.15 + (0.85 * lit));
    return fsOutput { metal::float4((metal::float3(230.0, 140.0, 60.0) * k) / metal::float3(255.0), 1.0) };
}
