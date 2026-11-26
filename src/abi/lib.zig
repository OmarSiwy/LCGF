//! The root of liblcgf (`zig build abi`): the seam's C functions (src/abi/seam.zig), declared
//! in src/abi/lcgf.h. C++ and Rust programs link it; they need no Zig compiler.
const lcgf = @import("lcgf");

comptime {
    lcgf.abi_seam.exportAll();
    lcgf.abi_api.exportAll();
    lcgf.abi_ct.exportAll();
}
