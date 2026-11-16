//! The X Input Method protocol (XIM 1.0, "The Input Method Protocol", X Consortium), as far as
//! the X11 shell's IME client needs it: the messages it sends and the fields of those it reads,
//! and the decoding of COMPOUND_TEXT commits. Plain bytes, no OS; x11.zig carries the messages
//! over the X transport (ClientMessage and properties).
//!
//! Every message is a 4-byte header (major opcode, minor opcode, length of the body in 4-byte
//! units) and the body, little-endian after XIM_CONNECT says 'l'.

const std = @import("std");
const wire = @import("wire.zig");
const Buf = wire.Buf;
const get = wire.get;
const pad4 = wire.pad4;

pub const op = struct {
    pub const connect = 1;
    pub const connect_reply = 2;
    pub const err = 20;
    pub const open = 30;
    pub const open_reply = 31;
    pub const register_triggerkeys = 34;
    pub const set_event_mask = 37;
    pub const encoding_negotiation = 38;
    pub const encoding_negotiation_reply = 39;
    pub const create_ic = 50;
    pub const create_ic_reply = 51;
    pub const set_ic_values = 54;
    pub const set_ic_values_reply = 55;
    pub const set_ic_focus = 58;
    pub const unset_ic_focus = 59;
    pub const forward_event = 60;
    pub const sync = 61;
    pub const sync_reply = 62;
    pub const commit = 63;
};

/// Over-the-spot: the input method draws the composition itself, next to `spotLocation`, and
/// sends only the committed text. No status window.
pub const style_preedit_position = 0x0004;
pub const style_status_nothing = 0x0400;

/// Bytes of a whole message (header and body) whose first 4 bytes are `head`.
pub fn size(head: []const u8) usize {
    return 4 + @as(usize, get(u16, head, 2)) * 4;
}

fn header(b: *Buf, major: u8, body: usize) void {
    std.debug.assert(body % 4 == 0);
    b.int(u8, major);
    b.int(u8, 0);
    b.int(u16, @intCast(body / 4));
}

/// XIM_CONNECT: little-endian, protocol 1.0, no authentication.
pub fn connect(b: *Buf) void {
    header(b, op.connect, 8);
    b.int(u8, 'l');
    b.zeros(1);
    b.int(u16, 1);
    b.int(u16, 0);
    b.int(u16, 0);
}

/// XIM_OPEN for `locale` (an STR: length byte and the name).
pub fn open(b: *Buf, locale: []const u8) void {
    const n = 1 + locale.len;
    header(b, op.open, n + pad4(n));
    b.int(u8, @intCast(locale.len));
    b.str(locale);
    // `str` padded `locale` alone; the length byte shifts it by one.
    b.len -= pad4(locale.len);
    b.zeros(pad4(n));
}

/// XIM_ENCODING_NEGOTIATION offering COMPOUND_TEXT, the encoding every server has.
pub fn encodingNegotiation(b: *Buf, im: u16) void {
    const name = "COMPOUND_TEXT";
    const n = 1 + name.len;
    header(b, op.encoding_negotiation, 4 + n + pad4(n) + 4);
    b.int(u16, im);
    b.int(u16, @intCast(n));
    b.int(u8, @intCast(name.len));
    @memcpy(b.bytes[b.len..][0..name.len], name);
    b.len += name.len;
    b.zeros(pad4(n));
    b.int(u16, 0);
    b.zeros(2);
}

/// IC attribute ids the server gave in XIM_OPEN_REPLY; `missing` where it has none.
pub const Attrs = struct {
    input_style: u16 = missing,
    client_window: u16 = missing,
    focus_window: u16 = missing,
    preedit_attributes: u16 = missing,
    spot_location: u16 = missing,

    pub const missing = 0xffff;

    /// Whether over-the-spot input can be asked for.
    pub fn complete(a: Attrs) bool {
        inline for (@typeInfo(Attrs).@"struct".field_names) |f| {
            if (@field(a, f) == missing) return false;
        }
        return true;
    }
};

