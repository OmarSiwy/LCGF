//! expect: extern structs cannot contain fields of type '@Vector(4, f32)'
const Row = extern struct { rect: @Vector(4, f32) };

export fn first(r: *const Row) f32 {
    return r.rect[0];
}
