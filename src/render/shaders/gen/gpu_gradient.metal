// language: metal1.0
#include <metal_stdlib>
#include <simd/simd.h>

using metal::uint;


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
, constant metal::float4& screen [[user(fake0)]]
) {
    float _e4 = screen.x;
    float _e11 = screen.y;
    return fsOutput { metal::float4((p.x / _e4) * 0.5, 0.25, (p.y / _e11) * 0.6, 1.0) };
}