/// The input method id and the IC attribute ids from an XIM_OPEN_REPLY message.
pub fn openReply(msg: []const u8) struct { im: u16, attrs: Attrs } {
    const im = get(u16, msg, 4);
    const n_im = get(u16, msg, 6);
    var at: usize = 8 + n_im;
    if (at + 4 > msg.len) return .{ .im = im, .attrs = .{} };
    const end = @min(at + 4 + get(u16, msg, at), msg.len);
    at += 4;
    var a: Attrs = .{};
    // XICATTR: id, type, name length, name, padding to 4 (counting the length field).
    while (at + 6 <= end) {
        const id = get(u16, msg, at);
        const n = get(u16, msg, at + 4);
        if (at + 6 + n > end) break;
        const name = msg[at + 6 ..][0..n];
        const names = .{ .{ "inputStyle", "input_style" }, .{ "clientWindow", "client_window" }, .{ "focusWindow", "focus_window" }, .{ "preeditAttributes", "preedit_attributes" }, .{ "spotLocation", "spot_location" } };
        inline for (names) |p| {
            if (std.mem.eql(u8, name, p[0])) @field(a, p[1]) = id;
        }
        at += 6 + n + pad4(2 + n);
    }
    return .{ .im = im, .attrs = a };
}

pub const create_ic_size = 4 + 4 + 8 * 3 + 4 + 8;

/// XIM_CREATE_IC for over-the-spot input in `window`, with the spot at (x, y) in its pixels.
pub fn createIc(b: *Buf, im: u16, a: Attrs, window: u32, x: i16, y: i16) void {
    header(b, op.create_ic, create_ic_size - 4);
    b.int(u16, im);
    b.int(u16, create_ic_size - 8);
    for ([_][2]u32{ .{ a.input_style, style_preedit_position | style_status_nothing }, .{ a.client_window, window }, .{ a.focus_window, window } }) |kv| {
        b.int(u16, @intCast(kv[0]));
        b.int(u16, 4);
        b.int(u32, kv[1]);
    }
    spot(b, a, x, y);
}

/// preeditAttributes, a nested list holding spotLocation.
fn spot(b: *Buf, a: Attrs, x: i16, y: i16) void {
    b.int(u16, a.preedit_attributes);
    b.int(u16, 8);
    b.int(u16, a.spot_location);
    b.int(u16, 4);
    b.int(i16, x);
    b.int(i16, y);
}

pub const set_spot_size = 8 + 4 + 8 + 4;

/// XIM_SET_IC_VALUES moving the spot to (x, y).
pub fn setSpot(b: *Buf, im: u16, ic: u16, a: Attrs, x: i16, y: i16) void {
    header(b, op.set_ic_values, set_spot_size - 4);
    b.int(u16, im);
    b.int(u16, ic);
    b.int(u16, 12);
    b.zeros(2);
    spot(b, a, x, y);
}

pub const ic_size = 8;

/// A message whose body is the input method and context ids: XIM_SET_IC_FOCUS,
/// XIM_UNSET_IC_FOCUS, XIM_SYNC_REPLY.
pub fn onIc(b: *Buf, major: u8, im: u16, ic: u16) void {
    header(b, major, 4);
    b.int(u16, im);
    b.int(u16, ic);
}

pub const forward_event_size = 4 + 8 + 32;

/// XIM_FORWARD_EVENT with the X event `ev` (32 bytes) and the top 16 bits of its serial.
pub fn forwardEvent(b: *Buf, im: u16, ic: u16, flag: u16, ev: []const u8) void {
    header(b, op.forward_event, forward_event_size - 4);
    b.int(u16, im);
    b.int(u16, ic);
    b.int(u16, flag);
    b.int(u16, 0);
    @memcpy(b.bytes[b.len..][0..32], ev[0..32]);
    b.len += 32;
}

