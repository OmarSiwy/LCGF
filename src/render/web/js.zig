//! The imports every LCGF wasm module gets from lcgf.js (`load`): a log line and a panic, both
//! as (pointer, length) into the module's memory. wasm32-freestanding only.
const std = @import("std");

const imports = struct {
    extern "lcgf" fn log(ptr: [*]const u8, len: usize) void;
    extern "lcgf" fn panic(ptr: [*]const u8, len: usize) noreturn;
};

pub fn log(s: []const u8) void {
    imports.log(s.ptr, s.len);
}

/// Formats into a stack buffer and logs it; cut at 256 bytes.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    log(std.fmt.bufPrint(&buf, fmt, args) catch buf[0..]);
}

/// `pub const panic = js.panic;` in a wasm root: the message reaches JS, which throws.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        imports.panic(msg.ptr, msg.len);
    }
}.f);
