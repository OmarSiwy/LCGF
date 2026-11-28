struct Params {
    float4 sphere;
    float4 bands;
};

cbuffer params : register(b0) { Params params; }

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
    bool local = (bool)0;

    float4 s = params.sphere;
    float2 n = ((floor(p.xy) - s.xy) / (s.z).xx);
    float d = (1.0 - dot(n, n));
    if ((d < 0.0)) {
        return float4(0.0627451, 0.09411765, 0.15686275, 1.0);
    }
    float3 l = float3((cos(s.w) * 0.8), -0.4, ((sin(s.w) * 0.8) + 0.6));
    float lit_ = max((dot(float3(n, sqrt(d)), l) / length(l)), 0.0);
    float _e43 = params.bands.x;
    if ((_e43 > 0.5)) {
        local = (frac((asin(n.y) * 8.0)) < 0.15);
    } else {
        local = false;
    }
    bool band = local;
    float k = (band ? 0.2 : (0.15 + (0.85 * lit_)));
    return float4(((float3(230.0, 140.0, 60.0) * k) / (255.0).xxx), 1.0);
}
