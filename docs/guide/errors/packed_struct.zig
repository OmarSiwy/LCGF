//! expect: expected 'bitpack', found 'packed'
pub const Flags = bitpack struct(u8) { a: bool, _: u7 = 0 };
