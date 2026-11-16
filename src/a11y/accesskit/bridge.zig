//! The AccessKit bridge: hands the semantic tree (`a11y.Export`, src/a11y/tree.zig) to the
//! platform through AccessKit's C interface. An adapter outside the tiers (docs/ARCHITECTURE.md):
//! built as its own module over `lcgr` (`zig build accesskit`), never imported by the core.
//!
//! The host runs the tier-0 passes (`names`, `states`, `flatten`) after each frame, then calls
//! `frame` here and the platform adapter's `update`. AccessKit calls back only into this file,
//! and only to read what `frame` stored or to queue a request; it never reaches the UI's columns
//! from another thread. When assistive technology first connects (activation), the bridge
//! answers "not ready" and asks for a frame; that frame's update carries the whole tree, as
//! AccessKit requires after such an answer.

const std = @import("std");
const lcgr = @import("lcgr");
const c = @import("c.zig");
const a11y = lcgr.a11y_tree;
const simd = lcgr.simd;
const mem = lcgr.mem;
const none = lcgr.types.none;
const Export = a11y.Export;
const Role = a11y.Role;
const scheduler = lcgr.scheduler;

/// The window: the tree's root, above the exported rows. Export ids are u32, so no row has it.
pub const root_id: c.NodeId = 1 << 32;

/// AccessKit's role for each `a11y.Role` byte; a stray byte reads `unknown`.
pub const roles: [256]c.Role = blk: {
    var m: [256]c.Role = @splat(.unknown);
    for (@typeInfo(Role).@"enum".field_values) |v| m[v] = switch (@as(Role, @fromBackingInt(v))) {
        .none, .group => .group,
        .label => .label,
        .button => .button,
        .checkbox => .check_box,
        .slider => .slider,
        .image => .image,
        .text_input => .text_input,
        .link => .link,
        .radio => .radio_button,
        .radio_group => .radio_group,
        .@"switch" => .@"switch",
        .spin_button => .spin_button,
        .meter => .meter,
        .progress_bar => .progress_indicator,
        .scroll_bar => .scroll_bar,
        .separator => .splitter,
        .heading => .heading,
        .article => .article,
        .feed => .feed,
        .list => .list,
        .list_item => .list_item,
        .combobox => .combo_box,
        .listbox => .list_box,
        .option => .list_box_option,
        .menu => .menu,
        .menu_bar => .menu_bar,
        .menu_item => .menu_item,
        .menu_item_checkbox => .menu_item_check_box,
        .menu_item_radio => .menu_item_radio,
        .tab_list => .tab_list,
        .tab => .tab,
        .tab_panel => .tab_panel,
        .toolbar => .toolbar,
        .tree => .tree,
        .tree_item => .tree_item,
        .grid => .grid,
        .tree_grid => .tree_grid,
        .table => .table,
        .row_group => .row_group,
        .row => .row,
        .cell => .cell,
        .column_header => .column_header,
        .row_header => .row_header,
        .dialog => .dialog,
        .alert_dialog => .alert_dialog,
        .alert => .alert,
        .tooltip => .tooltip,
        .region => .region,
        .banner => .banner,
        .navigation => .navigation,
        .main => .main,
        .complementary => .complementary,
        .content_info => .content_info,
        .form => .form,
        .search => .search,
        .status => .status,
    };
    break :blk m;
};

/// What a role offers assistive technology, indexed by the role byte.
const Offers = bitpack struct(u8) {
    click: bool = false,
    focus: bool = false,
    /// A numeric value: sent as the node's value, settable.
    value: bool = false,
    /// A checked state: sent as toggled, true or false.
    toggle: bool = false,
    _: u4 = 0,
};

const offers: [256]Offers = blk: {
    var m: [256]Offers = @splat(.{});
    const press: Offers = .{ .click = true, .focus = true };
    for ([_]Role{ .button, .link, .tab, .menu_item, .option, .tree_item, .combobox }) |r| m[@backingInt(r)] = press;
    for ([_]Role{ .checkbox, .radio, .@"switch", .menu_item_checkbox, .menu_item_radio }) |r|
        m[@backingInt(r)] = .{ .click = true, .focus = true, .toggle = true };
    for ([_]Role{ .slider, .spin_button, .scroll_bar }) |r| m[@backingInt(r)] = .{ .focus = true, .value = true };
    m[@backingInt(Role.text_input)] = .{ .focus = true };
    // Shown, not set.
    for ([_]Role{ .meter, .progress_bar }) |r| m[@backingInt(r)] = .{ .value = true };
    break :blk m;
};

