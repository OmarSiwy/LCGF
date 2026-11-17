//! expect: is not a render back end: missing `drawText` (src/render/iface.zig)
const MyBackEnd = struct {
    pub const Queue = void;
    pub const Pass = void;
    pub fn prepare() void {}
    pub fn drawBatch() void {}
};

comptime {
    @import("lcgf").render_iface.check(MyBackEnd);
}
