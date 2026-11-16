//! expect: col > col[2] > row[1] > slider[3]: slider 'gain' needs an f32 field, not u8
const s = @import("lcgr").spec;

// The path counts every child, labels included, so it matches `children[i]` at each level.
comptime {
    @import("lcgr").validate.check(struct { gain: u8, x: f32 }, s.col(.{}, .{
        s.label(.x),
        s.label(.x),
        s.col(.{}, .{
            s.row(.{}, .{}),
            s.row(.{}, .{ s.label(.x), s.label(.x), s.slider(.a, .x), s.slider(.b, .gain) }),
        }),
    }));
}
