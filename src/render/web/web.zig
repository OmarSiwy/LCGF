//! The web back end as one module (`render_web` in build.zig), for wasm roots outside this
//! directory such as the web shell's example (src/shell/web/main.zig). wasm32-freestanding only.
pub const js = @import("js.zig");
pub const webgpu = @import("webgpu.zig");
pub const canvas = @import("canvas.zig");