pub const Bridge = struct {
    /// The window's name, read by assistive technology as the application's top window.
    title: []const u8,
    /// Physical pixels per logical pixel; the root's transform, so rows stay in logical pixels.
    scale: f32 = 1,
    /// Per export row (and one past for the root), where its children start in `kids`. Filled
    /// by `frame`.
    first: []u32,
    /// Every row's children ids, grouped by parent in tree order.
    kids: []c.NodeId,
    /// Set by activation: the next update must carry the whole tree.
    full: std.atomic.Value(bool) = .init(false),
    // ---- this frame, stored by `frame`
    cur: ?*const Export = null,
    /// Rows that changed since the last frame (`a11y.diff`).
    ch: ?*const a11y.Changes = null,
    strings: []const u8 = "",
    /// Focused export id (`Interaction.focus`), or 0.
    focus: u32 = 0,
    /// The top-level rows' `kids_hash` the window was last sent with.
    top_hash: u32 = 0,
    // ---- requests from assistive technology
    /// Queued by the action handler on AccessKit's threads, drained by the UI with `drain`.
    queue: scheduler.Mailbox(a11y.Action),
    /// Held while pushing: the Mailbox takes one producer, and UI Automation may call the
    /// handler from several threads.
    pushing: std.atomic.Value(bool) = .init(false),
    /// Posted with each request and on activation, so `needsFrame` says yes.
    waker: ?*scheduler.Wake = null,
    /// Interrupts the shell's wait (`shell.wake`, thread-safe), so the frame comes now.
    wake: ?Wake = null,

    pub const Wake = struct { ctx: ?*anyopaque, f: *const fn (?*anyopaque) void };

    /// Requests a frame from any thread.
    fn askFrame(b: *Bridge) void {
        if (b.waker) |w| w.post();
        if (b.wake) |w| w.f(w.ctx);
    }

    /// Carves the children scratch for exports of up to `cap` rows. With a counting carver this
    /// sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32, title: []const u8) Bridge {
        return .{
            .title = title,
            .first = carver.slice(u32, cap + 1),
            .kids = carver.slice(c.NodeId, cap),
            // Not `Mailbox.init`: a counting carver hands out empty slices.
            .queue = .{ .buf = carver.slice(a11y.Action, queue_len) },
        };
    }

    /// Requests a frame may receive; more in one frame are dropped (a user acts far slower).
    pub const queue_len = 64;

    /// Stores this frame's export and its changes (`a11y.diff` against the previous frame's) for
    /// the next update, and groups each row's children. `strings` are the frame's bytes the names
    /// point into; they must stay valid until the update. Call it for every built frame, so no
    /// frame's changes are skipped.
    pub fn frame(b: *Bridge, cur: *const Export, ch: *const a11y.Changes, strings: []const u8, focus: u32) void {
        std.debug.assert(b.first.len > cur.len and b.kids.len >= cur.len);
        const n = cur.len;
        const e = &cur.c;
        // Counting sort by parent: `first[p]` ends past p's children, then each row, walked
        // backwards, steps its parent's cursor back, leaving `first[p]` at p's first child.
        // Top-level rows (parent `none`) are the root's, bucket `n`.
        var end: u32 = 0;
        for (0..n) |r| {
            end += e.kids[r];
            b.first[r] = end;
        }
        b.first[n] = end + e.kids[cur.cap];
        var r = n;
        while (r > 0) {
            r -= 1;
            const p = @min(e.parent[r], n);
            b.first[p] -= 1;
            b.kids[b.first[p]] = e.id[r];
        }
        b.cur = cur;
        b.ch = ch;
        b.strings = strings;
        b.focus = focus;
    }

    /// The tree update for the stored frame: every row, with the tree's root and toolkit.
    pub fn fullUpdate(b: *Bridge) *c.TreeUpdate {
        const cur = b.cur.?;
        const u = c.accesskit_tree_update_with_capacity_and_focus(cur.len + 1, b.focusId());
        const info = c.accesskit_tree_info_new(root_id);
        c.accesskit_tree_info_set_toolkit_name_with_length(info, "lcgr", 4);
        c.accesskit_tree_update_set_tree_info(u, info);
        c.accesskit_tree_update_push_node(u, root_id, b.rootNode());
        for (0..cur.len) |r| c.accesskit_tree_update_push_node(u, cur.c.id[r], b.node(@intCast(r)));
        b.top_hash = cur.c.kids_hash[cur.cap];
        return u;
    }

    /// The tree update for the stored frame's changes: the rows `a11y.diff` found new or
    /// changed, in tree order, and the window when its top-level rows changed. Rows that went
    /// are not named: their parent is sent with its new child list, and AccessKit drops what no
    /// node refers to any more. Focus is sent every time.
    pub fn changesUpdate(b: *Bridge) *c.TreeUpdate {
        const cur = b.cur.?;
        const ch = b.ch.?;
        const top = cur.c.kids_hash[cur.cap];
        const u = c.accesskit_tree_update_with_capacity_and_focus(ch.updated_len + 1, b.focusId());
        if (top != b.top_hash) c.accesskit_tree_update_push_node(u, root_id, b.rootNode());
        b.top_hash = top;
        for (ch.updated[0..ch.updated_len]) |r| c.accesskit_tree_update_push_node(u, cur.c.id[r], b.node(r));
        return u;
    }

    /// The focused node: the focused widget when it is exported, else the window.
    fn focusId(b: *const Bridge) c.NodeId {
        const cur = b.cur.?;
        const found = b.focus != 0 and simd.find(cur.c.id, cur.len, b.focus) != none;
        return if (found) b.focus else root_id;
    }

    fn rootNode(b: *const Bridge) *c.Node {
        const n = c.accesskit_node_new(.window);
        const cur = b.cur.?;
        c.accesskit_node_set_transform(n, c.accesskit_affine_scale(b.scale));
        c.accesskit_node_set_label_with_length(n, b.title.ptr, b.title.len);
        c.accesskit_node_set_children(n, cur.c.kids[cur.cap], b.kids[b.first[cur.len]..].ptr);
        return n;
    }

    /// Export row `r` as an AccessKit node.
    fn node(b: *const Bridge, r: u32) *c.Node {
        const e = &b.cur.?.c;
        const role = e.role[r];
        const n = c.accesskit_node_new(roles[role]);
        c.accesskit_node_set_bounds(n, .{ .x0 = e.rect[0][r], .y0 = e.rect[1][r], .x1 = e.rect[2][r], .y1 = e.rect[3][r] });
        c.accesskit_node_set_children(n, e.kids[r], b.kids[b.first[r]..].ptr);
        if (e.name_bytes[r] != 0) c.accesskit_node_set_label_with_length(n, b.strings[e.name_start[r]..].ptr, e.name_bytes[r]);
        const st: a11y.State = @bitCast(e.state[r]);
        const of = offers[role];
        if (of.toggle) c.accesskit_node_set_toggled(n, if (st.checked) .true else .false);
        if (st.expandable) c.accesskit_node_set_expanded(n, st.expanded);
        if (st.selected) c.accesskit_node_set_selected(n, true);
        if (st.disabled) c.accesskit_node_set_disabled(n);
        if (of.value) c.accesskit_node_set_numeric_value(n, e.value[r]);
        if (role == @backingInt(Role.status)) c.accesskit_node_set_live(n, .polite);
        // A disabled control takes focus (to be read) but does nothing.
        if (of.focus) c.accesskit_node_add_action(n, .focus);
        if (st.disabled) return n;
        if (of.click) c.accesskit_node_add_action(n, .click);
        // ponytail: no increment or decrement; the export has no range to step in. Add a
        // step column to `a11y.Export` if a screen reader's arrow keys must move sliders.
        if (of.value and of.focus) c.accesskit_node_add_action(n, .set_value);
        return n;
    }

    /// AccessKit's activation handler (`userdata` is the bridge): assistive technology connected.
    /// Answers "not ready", so AccessKit waits for the next update, which then carries the whole
    /// tree; the tree is never read off the UI thread.
    pub fn activate(userdata: ?*anyopaque) callconv(.c) ?*c.TreeUpdate {
        const b: *Bridge = @ptrCast(@alignCast(userdata.?));
        b.full.store(true, .release);
        b.askFrame();
        return null;
    }

    /// AccessKit's action handler (`userdata` is the bridge), on any thread: queues the request
    /// as an `a11y.Action` row and asks for a frame. Owns `request` and frees it.
    pub fn act(request: *c.ActionRequest, userdata: ?*anyopaque) callconv(.c) void {
        const b: *Bridge = @ptrCast(@alignCast(userdata.?));
        b.queueRequest(request);
        c.accesskit_action_request_free(request);
    }

    /// Converts one request and queues it: click is a press, focus a focus, a numeric
    /// set_value sets the value. Others, and requests for the window, are dropped.
    pub fn queueRequest(b: *Bridge, request: *const c.ActionRequest) void {
        const kind: a11y.Action.Kind = switch (request.action) {
            .click => .press,
            .focus => .focus,
            .set_value => .set_value,
            else => return,
        };
        if (request.target_node > std.math.maxInt(u32)) return;
        var row: a11y.Action = .{ .kind = kind, .target = @intCast(request.target_node) };
        if (kind == .set_value) {
            const d = &request.data;
            if (!d.has_value or d.value.tag != .numeric_value) return;
            row.value = @floatCast(d.value.u.numeric_value);
        }
        while (b.pushing.swap(true, .acquire)) std.atomic.spinLoopHint();
        _ = b.queue.push(row);
        b.pushing.store(false, .release);
        b.askFrame();
    }

    /// On the UI thread, before building the frame: the requests queued since the last call,
    /// copied to `out`, for `a11y.apply` and `a11y.setValue`.
    pub fn drain(b: *Bridge, out: []a11y.Action) []a11y.Action {
        var n: usize = 0;
        while (n < out.len) : (n += 1) out[n] = b.queue.pop() orelse break;
        return out[0..n];
    }

    /// AccessKit's tree update factory, called by the adapter's update on the UI thread.
    pub fn factory(userdata: ?*anyopaque) callconv(.c) ?*c.TreeUpdate {
        const b: *Bridge = @ptrCast(@alignCast(userdata.?));
        return if (b.full.swap(false, .acq_rel)) b.fullUpdate() else b.changesUpdate();
    }
};

