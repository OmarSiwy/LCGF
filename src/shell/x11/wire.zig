//! The X11 wire protocol, as far as the X11 shell (x11.zig) needs it: the connection setup,
//! the requests it sends, and where the fields of the replies and events it reads are. Plain
//! byte encoding and decoding, no socket and no OS, so it builds and is tested on every target;
//! x11.zig does the I/O. Byte order is always little-endian: the client says so in the setup
//! ('l') and the server converts.
//!
//! Layouts are from the X Window System Protocol, X Version 11 (xcb.freedesktop.org, "X
//! protocol"), and the XTEST extension protocol for the test's fake input.

const std = @import("std");

/// Little-endian reads at a byte offset of a message.
pub fn get(comptime T: type, msg: []const u8, at: usize) T {
    return std.mem.readInt(T, msg[at..][0..@sizeOf(T)], .little);
}

/// Bytes to the next multiple of 4.
pub fn pad4(n: usize) usize {
    return (4 - n % 4) % 4;
}

/// A request being written into the connection's output buffer. The caller makes sure `size`
/// bytes fit before writing a request (`Connection.req`).
pub const Buf = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn int(b: *Buf, comptime T: type, v: T) void {
        std.mem.writeInt(T, b.bytes[b.len..][0..@sizeOf(T)], v, .little);
        b.len += @sizeOf(T);
    }
    pub fn zeros(b: *Buf, n: usize) void {
        @memset(b.bytes[b.len..][0..n], 0);
        b.len += n;
    }
    /// `s`, then zeros to a multiple of 4.
    pub fn str(b: *Buf, s: []const u8) void {
        @memcpy(b.bytes[b.len..][0..s.len], s);
        b.len += s.len;
        b.zeros(pad4(s.len));
    }
    /// The 4-byte request header: opcode, one byte of data, length in 4-byte units.
    pub fn head(b: *Buf, opcode: u8, data: u8, words: usize) void {
        b.int(u8, opcode);
        b.int(u8, data);
        b.int(u16, @intCast(words));
    }
};

// ---------------------------------------------------------------------------------------------
// Display name and authorization

/// `DISPLAY` parsed: only local displays (`:N` or `:N.S`, optionally `unix:N`), reached through
/// the socket `/tmp/.X11-unix/XN`. TCP displays (`host:N`) are not supported.
pub const Display = struct {
    number: u32,
    screen: u32 = 0,

    pub fn parse(name: []const u8) error{UnsupportedDisplay}!Display {
        const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return error.UnsupportedDisplay;
        const host = name[0..colon];
        if (!(host.len == 0 or std.mem.eql(u8, host, "unix"))) return error.UnsupportedDisplay;
        const rest = name[colon + 1 ..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
        const number = std.fmt.parseInt(u32, rest[0..dot], 10) catch return error.UnsupportedDisplay;
        const screen = if (dot == rest.len) 0 else std.fmt.parseInt(u32, rest[dot + 1 ..], 10) catch return error.UnsupportedDisplay;
        return .{ .number = number, .screen = screen };
    }

    /// The socket path into `buf`.
    pub fn path(d: Display, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "/tmp/.X11-unix/X{d}", .{d.number}) catch unreachable;
    }
};

/// An authorization to send in the setup: a protocol name and its data.
pub const Auth = struct {
    name: []const u8 = "",
    data: []const u8 = "",
};

/// The MIT-MAGIC-COOKIE-1 for display `number` in the bytes of an Xauthority file, or none.
/// Entries are family (u16), address, display number (as text), name, data; every field after
/// the family is a big-endian u16 length and its bytes. Local (256) and wildcard (65535)
/// families match any host; this shell only connects locally.
pub fn cookie(file: []const u8, number: u32) Auth {
    var at: usize = 0;
    var fields: [4][]const u8 = undefined;
    while (at + 2 <= file.len) {
        const family = std.mem.readInt(u16, file[at..][0..2], .big);
        at += 2;
        for (&fields) |*f| {
            if (at + 2 > file.len) return .{};
            const n = std.mem.readInt(u16, file[at..][0..2], .big);
            at += 2;
            if (at + n > file.len) return .{};
            f.* = file[at..][0..n];
            at += n;
        }
        const local = family == 256 or family == 65535;
        var digits: [10]u8 = undefined;
        const want = std.fmt.bufPrint(&digits, "{d}", .{number}) catch unreachable;
        if (local and std.mem.eql(u8, fields[1], want) and std.mem.eql(u8, fields[2], "MIT-MAGIC-COOKIE-1"))
            return .{ .name = fields[2], .data = fields[3] };
    }
    return .{};
}

// ---------------------------------------------------------------------------------------------
// Connection setup

/// The setup request: byte order, protocol 11.0, and the authorization.
pub fn setup(b: *Buf, auth: Auth) void {
    b.int(u8, 'l');
    b.zeros(1);
    b.int(u16, 11);
    b.int(u16, 0);
    b.int(u16, @intCast(auth.name.len));
    b.int(u16, @intCast(auth.data.len));
    b.zeros(2);
    b.str(auth.name);
    b.str(auth.data);
}

pub fn setupSize(auth: Auth) usize {
    return 12 + auth.name.len + pad4(auth.name.len) + auth.data.len + pad4(auth.data.len);
}