/// What an XIM_COMMIT carries: the flags, the committed COMPOUND_TEXT and a keysym, either of
/// which may be absent.
pub const Commit = struct {
    flag: u16,
    text: []const u8 = "",
    keysym: u32 = 0,

    pub const synchronous = 1;
    const chars = 2;
    const keysym_flag = 4;

    pub fn parse(msg: []const u8) Commit {
        var c: Commit = .{ .flag = get(u16, msg, 8) };
        var at: usize = 10;
        if (c.flag & keysym_flag != 0) {
            if (at + 6 > msg.len) return c;
            c.keysym = get(u32, msg, at + 2);
            at += 6;
        }
        if (c.flag & chars != 0 and at + 2 <= msg.len) {
            const n = get(u16, msg, at);
            c.text = msg[at + 2 .. @min(at + 2 + n, msg.len)];
        }
        return c;
    }
};

/// COMPOUND_TEXT to UTF-8 in `out`, returning the length. Decodes ASCII and Latin-1 (the
/// defaults of GL and GR) and UTF-8 segments (ESC % G ... ESC % @), which servers built on
/// xcb-imdkit (fcitx5) send for everything else; text in other designated character sets (the
/// legacy CJK sets Xlib picks) is dropped, since decoding it needs their tables.
pub fn compoundToUtf8(ct: []const u8, out: []u8) usize {
    const Set = enum { latin1, utf8, other };
    var gl: Set = .latin1;
    var gr: Set = .latin1;
    var n: usize = 0;
    var i: usize = 0;
    while (i < ct.len) {
        const ch = ct[i];
        if (ch == 0x1b) {
            const rest = ct[i + 1 ..];
            if (std.mem.startsWith(u8, rest, "%G")) {
                gl = .utf8;
                gr = .utf8;
                i += 3;
            } else if (std.mem.startsWith(u8, rest, "%@")) {
                gl = .latin1;
                gr = .latin1;
                i += 3;
            } else {
                // ESC, intermediates (0x20..0x2f), final byte. "(B" is ASCII to GL, "-A"
                // Latin-1 to GR; anything else is a set this decoder does not have.
                var j: usize = i + 1;
                while (j < ct.len and ct[j] >= 0x20 and ct[j] <= 0x2f) j += 1;
                const seq = ct[i + 1 .. @min(j + 1, ct.len)];
                // The last intermediate says where: '(' (and "$(") is G0, which is GL.
                const to_gl = seq.len >= 2 and seq[seq.len - 2] == '(';
                const set: Set = if (std.mem.eql(u8, seq, "(B") or std.mem.eql(u8, seq, "-A")) .latin1 else .other;
                if (to_gl) gl = set else gr = set;
                i = j + 1;
            }
            continue;
        }
        const set = if (ch < 0x80) gl else gr;
        i += 1;
        switch (set) {
            .utf8 => {
                if (n < out.len) out[n] = ch;
                n += @intFromBool(n < out.len);
            },
            .latin1 => {
                var buf: [2]u8 = undefined;
                const len = std.unicode.utf8Encode(ch, &buf) catch unreachable;
                if (n + len > out.len) continue;
                @memcpy(out[n..][0..len], buf[0..len]);
                n += len;
            },
            .other => {},
        }
    }
    return n;
}

const testing = std.testing;

test "messages: headers count the body in 4-byte units" {
    var bytes: [128]u8 = undefined;
    inline for (.{
        .{ connect, .{} },
        .{ open, .{"en_US"} },
        .{ open, .{"ja_JP.UTF-8"} },
        .{ encodingNegotiation, .{1} },
        .{ createIc, .{ 1, Attrs{ .input_style = 0, .client_window = 1, .focus_window = 2, .preedit_attributes = 3, .spot_location = 4 }, 5, 6, 7 } },
        .{ setSpot, .{ 1, 2, Attrs{}, 3, 4 } },
        .{ onIc, .{ op.set_ic_focus, 1, 2 } },
        .{ forwardEvent, .{ 1, 2, 0, &@as([32]u8, @splat(0)) } },
    }) |c| {
        var b: Buf = .{ .bytes = &bytes };
        @call(.auto, c[0], .{&b} ++ c[1]);
        try testing.expectEqual(b.len, size(&bytes));
        try testing.expectEqual(@as(usize, 0), b.len % 4);
    }
    var b: Buf = .{ .bytes = &bytes };
    open(&b, "en_US");
    try testing.expectEqualSlices(u8, &.{ op.open, 0, 2, 0, 5, 'e', 'n', '_', 'U', 'S', 0, 0 }, bytes[0..12]);
}