const testing = std.testing;
const Tree = lcgr.tree.Tree;
const Texts = lcgr.texts.Texts;
const Strings = lcgr.strings.Strings;

/// A frame's columns for the tests: tree, text runs, bytes, semantics, two exports, changes and
/// a bridge over a buffer.
pub fn Fixture(comptime cap: u32) type {
    return struct {
        const Self = @This();
        buf: [bytes]u8 align(mem.column_align) = undefined,
        bytes_buf: [1024]u8 = undefined,
        t: Tree = undefined,
        tx: Texts = undefined,
        str: Strings = undefined,
        s: a11y.Semantics = undefined,
        out: [2]Export = undefined,
        ch: a11y.Changes = undefined,
        b: Bridge = undefined,
        gen: u1 = 0,

        fn carve(f: ?*Self, carver: *mem.Carver) void {
            const t = Tree.init(carver, cap);
            const tx = Texts.init(carver, cap);
            const s = a11y.Semantics.init(carver, cap);
            const out = [2]Export{ Export.init(carver, cap), Export.init(carver, cap) };
            const ch = a11y.Changes.init(carver, cap);
            const b = Bridge.init(carver, cap, "Example");
            if (f) |x| {
                x.t = t;
                x.tx = tx;
                x.s = s;
                x.out = out;
                x.ch = ch;
                x.b = b;
                x.str = .{ .buf = &x.bytes_buf };
            }
        }
        const bytes = blk: {
            @setEvalBranchQuota(60_000);
            var counter: mem.Carver = .{ .buf = null };
            carve(null, &counter);
            break :blk counter.off;
        };
        pub fn init(f: *Self) void {
            var carver: mem.Carver = .{ .buf = &f.buf };
            carve(f, &carver);
        }
        /// Starts a new frame, as a front end does.
        pub fn reset(f: *Self) void {
            f.t.reset();
            f.tx.reset();
            f.str.reset();
            f.s.clear();
        }
        pub fn text(f: *Self, parent: u32, str: []const u8) u32 {
            const n = f.t.push(parent, .none, &.{ .role = .label });
            f.t.c.text[n] = f.tx.push(n, f.str.add(str), &.{});
            f.t.seal(n);
            return n;
        }
        /// Runs the passes, diffs against last frame and hands the export to the bridge.
        pub fn end(f: *Self, focus: u32) void {
            f.gen +%= 1;
            a11y.names(&f.t, &f.s);
            a11y.states(&f.t, &f.s);
            a11y.flatten(&f.t, &f.tx, f.str.buf[0..f.str.len], &f.s, &f.out[f.gen]);
            a11y.diff(&f.out[f.gen], &f.out[f.gen ^ 1], &f.ch);
            f.b.frame(&f.out[f.gen], &f.ch, f.str.buf[0..f.str.len], focus);
        }
    };
}

