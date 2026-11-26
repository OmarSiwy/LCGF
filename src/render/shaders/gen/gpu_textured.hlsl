struct Params {
    float4 tint;
};

struct V {
    float4 pos : SV_Position;
    float2 uv : LOC0;
};

cbuffer params : register(b0) { Params params; }
Texture2D<float4> tex : register(t1);
SamplerState nagaSamplerHeap[2048]: register(s0, space0);
SamplerComparisonState nagaComparisonSamplerHeap[2048]: register(s0, space1);
StructuredBuffer<uint> nagaGroup0SamplerIndexArray : register(t0, space255);
static const SamplerState smp = nagaSamplerHeap[nagaGroup0SamplerIndexArray[2]];

struct VertexOutput_vs {
    float2 uv : LOC0;
    float4 pos : SV_Position;
};

struct FragmentInput_fs {
    float2 uv_1 : LOC0;
    float4 pos_1 : SV_Position;
};

V ConstructV(float4 arg0, float2 arg1) {
    V ret = (V)0;
    ret.pos = arg0;
    ret.uv = arg1;
    return ret;
}

VertexOutput_vs vs(float2 at : LOC0)
{
    const V v_1 = ConstructV(float4(((at.x * 2.0) - 1.0), (1.0 - (at.y * 2.0)), 0.0, 1.0), at);
    const VertexOutput_vs v_1_ = { v_1.uv, v_1.pos };
    return v_1_;
}

float4 fs(FragmentInput_fs fragmentinput_fs) : SV_Target0
{
    V v = { fragmentinput_fs.pos_1, fragmentinput_fs.uv_1 };
    float4 _e4 = tex.Sample(smp, v.uv);
    float4 _e7 = params.tint;
    return (_e4 * _e7);
}