/// What the shell keeps from a successful setup reply.
pub const Setup = struct {
    id_base: u32,
    id_mask: u32,
    /// Longest request in 4-byte units (without BIG-REQUESTS).
    max_request: u16,
    min_keycode: u8,
    max_keycode: u8,
    root: u32,
    root_visual: u32,
    root_depth: u8,
    /// Root window size in pixels and millimetres, for the DPI fallback.
    width_px: u16,
    height_px: u16,
    width_mm: u16,
    height_mm: u16,

    pub const Error = error{ SetupRefused, SetupTruncated, UnsupportedVisual };

    /// Parses the full reply `r` (8-byte header plus `get(u16, r, 6) * 4` bytes), for `screen`.
    /// Only 24- or 32-bit TrueColor root visuals with 32 bits per pixel and red in bits 16..23
    /// are accepted: those take the software renderer's `bgra8` pixels as they are.
    pub fn parse(r: []const u8, screen: u32) Error!Setup {
        if (r.len < 8 or r[0] != 1) return error.SetupRefused;
        if (r.len < 40) return error.SetupTruncated;
        const vendor_len = get(u16, r, 24);
        const n_screens = r[28];
        const n_formats = r[29];
        var at: usize = 40 + vendor_len + pad4(vendor_len);
        // Pixmap formats: depth, bits per pixel, scanline pad, 5 unused.
        var bpp: [256]u8 = @splat(0);
        for (0..n_formats) |_| {
            if (at + 8 > r.len) return error.SetupTruncated;
            bpp[r[at]] = r[at + 1];
            at += 8;
        }
        if (screen >= n_screens) return error.SetupRefused;
        for (0..n_screens) |s| {
            if (at + 40 > r.len) return error.SetupTruncated;
            const scr = r[at..];
            const out: Setup = .{
                .id_base = get(u32, r, 12),
                .id_mask = get(u32, r, 16),
                .max_request = get(u16, r, 26),
                .min_keycode = r[34],
                .max_keycode = r[35],
                .root = get(u32, scr, 0),
                .width_px = get(u16, scr, 20),
                .height_px = get(u16, scr, 22),
                .width_mm = get(u16, scr, 24),
                .height_mm = get(u16, scr, 26),
                .root_visual = get(u32, scr, 32),
                .root_depth = scr[38],
            };
            const n_depths = scr[39];
            at += 40;
            var red: u32 = 0;
            for (0..n_depths) |_| {
                if (at + 8 > r.len) return error.SetupTruncated;
                const n_visuals = get(u16, r, at + 2);
                at += 8;
                for (0..n_visuals) |_| {
                    if (at + 24 > r.len) return error.SetupTruncated;
                    if (get(u32, r, at) == out.root_visual and r[at + 4] == 4) red = get(u32, r, at + 8);
                    at += 24;
                }
            }
            if (s != screen) continue;
            if (red != 0x00ff_0000 or bpp[out.root_depth] != 32) return error.UnsupportedVisual;
            return out;
        }
        unreachable;
    }
};

// ---------------------------------------------------------------------------------------------
// Scale

/// `Xft.dpi` from the resource database string (the root's RESOURCE_MANAGER property), the DPI
/// desktops set for scaling; null when it has none.
pub fn resourceDpi(resources: []const u8) ?f32 {
    var lines = std.mem.splitScalar(u8, resources, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t"), "Xft.dpi")) continue;
        const dpi = std.fmt.parseFloat(f32, std.mem.trim(u8, line[colon + 1 ..], " \t\r")) catch return null;
        return if (dpi > 0) dpi else null;
    }
    return null;
}

/// Physical pixels per logical pixel. `Xft.dpi` is the user's choice and is taken as it is
/// (96 is 1). Without it, the screen's size in pixels and millimetres (from the setup, then from
/// RandR's ScreenChangeNotify) gives the DPI, rounded to a quarter step and never below 1, since
/// many servers report a made-up size close to 96 DPI.
pub fn scale(xft_dpi: ?f32, width_px: u16, width_mm: u16) f32 {
    if (xft_dpi) |d| return d / 96;
    if (width_mm == 0) return 1;
    const dpi = @as(f32, @floatFromInt(width_px)) * 25.4 / @as(f32, @floatFromInt(width_mm));
    return @max(1, @round(dpi / 96 * 4) / 4);
}

// ---------------------------------------------------------------------------------------------
// Messages from the server

/// Every message is 32 bytes, except replies and generic events, which say how many 4-byte
/// words follow.
pub fn messageSize(head: *const [32]u8) usize {
    const extra: usize = switch (head[0] & 0x7f) {
        reply, generic_event => get(u32, head, 4),
        else => 0,
    };
    return 32 + extra * 4;
}

pub const err = 0;
pub const reply = 1;
pub const key_press = 2;
pub const key_release = 3;
pub const button_press = 4;
pub const button_release = 5;
pub const motion_notify = 6;
pub const enter_notify = 7;
pub const leave_notify = 8;
pub const focus_in = 9;
pub const focus_out = 10;
pub const expose = 12;
pub const destroy_notify = 17;
pub const configure_notify = 22;
pub const property_notify = 28;
pub const selection_clear = 29;
pub const selection_request = 30;
pub const selection_notify = 31;
pub const client_message = 33;
pub const mapping_notify = 34;
pub const generic_event = 35;

/// The window an event is about, or 0 for events that name none (errors, replies, mapping).
pub fn eventWindow(msg: []const u8) u32 {
    return switch (msg[0] & 0x7f) {
        key_press, key_release, button_press, button_release, motion_notify, enter_notify, leave_notify => get(u32, msg, 12),
        focus_in, focus_out, expose, property_notify, client_message => get(u32, msg, 4),
        destroy_notify, configure_notify, selection_clear => get(u32, msg, 8),
        selection_request => get(u32, msg, 8),
        selection_notify => get(u32, msg, 8),
        else => 0,
    };
}

/// Pointer and key events: position in the event window, and the modifier and button state.
pub const Pointer = struct {
    x: i16,
    y: i16,
    state: u16,

    pub fn of(msg: []const u8) Pointer {
        return .{ .x = get(i16, msg, 24), .y = get(i16, msg, 26), .state = get(u16, msg, 28) };
    }
};