/// The example's toolbar: a Reset button, a Wireframe checkbox (on) and an Exposure slider.
pub fn buildToolbar(f: anytype, wire: bool, exposure: f32) void {
    const t = &f.t;
    const root = t.push(0, .none, &.{});
    const bar = t.push(root, .from("toolbar"), &.{});
    t.c.role[bar] = @backingInt(Role.toolbar);
    const reset = t.push(bar, .from("reset"), &.{ .role = .button });
    _ = f.text(reset, "Reset");
    t.seal(reset);
    const wf = t.push(bar, .from("wireframe"), &.{ .role = .checkbox, .value = @floatFromInt(@intFromBool(wire)) });
    _ = f.text(wf, "Wireframe");
    t.seal(wf);
    const lab = f.text(bar, "Exposure");
    const sl = t.push(bar, .from("exposure"), &.{ .role = .slider, .value = exposure });
    t.seal(sl);
    t.seal(bar);
    t.seal(root);
    f.s.c.labelled_by[sl] = lab;
}

/// AccessKit's debug form of `u`, freed.
fn debugText(u: *c.TreeUpdate, out: []u8) []const u8 {
    const s = c.accesskit_tree_update_debug(u);
    defer c.accesskit_string_free(s);
    const got = std.mem.span(s);
    const len = @min(got.len, out.len);
    @memcpy(out[0..len], got[0..len]);
    return out[0..len];
}

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing {s} in\n{s}\n", .{ needle, hay });
        return error.TestExpectedEqual;
    }
}

