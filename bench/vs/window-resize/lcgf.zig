//! Paint the resize fixture through the desktop examples' normal X11 host.
const lcgf = @import("lcgf");

pub const App = struct {
    pub fn build(_: *App, f: *lcgf.frame.Frame, ev: *const lcgf.shell_iface.Events) void {
        const width: u32 = @intFromFloat(ev.in.viewport[0]);
        const bg: lcgf.types.Color = if (width % 4 == 0) .rgb(0x22, 0x33, 0x44) else .rgb(0x51, 0x62, 0x73);
        _ = f.open(.from("background"), .{ .size = .{ .fill, .fill }, .main = .center, .cross = .center, .fill = bg });
        _ = f.leaf(.from("marker"), .{ .size = .{ .px(64), .px(64) }, .fill = .rgb(0xe6, 0x7e, 0x28) });
        f.close();
    }
};
