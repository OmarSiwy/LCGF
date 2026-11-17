pub const App = struct {
    title: []const u8 = "Counter",
    dec_text: []const u8 = "-",
    inc_text: []const u8 = "+",
    count: i32 = 0,
};
pub const counter = struct {
    pub fn dec(rt: anytype) void {
        rt.set(.count, rt.state.count - 1);
    }
    pub fn inc(rt: anytype) void {
        rt.set(.count, rt.state.count + 1);
    }
};
