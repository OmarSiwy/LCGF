//! The runtime frontend's zero-cost probe: one frame of a generated runtime page. Built with
//! and without `--runtime-vars=t-` for pages that use no token, which must not differ. A page
//! with run-time regions builds from the twin's sample items (`twin.Sample`).

const lcgf = @import("lcgf");
const page = @import("ui");
const twin = @import("twin");

var buffer: [lcgf.context.Context.requiredBytes(page.limits)]u8 align(lcgf.mem.column_align) = undefined;
var ui: page.Ui = .{};
var items: if (@hasDecl(twin, "Sample")) twin.Sample else void = if (@hasDecl(twin, "Sample")) .{} else {};

export fn markup_probe_runtime_frame(in: *const lcgf.input.Input) u32 {
    var ctx = lcgf.context.Context.init(&buffer, page.limits) catch return 0;
    var f = ctx.begin(in);
    if (comptime @hasDecl(twin, "Sample")) ui.build(&f, items.data()) else ui.build(&f);
    return (if (comptime @hasDecl(page.Ui, "end")) ui.end(&f, .{}) else f.end(.{})).tree.len;
}
