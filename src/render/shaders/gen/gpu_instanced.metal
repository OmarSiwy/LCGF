// language: metal1.0
#include <metal_stdlib>
#include <simd/simd.h>

using metal::uint;

struct V {
    metal::float4 pos;
    metal::float4 color;
};
int naga_neg(int val) {
    return as_type<int>(-as_type<uint>(val));
}


struct vsInput {
    metal::float2 corner [[attribute(0)]];
    metal::int2 at [[attribute(1)]];
    uint rgba [[attribute(2)]];
    metal::int4 check [[attribute(3)]];
};
struct vsOutput {
    metal::float4 pos [[position]];
    metal::float4 color [[user(loc0), flat]];
};
vertex vsOutput vs(
  vsInput varyings [[stage_in]]
) {
    const auto corner = varyings.corner;
    const auto at = varyings.at;
    const auto rgba = varyings.rgba;
    const auto check = varyings.check;
    bool local = {};
    bool local_1 = {};
    bool local_2 = {};
    bool local_3 = {};
    int column = naga_neg(at.x);
    if (at.y == column) {
        local = check.x == column;
    } else {
        local = false;
    }
    bool _e13 = local;
    if (_e13) {
        local_1 = check.y == naga_neg(column);
    } else {
        local_1 = false;
    }
    bool _e20 = local_1;
    if (_e20) {
        local_2 = check.z == as_type<int>(as_type<uint>(2) * as_type<uint>(column));
    } else {
        local_2 = false;
    }
    bool _e28 = local_2;
    if (_e28) {
        local_3 = check.w == -7;
    } else {
        local_3 = false;
    }
    bool ok = local_3;
    float x = (static_cast<float>(column) + corner.x) / 8.0;
    metal::float4 color = ok ? metal::unpack_unorm4x8_to_float(rgba) : metal::float4(1.0, 0.0, 1.0, 1.0);
    const auto _tmp = V {metal::float4((x * 2.0) - 1.0, 1.0 - (corner.y * 2.0), 0.0, 1.0), color};
    return vsOutput { _tmp.pos, _tmp.color };
}


struct fsInput {
    metal::float4 color [[user(loc0), flat]];
};
struct fsOutput {
    metal::float4 member_1 [[color(0)]];
};
fragment fsOutput fs(
  fsInput varyings_1 [[stage_in]]
, metal::float4 pos [[position]]
) {
    const V v = { pos, varyings_1.color };
    return fsOutput { v.color };
}
