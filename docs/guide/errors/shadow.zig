//! expect: shadows declaration of 'lanes'
const lanes = 8;

export fn width(lanes: u32) u32 {
    return lanes * 4;
}
