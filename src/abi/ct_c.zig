//! The static-UI engine alone (src/abi/ct.zig's C functions), for Zig's C backend: `zig build
//! abi` installs it as C source, so a C or C++ compiler can build a UI's frame with its words
//! as constants (lcgf-gen --static), specialized as Zig's comptime pipeline is.
const ct = @import("lcgf").abi_ct;

comptime {
    ct.exportAll();
    @export(&ct.cFrameWords, .{ .name = ct.frame_words_symbol });
}