test "accesskit: the whole tree goes out after activation, rooted at the window" {
    var f: Fixture(32) = .{};
    f.init();
    f.reset();
    buildToolbar(&f, true, 1.5);
    f.end(@backingInt(lcgr.types.Id.from("reset")));
    // Activation answers "not ready" and marks the next update as the whole tree.
    try testing.expectEqual(null, Bridge.activate(&f.b));
    try testing.expect(f.b.full.load(.acquire));
    const u = Bridge.factory(&f.b).?;
    defer c.accesskit_tree_update_free(u);
    try testing.expect(!f.b.full.load(.acquire));
    var buf: [8192]u8 = undefined;
    const d = debugText(u, &buf);
    try expectHas(d, "Window");
    try expectHas(d, "\"Example\"");
    try expectHas(d, "Toolbar");
    try expectHas(d, "Button");
    try expectHas(d, "\"Reset\"");
    try expectHas(d, "CheckBox");
    try expectHas(d, "\"Wireframe\"");
    try expectHas(d, "toggled: True");
    try expectHas(d, "Slider");
    try expectHas(d, "\"Exposure\"");
    try expectHas(d, "numeric_value: 1.5");
    try expectHas(d, "Click");
    try expectHas(d, "SetValue");
    try expectHas(d, "\"lcgr\"");
    var idbuf: [32]u8 = undefined;
    try expectHas(d, try std.fmt.bufPrint(&idbuf, "focus: #{d}", .{@backingInt(lcgr.types.Id.from("reset"))}));
}

/// Node ids pushed in `u`, in order, read from its debug form.
fn pushedIds(u: *c.TreeUpdate, out: []c.NodeId) ![]c.NodeId {
    var buf: [8192]u8 = undefined;
    const d = debugText(u, &buf);
    var n: usize = 0;
    // Each pushed node prints as `(#id, Node {`.
    var it = std.mem.splitSequence(u8, d, "(#");
    _ = it.next();
    while (it.next()) |part| {
        const end = std.mem.indexOfScalar(u8, part, ',') orelse continue;
        out[n] = try std.fmt.parseInt(c.NodeId, part[0..end], 10);
        n += 1;
    }
    return out[0..n];
}

fn idOf(comptime name: []const u8) c.NodeId {
    return @backingInt(lcgr.types.Id.from(name));
}

