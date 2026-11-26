// language: metal1.0
#include <metal_stdlib>
#include <simd/simd.h>

using metal::uint;

struct _mslBufferSizes {
    uint size0;
};

typedef uint type_1[1];

struct main_Input {
};
kernel void main_(
  metal::uint3 id [[thread_position_in_grid]]
, device type_1& out [[user(fake0)]]
, constant metal::uint4& base [[user(fake0)]]
, constant _mslBufferSizes& _buffer_sizes [[user(fake0)]]
) {
    if (id.x < (1 + (_buffer_sizes.size0 - 0 - 4) / 4)) {
        uint _e13 = base.x;
        out[id.x] = (id.x * 3u) + _e13;
        return;
    } else {
        return;
    }
}
