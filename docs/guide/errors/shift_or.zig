//! expect: ambiguous operator precedence with operators ... << ... | ...; use parentheses to disambiguate
export fn key(texture: u32, material: u32) u32 {
    return texture << 16 | material;
}