test "accesskit: later frames send only the rows that changed, and the window when its rows do" {
    var f: Fixture(32) = .{};
    f.init();
    f.reset();
    buildToolbar(&f, true, 1.5);
    f.end(0);
    _ = Bridge.activate(&f.b);
    c.accesskit_tree_update_free(Bridge.factory(&f.b).?);
    var ids: [32]c.NodeId = undefined;

    // Nothing changed: an update with focus only (the window, as nothing is focused).
    f.reset();
    buildToolbar(&f, true, 1.5);
    f.end(0);
    var u = Bridge.factory(&f.b).?;
    try testing.expectEqualSlices(c.NodeId, &.{}, try pushedIds(u, &ids));
    var buf: [8192]u8 = undefined;
    var idbuf: [32]u8 = undefined;
    try expectHas(debugText(u, &buf), try std.fmt.bufPrint(&idbuf, "focus: #{d}", .{root_id}));
    c.accesskit_tree_update_free(u);

    // The checkbox unticked and the slider moved: those two rows, in tree order.
    f.reset();
    buildToolbar(&f, false, 2);
    f.end(@backingInt(lcgr.types.Id.from("exposure")));
    u = Bridge.factory(&f.b).?;
    try testing.expectEqualSlices(c.NodeId, &.{ idOf("wireframe"), idOf("exposure") }, try pushedIds(u, &ids));
    const d = debugText(u, &buf);
    try expectHas(d, "toggled: False");
    try expectHas(d, "numeric_value: 2.0");
    try expectHas(d, try std.fmt.bufPrint(&idbuf, "focus: #{d}", .{idOf("exposure")}));
    c.accesskit_tree_update_free(u);

    // A second top-level row (a status line): the window goes again with it.
    f.reset();
    buildToolbar(&f, false, 2);
    const st = f.t.push(0, .from("status"), &.{});
    f.t.c.role[st] = @backingInt(Role.status);
    _ = f.text(st, "Saved");
    f.t.seal(st);
    f.end(0);
    u = Bridge.factory(&f.b).?;
    const got = try pushedIds(u, &ids);
    try testing.expectEqual(root_id, got[0]);
    try testing.expectEqual(idOf("status"), got[1]);
    try expectHas(debugText(u, &buf), "live: Polite");
    c.accesskit_tree_update_free(u);

    // Activation again (a screen reader restarted): the whole tree, whatever changed.
    f.reset();
    buildToolbar(&f, false, 2);
    f.end(0);
    _ = Bridge.activate(&f.b);
    u = Bridge.factory(&f.b).?;
    try testing.expectEqual(1 + f.out[f.gen].len, (try pushedIds(u, &ids)).len);
    c.accesskit_tree_update_free(u);
}

/// The bridge's side of a host loop, over a `Context`: the semantic columns, this and last
/// frame's export, and the changes between them. `frame` runs the tier-0 passes on a built
/// frame and hands the result to the bridge.
pub fn Host(comptime cap: u32) type {
    return struct {
        const Self = @This();
        buf: [bytes]u8 align(mem.column_align) = undefined,
        s: a11y.Semantics = undefined,
        out: [2]Export = undefined,
        ch: a11y.Changes = undefined,
        b: Bridge = undefined,
        gen: u1 = 0,

        fn carve(h: ?*Self, carver: *mem.Carver, title: []const u8) void {
            const s = a11y.Semantics.init(carver, cap);
            const out = [2]Export{ Export.init(carver, cap), Export.init(carver, cap) };
            const ch = a11y.Changes.init(carver, cap);
            const b = Bridge.init(carver, cap, title);
            if (h) |x| {
                x.s = s;
                x.out = out;
                x.ch = ch;
                x.b = b;
            }
        }
        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            carve(null, &counter, "");
            break :blk counter.off;
        };
        /// `ctx`'s waker is posted with each request; `wake` interrupts the shell's wait.
        pub fn init(h: *Self, title: []const u8, ctx: *lcgr.context.Context, wake: ?Bridge.Wake) void {
            var carver: mem.Carver = .{ .buf = &h.buf };
            carve(h, &carver, title);
            h.b.waker = &ctx.waker;
            h.b.wake = wake;
        }
        /// After `Frame.end`: exports the frame `ctx` just built and stores it in the bridge.
        /// Semantic inputs (`labelled_by`, application states) are set on `h.s` while building
        /// and cleared here for the next frame.
        pub fn frame(h: *Self, ctx: *const lcgr.context.Context, out: *const lcgr.context.Output) void {
            std.debug.assert(out.tree.len <= cap);
            const str = &ctx.strings[ctx.cur];
            h.gen +%= 1;
            a11y.names(out.tree, &h.s);
            a11y.states(out.tree, &h.s);
            a11y.flatten(out.tree, out.texts, str.buf[0..str.len], &h.s, &h.out[h.gen]);
            a11y.diff(&h.out[h.gen], &h.out[h.gen ^ 1], &h.ch);
            h.b.frame(&h.out[h.gen], &h.ch, str.buf[0..str.len], ctx.inter.focus);
            h.s.clear();
        }
    };
}

