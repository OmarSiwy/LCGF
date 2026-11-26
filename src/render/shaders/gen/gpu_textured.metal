// language: metal1.0
#include <metal_stdlib>
#include <simd/simd.h>

using metal::uint;

struct Params {
    metal::float4 tint;
};
struct V {
    metal::float4 pos;
    metal::float2 uv;
    char _pad2[8];
};

struct vsInput {
    metal::float2 at [[attribute(0)]];
};
struct vsOutput {
    metal::float4 pos [[position]];
    metal::float2 uv [[user(loc0), center_perspective]];
};
vertex vsOutput vs(
  vsInput varyings [[stage_in]]
) {
    const auto at = varyings.at;
    const auto _tmp = V {metal::float4((at.x * 2.0) - 1.0, 1.0 - (at.y * 2.0), 0.0, 1.0), at};
    return vsOutput { _tmp.pos, _tmp.uv };
}


struct fsInput {
    metal::float2 uv [[user(loc0), center_perspective]];
};
struct fsOutput {
    metal::float4 member_1 [[color(0)]];
};
fragment fsOutput fs(
  fsInput varyings_1 [[stage_in]]
, metal::float4 pos [[position]]
, constant Params& params [[user(fake0)]]
, metal::texture2d<float, metal::access::sample> tex [[user(fake0)]]
, metal::sampler smp [[user(fake0)]]
) {
    const V v = { pos, varyings_1.uv };
    metal::float4 _e4 = tex.sample(smp, v.uv);
    metal::float4 _e7 = params.tint;
    return fsOutput { _e4 * _e7 };
}
