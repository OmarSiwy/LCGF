//! expect: region 'view' floats and is sized .fill: a floating node is not in its parent's flow and takes no share of it, so it would be empty; write .pct(1) for the parent's content box, or .px(n)
// tidy: allow-file(line-too-long) the expected message is the first line, whole
const ct_interop = @import("lcgf").ct_interop;

comptime {
    _ = ct_interop.region(.view, .{ .float = true, .size = .{ .fill, .fill } });
}