/// Modifier and button bits of an event's `state`.
pub const State = struct {
    pub const shift = 1;
    pub const lock = 2;
    pub const control = 4;
    /// Mod1: Alt on every common keymap.
    pub const mod1 = 8;
    /// Mod2: Num Lock on every common keymap.
    pub const mod2 = 16;
    /// Mod4: Super on every common keymap.
    pub const mod4 = 64;
    pub const button1 = 0x100;
    pub const button2 = 0x200;
    pub const button3 = 0x400;
};

// ---------------------------------------------------------------------------------------------
// Requests

pub const op = struct {
    pub const create_window = 1;
    pub const change_window_attributes = 2;
    pub const destroy_window = 4;
    pub const map_window = 8;
    pub const configure_window = 12;
    pub const intern_atom = 16;
    pub const change_property = 18;
    pub const delete_property = 19;
    pub const get_property = 20;
    pub const set_selection_owner = 22;
    pub const get_selection_owner = 23;
    pub const convert_selection = 24;
    pub const send_event = 25;
    pub const set_input_focus = 42;
    pub const get_input_focus = 43;
    pub const translate_coordinates = 40;
    pub const open_font = 45;
    pub const create_pixmap = 53;
    pub const free_pixmap = 54;
    pub const create_gc = 55;
    pub const free_gc = 60;
    pub const copy_area = 62;
    pub const put_image = 72;
    pub const get_image = 73;
    pub const create_cursor = 93;
    pub const create_glyph_cursor = 94;
    pub const query_extension = 98;
    pub const get_keyboard_mapping = 101;
};

/// Window attribute bits, in the order their values follow (`createWindow`).
pub const Attr = struct {
    pub const back_pixmap = 0x1;
    pub const event_mask = 0x800;
    pub const cursor = 0x4000;
};

/// Event mask bits.
pub const Mask = struct {
    pub const key_press = 0x1;
    pub const key_release = 0x2;
    pub const button_press = 0x4;
    pub const button_release = 0x8;
    pub const enter_window = 0x10;
    pub const leave_window = 0x20;
    pub const pointer_motion = 0x40;
    pub const exposure = 0x8000;
    pub const structure_notify = 0x20000;
    pub const focus_change = 0x200000;
    pub const property_change = 0x400000;
};

pub const create_window_size = 40;

/// An InputOutput window of the parent's depth and visual, with no background (the shell
/// draws every pixel, so the server clearing it first would only flicker) and `events`.
pub fn createWindow(b: *Buf, id: u32, parent: u32, w: u16, h: u16, events: u32) void {
    b.head(op.create_window, 0, create_window_size / 4);
    b.int(u32, id);
    b.int(u32, parent);
    b.int(i16, 0);
    b.int(i16, 0);
    b.int(u16, w);
    b.int(u16, h);
    b.int(u16, 0); // border
    b.int(u16, 1); // InputOutput
    b.int(u32, 0); // CopyFromParent visual
    b.int(u32, Attr.back_pixmap | Attr.event_mask);
    b.int(u32, 0); // background None
    b.int(u32, events);
}

pub const change_cursor_size = 16;

/// Sets the window's cursor (`Attr.cursor`); 0 is the parent's.
pub fn changeCursor(b: *Buf, window: u32, cursor: u32) void {
    b.head(op.change_window_attributes, 0, change_cursor_size / 4);
    b.int(u32, window);
    b.int(u32, Attr.cursor);
    b.int(u32, cursor);
}

pub const move_window_size = 20;

/// ConfigureWindow moving `window` to (x, y) in its parent.
pub fn moveWindow(b: *Buf, window: u32, x: i16, y: i16) void {
    b.head(op.configure_window, 0, move_window_size / 4);
    b.int(u32, window);
    b.int(u16, 0x3); // x, y
    b.zeros(2);
    b.int(i32, x);
    b.int(i32, y);
}

pub const window_size = 8;

/// A request whose only field is a window: MapWindow, DestroyWindow.
pub fn onWindow(b: *Buf, opcode: u8, window: u32) void {
    b.head(opcode, 0, window_size / 4);
    b.int(u32, window);
}

pub fn internAtomSize(name: []const u8) usize {
    return 8 + name.len + pad4(name.len);
}

/// Asks for the atom of `name`, creating it. The reply has it at byte 8.
pub fn internAtom(b: *Buf, name: []const u8) void {
    b.head(op.intern_atom, 0, internAtomSize(name) / 4);
    b.int(u16, @intCast(name.len));
    b.zeros(2);
    b.str(name);
}

pub fn changePropertySize(data_len: usize) usize {
    return 24 + data_len + pad4(data_len);
}

/// Replaces `property` of `window` with `data`, items of `format` bits (8, 16 or 32).
pub fn changeProperty(b: *Buf, window: u32, property: u32, kind: u32, format: u8, data: []const u8) void {
    changePropertyHead(b, window, property, kind, format, data.len);
    b.str(data);
}

/// `changeProperty` in Append mode: `data` goes after what the property holds.
pub fn appendProperty(b: *Buf, window: u32, property: u32, kind: u32, format: u8, data: []const u8) void {
    const start = b.len;
    changeProperty(b, window, property, kind, format, data);
    b.bytes[start + 1] = 2;
}

pub const change_property_head = 24;

/// ChangeProperty without its data, for data too large for the output buffer: the caller sends
/// the `len` bytes and the padding to 4 right after.
pub fn changePropertyHead(b: *Buf, window: u32, property: u32, kind: u32, format: u8, len: usize) void {
    b.head(op.change_property, 0, changePropertySize(len) / 4);
    b.int(u32, window);
    b.int(u32, property);
    b.int(u32, kind);
    b.int(u8, format);
    b.zeros(3);
    b.int(u32, @intCast(len / (format / 8)));
}

