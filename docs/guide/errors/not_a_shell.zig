//! expect: is not a shell: missing `wait` (src/shell/iface.zig)
const MyShell = struct {
    pub fn poll() void {}
    pub fn apply() void {}
    pub fn present() void {}
    pub fn wake() void {}
};

comptime {
    @import("lcgr").shell_iface.check(MyShell);
}
