//! Kit: the runtime front end's common widgets behind one value that holds the frame and the
//! theme, each taking its options by name. Tier 2, over the widgets' own functions (it adds no
//! behaviour; `ui.button(.save, .{ .label = "Save" })` is `button.button(f, th, .from("save"),
//! "Save")`).
//!
//!     const ui = kit.on(f, &app.theme);
//!     if (ui.button(.save, .{ .label = "Save" }).clicked) save();
//!     _ = ui.slider(.gain, &app.gain, .{ .min = 0, .max = 4 });
//!     _ = ui.text("Gain {d:.1} dB", .{app.gain});
//!
//! An id is an enum literal (hashed while compiling, as `Id.from`) or an `Id` for one made at
//! run time (`Id.from("row").with(i)`). Options are checked while compiling: a misspelt one is
//! a compile error that names it.

const std = @import("std");
const types = @import("../core/types.zig");
const base = @import("base.zig");
const label_zig = @import("label.zig");
const button_zig = @import("button.zig");
const checkbox_zig = @import("checkbox.zig");
const slider_zig = @import("slider.zig");
const textfield_zig = @import("textfield.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Theme = base.Theme;
const Id = types.Id;
const Node = types.Node;
const Response = types.Response;

pub const Kit = struct {
    f: *Frame,
    theme: *const Theme,

    /// Text showing `str`, copied (it may be a temporary).
    pub fn label(ui: Kit, str: []const u8) Node {
        return label_zig.label(ui.f, ui.theme, str);
    }

    /// Text of `args` formatted by `fmt` (`std.fmt`), written into the frame's strings: no
    /// buffer of the caller's.
    pub fn text(ui: Kit, comptime fmt: []const u8, args: anytype) Node {
        return ui.f.textfStyled(fmt, args, label_zig.labelText(ui.theme), label_zig.labelStyle(ui.theme));
    }

    pub const ButtonOptions = struct { label: []const u8 = "" };

    /// A button; `clicked` is set the frame it fires.
    pub fn button(ui: Kit, id: anytype, o: ButtonOptions) Response {
        return button_zig.button(ui.f, ui.theme, idOf(id), o.label);
    }

    pub const CheckboxOptions = struct { label: []const u8 = "" };

    /// A checkbox over `value` (a `*bool` or a `*Check`), toggled by a click or Space.
    pub fn checkbox(ui: Kit, id: anytype, value: anytype, o: CheckboxOptions) Response {
        return checkbox_zig.checkbox(ui.f, ui.theme, idOf(id), value, o.label);
    }

    pub const SliderOptions = struct { min: f32 = 0, max: f32 = 1 };

    /// A slider over `value`, from `min` at the left end to `max` at the right.
    pub fn slider(ui: Kit, id: anytype, value: *f32, o: SliderOptions) Response {
        return slider_zig.slider(ui.f, ui.theme, idOf(id), value, o.min, o.max);
    }

    pub const TextfieldOptions = struct { hint: []const u8 = "" };

    /// A one-line text field over `state` (a `*textfield.Text(cap)`), showing `hint` while
    /// empty; what the input did to the text is `state.result`.
    pub fn textfield(ui: Kit, id: anytype, state: anytype, o: TextfieldOptions) Response {
        return textfield_zig.textfield(ui.f, ui.theme, idOf(id), state, o.hint);
    }
};

/// The kit over frame `f` with theme `th`, for this frame.
pub fn on(f: *Frame, th: *const Theme) Kit {
    return .{ .f = f, .theme = th };
}

/// `id` as an `Id`: an `Id` as it is, an enum literal hashed while compiling.
pub fn idOf(id: anytype) Id {
    const T = @TypeOf(id);
    if (T == Id) return id;
    if (T == @EnumLiteral()) return comptime Id.from(@tagName(id));
    @compileError("an id is an enum literal (`.save`) or an `Id`, not " ++ @typeName(T));
}

const testing = std.testing;
const context = @import("../runtime/context.zig");
const mem = @import("../core/mem.zig");
const Input = @import("../core/input.zig").Input;

const KitApp = struct {
    theme: Theme = .default,
    gain: f32 = 1.25,
    loud: bool = false,

    fn build(app: *KitApp, f: *Frame, kit: bool) void {
        const th = &app.theme;
        _ = f.open(.from("panel"), .{ .pad = @splat(8), .gap = 4 });
        if (kit) {
            const ui = on(f, th);
            _ = ui.button(.save, .{ .label = "Save" });
            _ = ui.checkbox(.loud, &app.loud, .{ .label = "Loud" });
            _ = ui.slider(.gain, &app.gain, .{ .min = 0, .max = 4 });
            _ = ui.text("Gain {d:.1}", .{app.gain});
        } else {
            _ = button_zig.button(f, th, .from("save"), "Save");
            _ = checkbox_zig.checkbox(f, th, .from("loud"), &app.loud, "Loud");
            _ = slider_zig.slider(f, th, .from("gain"), &app.gain, 0, 4);
            var buf: [32]u8 = undefined;
            _ = label_zig.label(f, th, std.fmt.bufPrint(&buf, "Gain {d:.1}", .{app.gain}) catch unreachable);
        }
        f.close();
    }
};

const kit_limits: context.Limits = .{ .nodes = 32, .texts = 8, .customs = 1, .strings = 256, .depth = 8 };
var kit_buffers: [2][context.Context.requiredBytes(kit_limits)]u8 align(mem.column_align) = undefined;

test "kit: the same draw list as the widgets' own functions, text formatted in place" {
    var ctx: [2]context.Context = undefined;
    var apps: [2]KitApp = .{ .{}, .{} };
    var outs: [2]context.Output = undefined;
    const in: Input = .{ .viewport = .{ 400, 300 } };
    for (&ctx, &apps, &outs, &kit_buffers, 0..) |*c, *app, *out, *buf, k| {
        c.* = try context.Context.init(buf, kit_limits);
        var f = c.begin(&in);
        app.build(&f, k == 0);
        out.* = f.end(.{});
    }
    try testing.expect(base.sameDraw(outs[0].draw, outs[1].draw));
    try testing.expect(std.mem.indexOf(u8, outs[0].draw.strings, "Gain 1.2") != null or std.mem.indexOf(u8, outs[0].draw.strings, "Gain 1.3") != null);
    try testing.expectEqual(comptime Id.from("save"), idOf(.save));
}
