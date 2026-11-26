//! One markup fixture: the module lcgf-gen generated from `page.html` (`page`) against the
//! page written by hand (`twin`). The generated `Spec` must equal the twin's at compile time,
//! and when the twin also has the runtime page (`App`), both front ends must draw the same
//! lists frame by frame over the twin's `replay` (base.Harness).

const std = @import("std");
const lcgf = @import("lcgf");
const page = @import("page");
const twin = @import("twin");

test "the generated spec is the twin's" {
    comptime {
        @setEvalBranchQuota(200_000);
        std.testing.expectEqualDeep(twin.spec, page.spec) catch @compileError("the generated spec differs from twin.zig's");
    }
}

test "the generated theme and state defaults are the twin's" {
    try std.testing.expectEqualDeep(twin.theme, page.theme);
    if (@hasDecl(twin, "State")) {
        const a: twin.State = .{};
        const b: page.State = .{};
        inline for (comptime @typeInfo(twin.State).@"struct".field_names) |f| {
            // An lcgf-switch field is an enum each side declares: compare by tag.
            if (@TypeOf(@field(a, f)) != @TypeOf(@field(b, f)))
                try std.testing.expectEqualStrings(@tagName(@field(a, f)), @tagName(@field(b, f)))
            else
                try std.testing.expectEqualDeep(@field(a, f), @field(b, f));
        }
        try std.testing.expectEqual(@typeInfo(twin.State).@"struct".field_names.len, @typeInfo(page.State).@"struct".field_names.len);
    }
}

const Replay = lcgf.input.Replay;

var harness: if (@hasDecl(twin, "App")) lcgf.widgets_base.Harness(twin.App, page.Ui, twin.limits) else void = undefined;

test "both front ends draw the same frames" {
    if (!@hasDecl(twin, "App")) return;
    const h = &harness;
    h.init();
    var text: [16]u8 = undefined;
    var evs: [8]lcgf.input.Input.Event = undefined;
    var contacts: [1]lcgf.input.Input.Contact = undefined;
    const buf: Replay.Buffers = .{ .text = &text, .events = &evs, .contacts = &contacts };
    var replay: Replay = .{ .src = if (@hasDecl(twin, "replay")) twin.replay else "frame\nviewport 800 600\n" };
    while (try replay.next(buf)) |in| _ = try h.frame(in);
    try std.testing.expect(h.frames > 0);
}

test "the handler type checks and events reach it" {
    if (!@hasDecl(twin, "Handlers")) return;
    const H = twin.Handlers(page.Ui);
    // Too big for a test's stack with its tables.
    const p = &struct {
        var value: page.Page(H) = .{};
    }.value;
    var h: H = .{};
    if (@hasDecl(twin, "events")) try twin.events(page, p, &h);
}