test "openReply: IC attribute ids by name" {
    var bytes: [256]u8 = undefined;
    var b: Buf = .{ .bytes = &bytes };
    b.int(u8, op.open_reply);
    b.zeros(3);
    b.int(u16, 7); // im
    b.int(u16, 24); // IM attributes: one, 6 + 15 + 3 bytes
    b.int(u16, 0);
    b.int(u16, 10);
    b.int(u16, 15);
    @memcpy(b.bytes[b.len..][0..15], "queryInputStyle");
    b.len += 15;
    b.zeros(pad4(2 + 15));
    const ic_at = b.len;
    b.int(u16, 0);
    b.zeros(2);
    for ([_][]const u8{ "inputStyle", "clientWindow", "focusWindow", "preeditAttributes", "spotLocation", "separatorofNestedList" }, 0..) |name, id| {
        b.int(u16, @intCast(id + 10));
        b.int(u16, 3);
        b.int(u16, @intCast(name.len));
        @memcpy(b.bytes[b.len..][0..name.len], name);
        b.len += name.len;
        b.zeros(pad4(2 + name.len));
    }
    std.mem.writeInt(u16, bytes[ic_at..][0..2], @intCast(b.len - ic_at - 4), .little);
    const r = openReply(bytes[0..b.len]);
    try testing.expectEqual(@as(u16, 7), r.im);
    try testing.expectEqual(Attrs{ .input_style = 10, .client_window = 11, .focus_window = 12, .preedit_attributes = 13, .spot_location = 14 }, r.attrs);
    try testing.expect(r.attrs.complete());
    // A truncated reply gives what it has, without reading past it.
    try testing.expect(!openReply(bytes[0 .. b.len - 40]).attrs.complete());
}

test "Commit.parse: chars, keysym, both" {
    const chars = [_]u8{ op.commit, 0, 3, 0, 1, 0, 1, 0, 3, 0, 3, 0, 'a', 'b', 'c', 0 };
    const c = Commit.parse(&chars);
    try testing.expectEqualStrings("abc", c.text);
    try testing.expectEqual(@as(u16, 3), c.flag);
    const sym = [_]u8{ op.commit, 0, 3, 0, 1, 0, 1, 0, 4, 0, 0, 0, 0x61, 0, 0, 0 };
    try testing.expectEqual(@as(u32, 'a'), Commit.parse(&sym).keysym);
    const both = [_]u8{ op.commit, 0, 4, 0, 1, 0, 1, 0, 6, 0, 0, 0, 0x61, 0, 0, 0, 1, 0, 'x', 0 };
    try testing.expectEqualStrings("x", Commit.parse(&both).text);
    try testing.expectEqual(@as(u32, 'a'), Commit.parse(&both).keysym);
}

test "compoundToUtf8: Latin-1, UTF-8 segments, unknown sets dropped" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("abc", out[0..compoundToUtf8("abc", &out)]);
    try testing.expectEqualStrings("caf\xc3\xa9", out[0..compoundToUtf8("caf\xe9", &out)]);
    try testing.expectEqualStrings("a\xe3\x81\x82b", out[0..compoundToUtf8("a\x1b%G\xe3\x81\x82\x1b%@b", &out)]);
    // JIS X 0208 ("ESC $ ) B" to GR) is not decoded; ASCII after "ESC ( B" is.
    try testing.expectEqualStrings("xy", out[0..compoundToUtf8("x\x1b$)B\xa4\xa2\x1b-Ay", &out)]);
    try testing.expectEqualStrings("z", out[0..compoundToUtf8("\x1b$(B\x24\x22\x1b(Bz", &out)]);
    // Never past `out`.
    try testing.expectEqual(@as(usize, 2), compoundToUtf8("\xe9\xe9", out[0..3]));
}