pub const set_selection_owner_size = 16;

pub fn setSelectionOwner(b: *Buf, owner: u32, selection: u32) void {
    b.head(op.set_selection_owner, 0, set_selection_owner_size / 4);
    b.int(u32, owner);
    b.int(u32, selection);
    b.int(u32, 0); // CurrentTime
}

pub const convert_selection_size = 24;

/// Asks the owner of `selection` to put it, as `target`, in `property` of `requestor`; a
/// SelectionNotify says when it has.
pub fn convertSelection(b: *Buf, requestor: u32, selection: u32, target: u32, property: u32) void {
    b.head(op.convert_selection, 0, convert_selection_size / 4);
    b.int(u32, requestor);
    b.int(u32, selection);
    b.int(u32, target);
    b.int(u32, property);
    b.int(u32, 0);
}

/// The SelectionNotify an owner sends the requestor; `property` 0 refuses.
pub fn selectionNotify(requestor: u32, selection: u32, target: u32, property: u32) [32]u8 {
    var e: [32]u8 = @splat(0);
    e[0] = selection_notify;
    std.mem.writeInt(u32, e[8..12], requestor, .little);
    std.mem.writeInt(u32, e[12..16], selection, .little);
    std.mem.writeInt(u32, e[16..20], target, .little);
    std.mem.writeInt(u32, e[20..24], property, .little);
    return e;
}

pub const get_property_size = 24;

/// Reads up to `words` 4-byte words of `property` (any type). The reply: format at byte 1, type
/// at 8, bytes left at 12, item count at 16, the value from byte 32.
pub fn getProperty(b: *Buf, window: u32, property: u32, delete: bool, words: u32) void {
    b.head(op.get_property, @intFromBool(delete), get_property_size / 4);
    b.int(u32, window);
    b.int(u32, property);
    b.int(u32, 0); // AnyPropertyType
    b.int(u32, 0);
    b.int(u32, words);
}

pub const change_event_mask_size = 16;

/// Replaces this client's event mask on `window` (used on the root, for PropertyNotify).
pub fn changeEventMask(b: *Buf, window: u32, mask: u32) void {
    b.head(op.change_window_attributes, 0, change_event_mask_size / 4);
    b.int(u32, window);
    b.int(u32, Attr.event_mask);
    b.int(u32, mask);
}

pub const delete_property_size = 12;

pub fn deleteProperty(b: *Buf, window: u32, property: u32) void {
    b.head(op.delete_property, 0, delete_property_size / 4);
    b.int(u32, window);
    b.int(u32, property);
}

pub const randr_select_input_size = 12;

/// RandR SelectInput (minor 4): ScreenChangeNotify events about `window`'s screen, whose code
/// is the extension's first event.
pub fn randrSelectInput(b: *Buf, randr: u8, window: u32) void {
    b.head(randr, 4, randr_select_input_size / 4);
    b.int(u32, window);
    b.int(u16, 1); // ScreenChangeNotify
    b.zeros(2);
}

pub const randr_set_screen_size_size = 20;

/// RandR SetScreenSize (minor 7): the screen's size in pixels and millimetres.
pub fn randrSetScreenSize(b: *Buf, randr: u8, window: u32, w: u16, h: u16, mm_w: u32, mm_h: u32) void {
    b.head(randr, 7, randr_set_screen_size_size / 4);
    b.int(u32, window);
    b.int(u16, w);
    b.int(u16, h);
    b.int(u32, mm_w);
    b.int(u32, mm_h);
}

pub fn openFontSize(name: []const u8) usize {
    return 12 + name.len + pad4(name.len);
}

pub fn openFont(b: *Buf, id: u32, name: []const u8) void {
    b.head(op.open_font, 0, openFontSize(name) / 4);
    b.int(u32, id);
    b.int(u16, @intCast(name.len));
    b.zeros(2);
    b.str(name);
}

pub const create_cursor_size = 32;

/// Core CreateCursor: a depth-one bitmap and mask, black on white, hotspot at (0,0).
/// A cleared mask hides every pixel and works without the XFIXES extension.
pub fn createCursor(b: *Buf, id: u32, source: u32, mask: u32) void {
    b.head(op.create_cursor, 0, create_cursor_size / 4);
    b.int(u32, id);
    b.int(u32, source);
    b.int(u32, mask);
    b.zeros(6);
    for (0..3) |_| b.int(u16, 0xffff);
    b.zeros(4);
}

pub const clear_bitmap_size = 28;

/// One zero bit, padded to the server's 32-bit scanline unit. The source and mask share it.
pub fn clearBitmap(b: *Buf, bitmap: u32, gc: u32) void {
    putImage(b, bitmap, gc, 1, 1, 0, 0, 1);
    b.zeros(4);
}

pub const create_glyph_cursor_size = 32;

/// A cursor from glyph `glyph` of the core "cursor" font, its mask the next glyph, black on
/// white.
pub fn createGlyphCursor(b: *Buf, id: u32, font: u32, glyph: u16) void {
    b.head(op.create_glyph_cursor, 0, create_glyph_cursor_size / 4);
    b.int(u32, id);
    b.int(u32, font);
    b.int(u32, font);
    b.int(u16, glyph);
    b.int(u16, glyph + 1);
    b.zeros(6); // foreground black
    for (0..3) |_| b.int(u16, 0xffff);
}

pub const xfixes_query_version_size = 12;

