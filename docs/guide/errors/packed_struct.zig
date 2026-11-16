//! expect: expected 'bitpack', found 'packed'
pub const Flags = packed struct(u8) { a: bool, _: u7 = 0 };
