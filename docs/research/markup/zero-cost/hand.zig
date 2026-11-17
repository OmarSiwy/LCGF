const lcgf = @import("lcgf");
const h = @import("handlers");
const s = lcgf.spec;
const w = lcgf.widgets_base;
const th: w.Theme = .default;
const button = lcgf.widgets_button.ct.button;
const label = lcgf.widgets_label.ct.label;

const page = s.col(.{ .pad = @splat(8), .gap = 4 }, .{
    label(th, .title),
    s.row(.{ .gap = 4 }, .{ button(th, .dec, .dec_text), button(th, .inc, .inc_text) }),
});
const Ui = w.ComptimeUi(h.App, page, th);

export fn probe(p: *anyopaque, in: *const anyopaque) usize {
    const ui: *Ui = @ptrCast(@alignCast(p));
    const out = ui.frame(@ptrCast(@alignCast(in)));
    if (out.event) |e| switch (e) {
        .dec => h.counter.dec(&ui.signals),
        .inc => h.counter.inc(&ui.signals),
    };
    return out.draw.cmd_len;
}