/// XFIXES QueryVersion 4.0 (minor 0), required before other XFIXES requests; has a reply.
pub fn xfixesQueryVersion(b: *Buf, xfixes: u8) void {
    b.head(xfixes, 0, xfixes_query_version_size / 4);
    b.int(u32, 4);
    b.int(u32, 0);
}

pub const xfixes_get_cursor_image_size = 4;

/// XFIXES GetCursorImage (minor 4): the cursor shown now. The reply: width at 12, height at 14,
/// hot spot at 16 and 18, serial at 20, ARGB pixels from 32.
pub fn xfixesGetCursorImage(b: *Buf, xfixes: u8) void {
    b.head(xfixes, 4, 1);
}

pub const get_selection_owner_size = 8;

/// The owner window of `selection` is at byte 8 of the reply (0: none).
pub fn getSelectionOwner(b: *Buf, selection: u32) void {
    b.head(op.get_selection_owner, 0, get_selection_owner_size / 4);
    b.int(u32, selection);
}

/// A ClientMessage event of `format` 8 (20 bytes of `data`, zero-padded) or 32 (five u32).
pub fn clientMessage(window: u32, kind: u32, format: u8, data: []const u8) [32]u8 {
    var e: [32]u8 = @splat(0);
    e[0] = client_message;
    e[1] = format;
    std.mem.writeInt(u32, e[4..8], window, .little);
    std.mem.writeInt(u32, e[8..12], kind, .little);
    @memcpy(e[12..][0..data.len], data);
    return e;
}

pub const translate_coordinates_size = 16;

/// Where (x, y) of `src` is in `dst`: the reply has it at bytes 12 and 14.
pub fn translateCoordinates(b: *Buf, src: u32, dst: u32, x: i16, y: i16) void {
    b.head(op.translate_coordinates, 0, translate_coordinates_size / 4);
    b.int(u32, src);
    b.int(u32, dst);
    b.int(i16, x);
    b.int(i16, y);
}