test "accesskit: action requests reach the example as the user's own input" {
    const example = lcgr.shell_example;
    const Context = lcgr.context.Context;
    const limits: lcgr.context.Limits = .{ .nodes = 256, .texts = 64 };
    const S = struct {
        var ctx_buffer: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
        var host: Host(256) = .{};
        var woken: u32 = 0;
        fn wake(_: ?*anyopaque) void {
            woken += 1;
        }
    };
    var ctx = try Context.init(&S.ctx_buffer, limits);
    const h = &S.host;
    h.init("Example", &ctx, .{ .ctx = null, .f = S.wake });
    var app: example.App = .{};
    var ev: lcgr.shell_iface.Events = .{};
    ev.in.viewport = .{ 800, 600 };
    var acts_buf: [Bridge.queue_len]a11y.Action = undefined;

    const Step = struct {
        fn run(cx: *Context, ap: *example.App, e: *lcgr.shell_iface.Events, hh: *Host(256), buf: []a11y.Action) void {
            const acts = hh.b.drain(buf);
            var f = cx.begin(&e.in);
            a11y.apply(&cx.inter, acts);
            ap.build(&f, e);
            const out = f.end(.{});
            hh.frame(cx, &out);
        }
    };
    Step.run(&ctx, &app, &ev, h, &acts_buf);
    // A screen reader connects: it gets the whole example once a frame is built.
    _ = Bridge.activate(&h.b);
    try testing.expect(ctx.needsFrame(&ev.in));
    try testing.expectEqual(1, S.woken);
    Step.run(&ctx, &app, &ev, h, &acts_buf);
    const u = Bridge.factory(&h.b).?;
    var buf: [16384]u8 = undefined;
    const d = debugText(u, &buf);
    try expectHas(d, "label: \"Reset\"");
    try expectHas(d, "label: \"Add layer\"");
    try expectHas(d, "label: \"Layer 2\"");
    c.accesskit_tree_update_free(u);

    // "Press Reset", "focus Exposure", "set Exposure to 3", and a scroll the bridge does not
    // take, as AccessKit hands them over.
    const id_reset = @backingInt(example.id_reset);
    const id_exp = @backingInt(example.id_exposure);
    var req: c.ActionRequest = .{ .action = .click, .target_tree = @splat(0), .target_node = id_reset, .data = .{ .has_value = false, .value = undefined } };
    h.b.queueRequest(&req);
    req.action = .focus;
    req.target_node = id_exp;
    h.b.queueRequest(&req);
    req.action = .set_value;
    req.data = .{ .has_value = true, .value = .{ .tag = .numeric_value, .u = .{ .numeric_value = 3 } } };
    h.b.queueRequest(&req);
    req.action = @fromBackingInt(@intCast(11)); // scroll_down
    h.b.queueRequest(&req);
    try testing.expectEqual(4, S.woken);
    try testing.expect(ctx.needsFrame(&ev.in));

    app.exposure = 2;
    const acts = h.b.drain(&acts_buf);
    try testing.expectEqual(3, acts.len);
    try testing.expectEqual(a11y.Action.Kind.set_value, acts[2].kind);
    try testing.expectEqual(3, a11y.setValue(acts, example.id_exposure, app.exposure));
    // Put back for the frame, which drains them itself.
    for (acts) |a| _ = h.b.queue.push(a);
    Step.run(&ctx, &app, &ev, h, &acts_buf);
    try testing.expectEqual(1, app.resets);
    try testing.expectEqual(1, app.exposure); // Reset's click set it back
    try testing.expectEqual(id_exp, ctx.inter.focus);
    // The next update moves the screen reader's focus to Exposure.
    const next = Bridge.factory(&h.b).?;
    var idbuf: [32]u8 = undefined;
    try expectHas(debugText(next, &buf), try std.fmt.bufPrint(&idbuf, "focus: #{d}", .{id_exp}));
    c.accesskit_tree_update_free(next);
}
