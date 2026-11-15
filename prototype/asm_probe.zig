const ui = @import("ui.zig");
export fn p_prepare(t: *ui.Tree) void {
    ui.layout.prepare(t);
}
export fn p_fit(t: *ui.Tree) void {
    ui.layout.fit(t, .x);
}
export fn p_resolve(t: *ui.Tree) void {
    ui.layout.resolve(t, .x, 800);
}
export fn p_place(t: *ui.Tree) void {
    ui.layout.place(t);
}
export fn p_finalize(t: *ui.Tree) void {
    ui.layout.finalize(t);
}
export fn p_hit(t: *const ui.Tree, x: f32, y: f32) u32 {
    return ui.hit.at(t, x, y, .any);
}
export fn p_paint(t: *const ui.Tree, tx: *const ui.Texts, cu: *const ui.Customs, d: *ui.DrawList) void {
    ui.paint.emit(t, tx, cu, "", d);
}
export fn p_anim(a: *ui.Anims, dt: f32) f32 {
    return a.step(dt);
}
export fn p_sweep(a: *ui.Anims, frame: u32) void {
    a.sweep(frame);
}
export fn p_find(col: [*]const u32, len: u32, needle: u32) u32 {
    return ui.simd.find(col[0 .. len + 16], len, needle);
}
export fn p_measure(tx: *ui.Texts) void {
    (ui.fonts.Mono{}).measure(tx);
}
export fn p_wrap(tx: *ui.Texts) void {
    (ui.fonts.Mono{}).wrap(tx);
}
export fn p_step(s: *ui.Interaction, prev: *const ui.Tree, in: *const ui.Input) void {
    s.step(prev, in);
}
export fn p_response(s: *const ui.Interaction, id: u32) u8 {
    return @bitCast(s.response(@fromBackingInt(id)));
}
export fn p_push(t: *ui.Tree, parent: u32, id: u32, s: *const ui.Style) u32 {
    return t.push(parent, @fromBackingInt(id), s);
}
