RWByteAddressBuffer out_ : register(u0);
cbuffer base : register(b1) { uint4 base; }

uint NagaBufferLengthRW(RWByteAddressBuffer buffer)
{
    uint ret;
    buffer.GetDimensions(ret);
    return ret;
}

[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    if ((id.x < ((NagaBufferLengthRW(out_) - 0) / 4))) {
        uint _e13 = base.x;
        out_.Store(id.x*4, asuint(((id.x * 3u) + _e13)));
        return;
    } else {
        return;
    }
}
