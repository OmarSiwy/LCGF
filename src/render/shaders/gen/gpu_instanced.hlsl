struct V {
    float4 pos : SV_Position;
    nointerpolation float4 color : LOC0;
};

struct VertexOutput_vs {
    nointerpolation float4 color : LOC0;
    float4 pos : SV_Position;
};

struct FragmentInput_fs {
    nointerpolation float4 color_1 : LOC0;
    float4 pos_1 : SV_Position;
};

int naga_neg(int val) {
    return asint(-asuint(val));
}

V ConstructV(float4 arg0, float4 arg1) {
    V ret = (V)0;
    ret.pos = arg0;
    ret.color = arg1;
    return ret;
}

VertexOutput_vs vs(float2 corner : LOC0, int2 at : LOC1, uint rgba : LOC2, int4 check : LOC3)
{
    bool local = (bool)0;
    bool local_1 = (bool)0;
    bool local_2 = (bool)0;
    bool local_3 = (bool)0;

    int column = naga_neg(at.x);
    if ((at.y == column)) {
        local = (check.x == column);
    } else {
        local = false;
    }
    bool _e13 = local;
    if (_e13) {
        local_1 = (check.y == naga_neg(column));
    } else {
        local_1 = false;
    }
    bool _e20 = local_1;
    if (_e20) {
        local_2 = (check.z == asint(asuint(int(2)) * asuint(column)));
    } else {
        local_2 = false;
    }
    bool _e28 = local_2;
    if (_e28) {
        local_3 = (check.w == int(-7));
    } else {
        local_3 = false;
    }
    bool ok = local_3;
    float x = ((float(column) + corner.x) / 8.0);
    float4 color_2 = (ok ? (float4(rgba & 0xFF, rgba >> 8 & 0xFF, rgba >> 16 & 0xFF, rgba >> 24) / 255.0) : float4(1.0, 0.0, 1.0, 1.0));
    const V v_1 = ConstructV(float4(((x * 2.0) - 1.0), (1.0 - (corner.y * 2.0)), 0.0, 1.0), color_2);
    const VertexOutput_vs v_1_ = { v_1.color, v_1.pos };
    return v_1_;
}

float4 fs(FragmentInput_fs fragmentinput_fs) : SV_Target0
{
    V v = { fragmentinput_fs.pos_1, fragmentinput_fs.color_1 };
    return v.color;
}
