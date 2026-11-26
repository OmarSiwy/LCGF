cbuffer screen : register(b0) { float4 screen; }

struct FragmentInput_fs {
    float4 p_1 : SV_Position;
};

float4 vs(uint i : SV_VertexID) : SV_Position
{
    return float4(((float((i & 1u)) * 4.0) - 1.0), ((float((i >> 1u)) * 4.0) - 1.0), 0.0, 1.0);
}

float4 fs(FragmentInput_fs fragmentinput_fs) : SV_Target0
{
    float4 p = fragmentinput_fs.p_1;
    float _e4 = screen.x;
    float _e11 = screen.y;
    return float4(((p.x / _e4) * 0.5), 0.25, ((p.y / _e11) * 0.6), 1.0);
}