/// The local paths of a text/uri-list (RFC 2483): one URI per line, `#` lines are comments,
/// only `file:` URIs on this host (`file:///p`, `file://localhost/p`, `file:/p`) are kept, and
/// %XX escapes are decoded. Paths go into `names` back to back, the end of each into `ends`;
/// returns how many, stopping where either runs out.
pub fn uriListPaths(list: []const u8, names: []u8, ends: []u32) usize {
    var n: usize = 0;
    var at: usize = 0;
    var lines = std.mem.tokenizeAny(u8, list, "\r\n");
    while (lines.next()) |line| {
        if (line[0] == '#' or n == ends.len) continue;
        var rest = line;
        if (!std.ascii.startsWithIgnoreCase(rest, "file:")) continue;
        rest = rest[5..];
        if (std.mem.startsWith(u8, rest, "//")) {
            rest = rest[2..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
            const host = rest[0..slash];
            if (!(host.len == 0 or std.mem.eql(u8, host, "localhost"))) continue;
            rest = rest[slash..];
        }
        const start = at;
        var i: usize = 0;
        while (i < rest.len and at < names.len) : (at += 1) {
            const escaped = rest[i] == '%' and i + 2 < rest.len and std.ascii.isHex(rest[i + 1]) and std.ascii.isHex(rest[i + 2]);
            const hex = if (escaped) std.fmt.parseInt(u8, rest[i + 1 ..][0..2], 16) catch unreachable else null;
            names[at] = hex orelse rest[i];
            i += if (hex != null) 3 else 1;
        }
        if (i < rest.len) {
            at = start; // did not fit
            break;
        }
        ends[n] = @intCast(at);
        n += 1;
    }
    return n;
}

pub const send_event_size = 44;

/// Sends the 32-byte `event` to `window` (to its owner when `mask` is 0).
pub fn sendEvent(b: *Buf, window: u32, mask: u32, event: *const [32]u8) void {
    b.head(op.send_event, 0, send_event_size / 4);
    b.int(u32, window);
    b.int(u32, mask);
    @memcpy(b.bytes[b.len..][0..32], event);
    b.len += 32;
}

pub const set_input_focus_size = 12;

/// Gives `window` the keyboard focus (revert to the root; CurrentTime).
pub fn setInputFocus(b: *Buf, window: u32) void {
    b.head(op.set_input_focus, 1, set_input_focus_size / 4);
    b.int(u32, window);
    b.int(u32, 0);
}

pub const get_input_focus_size = 4;

/// Has a reply and no effect: a round trip, after which the server has handled every earlier
/// request.
pub fn getInputFocus(b: *Buf) void {
    b.head(op.get_input_focus, 0, 1);
}

pub const create_pixmap_size = 16;

pub fn createPixmap(b: *Buf, id: u32, drawable: u32, width: u16, height: u16, depth: u8) void {
    b.head(op.create_pixmap, depth, create_pixmap_size / 4);
    b.int(u32, id);
    b.int(u32, drawable);
    b.int(u16, width);
    b.int(u16, height);
}

pub const copy_area_size = 28;

/// Copies the complete frame from the pixmap to the window, origin to origin.
pub fn copyArea(b: *Buf, src: u32, dst: u32, gc: u32, width: u16, height: u16) void {
    b.head(op.copy_area, 0, copy_area_size / 4);
    b.int(u32, src);
    b.int(u32, dst);
    b.int(u32, gc);
    b.zeros(8);
    b.int(u16, width);
    b.int(u16, height);
}

pub const create_gc_size = 20;

/// A graphics context for PutImage, without GraphicsExpose events.
pub fn createGc(b: *Buf, id: u32, drawable: u32) void {
    b.head(op.create_gc, 0, create_gc_size / 4);
    b.int(u32, id);
    b.int(u32, drawable);
    b.int(u32, 0x10000); // graphics-exposures
    b.int(u32, 0);
}

pub const put_image_head = 24;

/// The header of a ZPixmap PutImage of `w` x `h` pixels of 32 bits at (x, y); the caller sends
/// the `w * h * 4` pixel bytes right after it.
pub fn putImage(b: *Buf, drawable: u32, gc: u32, w: u16, h: u16, x: i16, y: i16, depth: u8) void {
    const bytes = @as(usize, w) * h * 4;
    b.head(op.put_image, 2, (put_image_head + bytes) / 4);
    b.int(u32, drawable);
    b.int(u32, gc);
    b.int(u16, w);
    b.int(u16, h);
    b.int(i16, x);
    b.int(i16, y);
    b.int(u8, 0);
    b.int(u8, depth);
    b.zeros(2);
}

pub const get_image_size = 20;

/// Reads `w` x `h` ZPixmap pixels back; the reply's data starts at byte 32.
pub fn getImage(b: *Buf, drawable: u32, x: i16, y: i16, w: u16, h: u16) void {
    b.head(op.get_image, 2, get_image_size / 4);
    b.int(u32, drawable);
    b.int(i16, x);
    b.int(i16, y);
    b.int(u16, w);
    b.int(u16, h);
    b.int(u32, 0xffff_ffff);
}

pub fn queryExtensionSize(name: []const u8) usize {
    return 8 + name.len + pad4(name.len);
}

/// Whether the server has extension `name`. The reply: present at byte 8, major opcode at 9,
/// first event at 10.
pub fn queryExtension(b: *Buf, name: []const u8) void {
    b.head(op.query_extension, 0, queryExtensionSize(name) / 4);
    b.int(u16, @intCast(name.len));
    b.zeros(2);
    b.str(name);
}

pub const get_keyboard_mapping_size = 8;

/// The keysyms of `count` keycodes from `first`. The reply: keysyms per keycode at byte 1, the
/// keysyms from byte 32.
pub fn getKeyboardMapping(b: *Buf, first: u8, count: u8) void {
    b.head(op.get_keyboard_mapping, 0, get_keyboard_mapping_size / 4);
    b.int(u8, first);
    b.int(u8, count);
    b.zeros(2);
}

pub const xkb_use_extension_size = 8;

/// XKB UseExtension 1.0 (minor 0): required before any other XKB request. The reply says
/// whether it is supported at byte 1.
pub fn xkbUseExtension(b: *Buf, xkb: u8) void {
    b.head(xkb, 0, xkb_use_extension_size / 4);
    b.int(u16, 1);
    b.int(u16, 0);
}

pub const xkb_per_client_flags_size = 28;

/// XKB PerClientFlags (minor 21) turning on DetectableAutoRepeat for the core keyboard: a held
/// key then repeats as presses alone, not as release and press pairs. Has a reply.
pub fn xkbDetectableAutoRepeat(b: *Buf, xkb: u8) void {
    b.head(xkb, 21, xkb_per_client_flags_size / 4);
    b.int(u16, 0x100); // UseCoreKbd
    b.zeros(2);
    b.int(u32, 1); // change: DetectableAutoRepeat
    b.int(u32, 1); // value
    b.int(u32, 0);
    b.int(u32, 0);
    b.int(u32, 0);
}

pub const fake_input_size = 36;

/// XTEST FakeInput (minor opcode 2): the server acts as if the device did it. `kind` is the
/// event code (key_press, button_press, motion_notify, ...), `detail` the key or button; motion
/// moves the pointer to (x, y) in `root`.
pub fn fakeInput(b: *Buf, xtest: u8, kind: u8, detail: u8, root: u32, x: i16, y: i16) void {
    b.head(xtest, 2, fake_input_size / 4);
    b.int(u8, kind);
    b.int(u8, detail);
    b.zeros(2);
    b.int(u32, 0); // CurrentTime
    b.int(u32, root);
    b.zeros(8);
    b.int(i16, x);
    b.int(i16, y);
    b.zeros(8);
}

const testing = std.testing;

test "Display.parse: local displays only" {
    try testing.expectEqual(Display{ .number = 0 }, try Display.parse(":0"));
    try testing.expectEqual(Display{ .number = 12, .screen = 1 }, try Display.parse(":12.1"));
    try testing.expectEqual(Display{ .number = 3 }, try Display.parse("unix:3"));
    try testing.expectError(error.UnsupportedDisplay, Display.parse("host:0"));
    try testing.expectError(error.UnsupportedDisplay, Display.parse("0"));
    try testing.expectError(error.UnsupportedDisplay, Display.parse(":x"));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("/tmp/.X11-unix/X12", (Display{ .number = 12 }).path(&buf));
}

/// Appends one Xauthority entry, as xauth writes it.
fn entry(b: *Buf, family: u16, number: []const u8, name: []const u8, data: []const u8) void {
    std.mem.writeInt(u16, b.bytes[b.len..][0..2], family, .big);
    b.len += 2;
    for ([_][]const u8{ "host", number, name, data }) |f| {
        std.mem.writeInt(u16, b.bytes[b.len..][0..2], @intCast(f.len), .big);
        @memcpy(b.bytes[b.len + 2 ..][0..f.len], f);
        b.len += 2 + f.len;
    }
}

test "cookie: the local entry for the display" {
    var bytes: [256]u8 = undefined;
    var b: Buf = .{ .bytes = &bytes };
    entry(&b, 0, "1", "MIT-MAGIC-COOKIE-1", "inet");
    entry(&b, 256, "0", "MIT-MAGIC-COOKIE-1", "zero");
    entry(&b, 256, "1", "XDM-AUTHORIZATION-1", "nope");
    entry(&b, 256, "1", "MIT-MAGIC-COOKIE-1", "one!");
    const file = bytes[0..b.len];
    try testing.expectEqualStrings("zero", cookie(file, 0).data);
    try testing.expectEqualStrings("one!", cookie(file, 1).data);
    try testing.expectEqualStrings("MIT-MAGIC-COOKIE-1", cookie(file, 1).name);
    try testing.expectEqualStrings("", cookie(file, 2).data);
    // A truncated file gives no cookie rather than reading past its end.
    try testing.expectEqualStrings("", cookie(file[0 .. file.len - 2], 1).data);
}

test "setup: request bytes" {
    var bytes: [64]u8 = undefined;
    var b: Buf = .{ .bytes = &bytes };
    const auth: Auth = .{ .name = "MIT-MAGIC-COOKIE-1", .data = "0123456789abcdef" };
    setup(&b, auth);
    try testing.expectEqual(setupSize(auth), b.len);
    try testing.expectEqual(@as(usize, 12 + 20 + 16), b.len);
    try testing.expectEqualSlices(u8, &.{ 'l', 0, 11, 0, 0, 0, 18, 0, 16, 0, 0, 0 }, bytes[0..12]);
    try testing.expectEqualStrings("MIT-MAGIC-COOKIE-1\x00\x000123456789abcdef", bytes[12..48]);
}

/// A setup reply with one format, one screen, one depth and one visual.
fn fakeSetup(red: u32, bpp: u8) [124]u8 {
    var r: [124]u8 = @splat(0);
    var b: Buf = .{ .bytes = &r };
    b.int(u8, 1);
    b.zeros(1);
    b.int(u16, 11);
    b.int(u16, 0);
    b.int(u16, (124 - 8) / 4);
    b.int(u32, 0); // release
    b.int(u32, 0x0040_0000); // id base
    b.int(u32, 0x001f_ffff); // id mask
    b.int(u32, 0);
    b.int(u16, 4); // vendor length
    b.int(u16, 65535);
    b.int(u8, 1); // screens
    b.int(u8, 1); // formats
    b.zeros(4);
    b.int(u8, 8);
    b.int(u8, 255);
    b.zeros(4);
    b.str("Test");
    b.int(u8, 24);
    b.int(u8, bpp);
    b.int(u8, 32);
    b.zeros(5);
    // Screen at 52.
    b.int(u32, 0x1e9); // root
    b.int(u32, 0x20); // colormap
    b.int(u32, 0xffffff);
    b.int(u32, 0);
    b.int(u32, 0);
    b.int(u16, 1024);
    b.int(u16, 768);
    b.int(u16, 271);
    b.int(u16, 203);
    b.int(u16, 1);
    b.int(u16, 1);
    b.int(u32, 0x21); // root visual
    b.zeros(2);
    b.int(u8, 24);
    b.int(u8, 1);
    // Depth 24 with one visual.
    b.int(u8, 24);
    b.zeros(1);
    b.int(u16, 1);
    b.zeros(4);
    b.int(u32, 0x21);
    b.int(u8, 4); // TrueColor
    b.int(u8, 8);
    b.int(u16, 256);
    b.int(u32, red);
    b.int(u32, 0x00ff00);
    b.int(u32, 0x0000ff);
    b.zeros(4);
    std.debug.assert(b.len == 124);
    return r;
}

test "Setup.parse: the screen's root, visual and sizes" {
    const r = fakeSetup(0xff0000, 32);
    const s = try Setup.parse(&r, 0);
    try testing.expectEqual(@as(u32, 0x1e9), s.root);
    try testing.expectEqual(@as(u32, 0x21), s.root_visual);
    try testing.expectEqual(@as(u8, 24), s.root_depth);
    try testing.expectEqual(@as(u32, 0x0040_0000), s.id_base);
    try testing.expectEqual(@as(u16, 1024), s.width_px);
    try testing.expectEqual(@as(u16, 203), s.height_mm);
    try testing.expectEqual(@as(u8, 8), s.min_keycode);
    try testing.expectError(error.UnsupportedVisual, Setup.parse(&fakeSetup(0x0000ff, 32), 0));
    try testing.expectError(error.UnsupportedVisual, Setup.parse(&fakeSetup(0xff0000, 24), 0));
    try testing.expectError(error.SetupRefused, Setup.parse(&r, 1));
    try testing.expectError(error.SetupTruncated, Setup.parse(r[0..110], 0));
    var refused = r;
    refused[0] = 0;
    try testing.expectError(error.SetupRefused, Setup.parse(&refused, 0));
}

test "requests: lengths match the bytes written" {
    var bytes: [128]u8 = undefined;
    inline for (.{
        .{ create_window_size, createWindow, .{ 1, 2, 3, 4, 5 } },
        .{ change_cursor_size, changeCursor, .{ 1, 2 } },
        .{ internAtomSize("WM_PROTOCOLS"), internAtom, .{"WM_PROTOCOLS"} },
        .{ changePropertySize(5), changeProperty, .{ 1, 2, 3, 8, "title" } },
        .{ get_property_size, getProperty, .{ 1, 2, false, 3 } },
        .{ get_input_focus_size, getInputFocus, .{} },
        .{ create_gc_size, createGc, .{ 1, 2 } },
        .{ create_pixmap_size, createPixmap, .{ 1, 2, 640, 480, 24 } },
        .{ copy_area_size, copyArea, .{ 1, 2, 3, 640, 480 } },
        .{ put_image_head, putImage, .{ 1, 2, 0, 0, 0, 0, 24 } },
        .{ get_image_size, getImage, .{ 1, 0, 0, 1, 1 } },
        .{ queryExtensionSize("XTEST"), queryExtension, .{"XTEST"} },
        .{ fake_input_size, fakeInput, .{ 130, 6, 0, 1, 10, 20 } },
        .{ get_keyboard_mapping_size, getKeyboardMapping, .{ 8, 248 } },
        .{ set_input_focus_size, setInputFocus, .{1} },
        .{ move_window_size, moveWindow, .{ 1, 2, 3 } },
        .{ translate_coordinates_size, translateCoordinates, .{ 1, 2, 3, 4 } },
        .{ set_selection_owner_size, setSelectionOwner, .{ 1, 2 } },
        .{ get_selection_owner_size, getSelectionOwner, .{1} },
        .{ changePropertySize(3), appendProperty, .{ 1, 2, 3, 8, "abc" } },
        .{ convert_selection_size, convertSelection, .{ 1, 2, 3, 4 } },
        .{ change_event_mask_size, changeEventMask, .{ 1, 2 } },
        .{ delete_property_size, deleteProperty, .{ 1, 2 } },
        .{ randr_select_input_size, randrSelectInput, .{ 140, 1 } },
        .{ openFontSize("cursor"), openFont, .{ 1, "cursor" } },
        .{ create_cursor_size, createCursor, .{ 1, 2, 2 } },
        .{ clear_bitmap_size, clearBitmap, .{ 1, 2 } },
        .{ create_glyph_cursor_size, createGlyphCursor, .{ 1, 2, 68 } },
        .{ xfixes_query_version_size, xfixesQueryVersion, .{140} },
        .{ xfixes_get_cursor_image_size, xfixesGetCursorImage, .{140} },
        .{ randr_set_screen_size_size, randrSetScreenSize, .{ 140, 1, 2, 3, 4, 5 } },
        .{ xkb_use_extension_size, xkbUseExtension, .{130} },
        .{ xkb_per_client_flags_size, xkbDetectableAutoRepeat, .{130} },
    }) |c| {
        var b: Buf = .{ .bytes = &bytes };
        @call(.auto, c[1], .{&b} ++ c[2]);
        try testing.expectEqual(@as(usize, c[0]), b.len);
        // Every request's length field counts its 4-byte words (PutImage's includes the pixels).
        try testing.expectEqual(c[0] / 4, get(u16, &bytes, 2));
    }
    var b: Buf = .{ .bytes = &bytes };
    putImage(&b, 1, 2, 3, 2, 0, 0, 24);
    try testing.expectEqual(@as(u16, (put_image_head + 3 * 2 * 4) / 4), get(u16, &bytes, 2));
}

test "messageSize: replies and generic events carry their length" {
    var m: [32]u8 = @splat(0);
    m[0] = motion_notify;
    try testing.expectEqual(@as(usize, 32), messageSize(&m));
    m[0] = reply;
    m[4] = 3;
    try testing.expectEqual(@as(usize, 44), messageSize(&m));
    m[0] = generic_event;
    try testing.expectEqual(@as(usize, 44), messageSize(&m));
    // A SendEvent copy (high bit set) is still 32 bytes.
    m[0] = client_message | 0x80;
    try testing.expectEqual(@as(usize, 32), messageSize(&m));
}

test "resourceDpi: Xft.dpi from the resource string" {
    try testing.expectEqual(@as(?f32, 192), resourceDpi("Xcursor.size:\t24\nXft.dpi:\t192\nXft.hinting:\t1\n"));
    try testing.expectEqual(@as(?f32, 120), resourceDpi("Xft.dpi: 120"));
    try testing.expectEqual(@as(?f32, null), resourceDpi("Xft.dpix:\t192\n*dpi: 3\n"));
    try testing.expectEqual(@as(?f32, null), resourceDpi("Xft.dpi:\tbig\n"));
    try testing.expectEqual(@as(?f32, null), resourceDpi(""));
}

test "scale: Xft.dpi wins, then the screen's physical size in quarter steps" {
    try testing.expectEqual(@as(f32, 2), scale(192, 1024, 271));
    try testing.expectEqual(@as(f32, 1.25), scale(120, 0, 0));
    try testing.expectEqual(@as(f32, 1), scale(null, 1024, 271)); // 96 DPI
    try testing.expectEqual(@as(f32, 2), scale(null, 3840, 508)); // 192 DPI
    try testing.expectEqual(@as(f32, 1.5), scale(null, 2880, 508)); // 144 DPI
    try testing.expectEqual(@as(f32, 1), scale(null, 1024, 400)); // under 96: never below 1
    try testing.expectEqual(@as(f32, 1), scale(null, 1024, 0));
}

test "uriListPaths: local file URIs, decoded" {
    var names: [64]u8 = undefined;
    var ends: [4]u32 = undefined;
    const list = "# from a file manager\r\nfile:///tmp/a%20b.txt\r\nhttp://example.com/x\r\nfile://localhost/home/x/%C3%BC.png\r\nfile://otherhost/y\r\nfile:/z\r\n";
    const n = uriListPaths(list, &names, &ends);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("/tmp/a b.txt", names[0..ends[0]]);
    try testing.expectEqualStrings("/home/x/\xc3\xbc.png", names[ends[0]..ends[1]]);
    try testing.expectEqualStrings("/z", names[ends[1]..ends[2]]);
    // Out of room: the paths that fit.
    try testing.expectEqual(@as(usize, 1), uriListPaths(list, names[0..16], &ends));
    try testing.expectEqual(@as(usize, 2), uriListPaths(list, &names, ends[0..2]));
    // A % without two hex digits is kept as it is.
    try testing.expectEqual(@as(usize, 1), uriListPaths("file:///100%\n", &names, &ends));
    try testing.expectEqualStrings("/100%", names[0..ends[0]]);
}
