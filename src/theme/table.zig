//! Run-time theme tokens (docs/plans/schemify.md §2): a caller-owned table of the values a
//! compiled page reads while it builds (lengths, font sizes, radii, spacing, colours), with a
//! generation that every change bumps, so a page that saw another generation lays out again.
//! Tier 2: plain data, no allocation. `Tokens` is a struct of the token values with their
//! defaults.
//!
//!     var tokens: ThemeTable(page.Tokens) = .{};
//!     page_ui.tokens = &tokens;
//!     tokens.set(.space_m, 12); // the next frame lays out with it

const std = @import("std");

pub fn ThemeTable(comptime Tokens: type) type {
    return struct {
        const Self = @This();

        values: Tokens = .{},
        /// Bumped by every `set`; wraps.
        generation: u32 = 0,

        pub const Token = std.meta.FieldEnum(Tokens);

        /// Sets one token and bumps the generation.
        pub fn set(t: *Self, comptime token: Token, value: @FieldType(Tokens, @tagName(token))) void {
            @field(t.values, @tagName(token)) = value;
            t.generation +%= 1;
        }

        /// Whether the table changed since a reader saw generation `seen`.
        pub fn changedSince(t: *const Self, seen: u32) bool {
            return t.generation != seen;
        }
    };
}

test "ThemeTable: set changes the value and the generation" {
    const T = ThemeTable(struct { space_m: f32 = 8, size: f32 = 14 });
    var t: T = .{};
    const seen = t.generation;
    try std.testing.expect(!t.changedSince(seen));
    t.set(.space_m, 12);
    try std.testing.expectEqual(12, t.values.space_m);
    try std.testing.expectEqual(14, t.values.size);
    try std.testing.expect(t.changedSince(seen));
}
