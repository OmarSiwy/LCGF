//! The runtime frontend's zero-cost probe: one frame of a generated runtime page. Built with
//! and without `--runtime-vars=t-` for pages that use no token, which must not differ. A page
//! with run-time regions builds from the app's items (`build(ui, f, data)`), which the probe
//! does not have, so it probes nothing there.

const lcgf = @import("lcgf");
const page = @import("ui");

var buffer: [lcgf.context.Context.requiredBytes(page.limits)]u8 align(lcgf.mem.column_align) = undefined;
var ui: page.Ui = .{};

export fn markup_probe_runtime_frame(in: *const lcgf.input.Input) u32 {
    if (comptime @typeInfo(@TypeOf(page.Ui.build)).@"fn".param_types.len != 2) return 0;
    var ctx = lcgf.context.Context.init(&buffer, page.limits) catch return 0;
    var f = ctx.begin(in);
    ui.build(&f);
    return f.end(.{}).tree.len;
}
