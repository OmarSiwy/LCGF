//! Keyboard maps without libxkbcommon: the subset of the XKB text format a compositor sends in
//! `wl_keyboard.keymap` that turns a key into a scancode and typed text. From `xkb_keycodes`
//! the key names and their keycodes (aliases too); from `xkb_symbols` each key's first group,
//! four shift levels. Level = Shift (Caps Lock flips it for letters), plus 2 with Level 3
//! (AltGr, Mod5). Keysym names map to Unicode for ASCII, Latin-1, `U+XXXX` (`U1E9E`) and the
//! `0x1XXXXXX` forms.
//!
//! ponytail: no compose, dead keys, key types, groups beyond the first or keysym names outside
//! Latin-1 (`Cyrillic_a`, ... type nothing). Upgrade path: generate the keysym name table from
//! xkbcommon-keysyms.h, and read `xkb_types` for each key's levels.

const std = @import("std");
const Input = @import("lcgr").input.Input;

/// Evdev keycodes this map covers; XKB keycodes are evdev + 8.
pub const keys = 256;

pub const Keymap = struct {
    /// Unicode of each evdev key at levels 1 to 4; 0 types nothing.
    syms: [keys][4]u21 = @splat(@splat(0)),

    /// Parses an XKB keymap. Unknown parts are skipped, so a partial map gives a partial table.
    pub fn parse(src: []const u8) Keymap {
        var km: Keymap = .{};
        var names: [600]Name = undefined;
        var n: usize = 0;
        const kc = section(src, "xkb_keycodes");
        var lines = std.mem.tokenizeScalar(u8, kc, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            const alias = std.mem.startsWith(u8, line, "alias ");
            const rest = if (alias) line[6..] else line;
            if (rest.len == 0 or rest[0] != '<' or n == names.len) continue;
            const name = between(rest, '<', '>') orelse continue;
            const value = std.mem.trim(u8, rest[std.mem.indexOfScalar(u8, rest, '=') orelse continue ..][1..], " \t;");
            const code: u16 = if (alias) lookup(names[0..n], between(value, '<', '>') orelse continue) else std.fmt.parseInt(u16, value, 10) catch continue;
            names[n] = .{ .name = name, .code = code };
            n += 1;
        }
        var sy = section(src, "xkb_symbols");
        while (std.mem.indexOf(u8, sy, "key <")) |at| {
            sy = sy[at + 4 ..];
            const name = between(sy, '<', '>') orelse break;
            const code = lookup(names[0..n], name);
            // The first list that is not an index (`symbols[1]= [ ... ]`).
            var open = std.mem.indexOfScalar(u8, sy, '[') orelse break;
            var close = std.mem.indexOfScalarPos(u8, sy, open, ']') orelse break;
            while (std.mem.startsWith(u8, std.mem.trimStart(u8, sy[close + 1 ..], " \t"), "=")) {
                open = std.mem.indexOfScalarPos(u8, sy, close, '[') orelse break;
                close = std.mem.indexOfScalarPos(u8, sy, open, ']') orelse break;
            }
            defer sy = sy[close..];
            if (code < 8 or code - 8 >= keys) continue;
            var syms = std.mem.tokenizeAny(u8, sy[open + 1 .. close], ", \t\n");
            for (&km.syms[code - 8]) |*s| s.* = unicode(syms.next() orelse break);
        }
        return km;
    }

    /// What evdev key `key` types with the modifiers of `wl_keyboard.modifiers` (depressed,
    /// latched and locked ORed); 0 for nothing.
    pub fn text(km: *const Keymap, key: u32, mask: u32) u21 {
        if (key >= keys) return 0;
        const s = km.syms[key];
        // Caps Lock acts on keys whose two levels are a lower and an upper case letter.
        const letter = s[0] != s[1] and s[1] != 0 and lower(s[1]) == s[0];
        const shift = (mask & mod_shift != 0) != (letter and mask & mod_lock != 0);
        const level = @as(usize, @intFromBool(shift)) + 2 * @as(usize, @intFromBool(mask & mod_level3 != 0));
        // A key with fewer levels types its first one (Space with Shift).
        return if (s[level] != 0) s[level] else if (level >= 2) 0 else s[0];
    }
};

/// Real modifier bits of `wl_keyboard.modifiers`, in X11's fixed order, which every compiled
/// keymap keeps: Shift, Lock, Control, Mod1 (Alt), Mod2 (NumLock), Mod3, Mod4 (Super), Mod5
/// (Level 3, AltGr).
pub const mod_shift: u32 = 1 << 0;
pub const mod_lock: u32 = 1 << 1;
pub const mod_ctrl: u32 = 1 << 2;
pub const mod_alt: u32 = 1 << 3;
pub const mod_super: u32 = 1 << 6;
pub const mod_level3: u32 = 1 << 7;

/// The modifiers the core reads.
pub fn mods(mask: u32) Input.Mods {
    return .{ .shift = mask & mod_shift != 0, .ctrl = mask & mod_ctrl != 0, .alt = mask & mod_alt != 0, .cmd = mask & mod_super != 0 };
}

const Name = struct { name: []const u8, code: u16 };

fn lookup(names: []const Name, name: []const u8) u16 {
    for (names) |e| if (std.mem.eql(u8, e.name, name)) return e.code;
    return 0;
}

fn between(s: []const u8, a: u8, b: u8) ?[]const u8 {
    const i = std.mem.indexOfScalar(u8, s, a) orelse return null;
    const j = std.mem.indexOfScalarPos(u8, s, i + 1, b) orelse return null;
    return s[i + 1 .. j];
}

/// The text from `name {` to the next `xkb_` section, or empty.
fn section(src: []const u8, name: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, src, name) orelse return "";
    const body = src[at + name.len ..];
    return body[0 .. std.mem.indexOf(u8, body, "xkb_") orelse body.len];
}

fn lower(c: u21) u21 {
    return if (c < 0x80) std.ascii.toLower(@intCast(c)) else if (c >= 0xc0 and c <= 0xde and c != 0xd7) c + 0x20 else c;
}

/// Unicode of a keysym name, or 0 when it types nothing (or is not known here).
pub fn unicode(name: []const u8) u21 {
    if (name.len == 1 and name[0] > 0x20 and name[0] < 0x7f) return name[0];
    if (name.len >= 5 and name[0] == 'U') return std.fmt.parseInt(u21, name[1..], 16) catch 0;
    if (name.len == 9 and std.mem.startsWith(u8, name, "0x1")) return std.fmt.parseInt(u21, name[3..], 16) catch 0;
    return latin1.get(name) orelse 0;
}

/// Keysym names of ASCII punctuation and Latin-1, from X11/keysymdef.h (xorgproto 2025.1).
const latin1 = std.StaticStringMap(u21).initComptime(.{
    .{ "space", 0x20 },          .{ "exclam", 0x21 },        .{ "quotedbl", 0x22 },      .{ "numbersign", 0x23 },    .{ "dollar", 0x24 },
    .{ "percent", 0x25 },        .{ "ampersand", 0x26 },     .{ "apostrophe", 0x27 },    .{ "quoteright", 0x27 },    .{ "parenleft", 0x28 },
    .{ "parenright", 0x29 },     .{ "asterisk", 0x2a },      .{ "plus", 0x2b },          .{ "comma", 0x2c },         .{ "minus", 0x2d },
    .{ "period", 0x2e },         .{ "slash", 0x2f },         .{ "colon", 0x3a },         .{ "semicolon", 0x3b },     .{ "less", 0x3c },
    .{ "equal", 0x3d },          .{ "greater", 0x3e },       .{ "question", 0x3f },      .{ "at", 0x40 },            .{ "bracketleft", 0x5b },
    .{ "backslash", 0x5c },      .{ "bracketright", 0x5d },  .{ "asciicircum", 0x5e },   .{ "underscore", 0x5f },    .{ "grave", 0x60 },
    .{ "quoteleft", 0x60 },      .{ "braceleft", 0x7b },     .{ "bar", 0x7c },           .{ "braceright", 0x7d },    .{ "asciitilde", 0x7e },
    .{ "nobreakspace", 0xa0 },   .{ "exclamdown", 0xa1 },    .{ "cent", 0xa2 },          .{ "sterling", 0xa3 },      .{ "currency", 0xa4 },
    .{ "yen", 0xa5 },            .{ "brokenbar", 0xa6 },     .{ "section", 0xa7 },       .{ "diaeresis", 0xa8 },     .{ "copyright", 0xa9 },
    .{ "ordfeminine", 0xaa },    .{ "guillemotleft", 0xab }, .{ "guillemetleft", 0xab }, .{ "notsign", 0xac },       .{ "hyphen", 0xad },
    .{ "registered", 0xae },     .{ "macron", 0xaf },        .{ "degree", 0xb0 },        .{ "plusminus", 0xb1 },     .{ "twosuperior", 0xb2 },
    .{ "threesuperior", 0xb3 },  .{ "acute", 0xb4 },         .{ "mu", 0xb5 },            .{ "paragraph", 0xb6 },     .{ "periodcentered", 0xb7 },
    .{ "cedilla", 0xb8 },        .{ "onesuperior", 0xb9 },   .{ "masculine", 0xba },     .{ "ordmasculine", 0xba },  .{ "guillemotright", 0xbb },
    .{ "guillemetright", 0xbb }, .{ "onequarter", 0xbc },    .{ "onehalf", 0xbd },       .{ "threequarters", 0xbe }, .{ "questiondown", 0xbf },
    .{ "Agrave", 0xc0 },         .{ "Aacute", 0xc1 },        .{ "Acircumflex", 0xc2 },   .{ "Atilde", 0xc3 },        .{ "Adiaeresis", 0xc4 },
    .{ "Aring", 0xc5 },          .{ "AE", 0xc6 },            .{ "Ccedilla", 0xc7 },      .{ "Egrave", 0xc8 },        .{ "Eacute", 0xc9 },
    .{ "Ecircumflex", 0xca },    .{ "Ediaeresis", 0xcb },    .{ "Igrave", 0xcc },        .{ "Iacute", 0xcd },        .{ "Icircumflex", 0xce },
    .{ "Idiaeresis", 0xcf },     .{ "ETH", 0xd0 },           .{ "Eth", 0xd0 },           .{ "Ntilde", 0xd1 },        .{ "Ograve", 0xd2 },
    .{ "Oacute", 0xd3 },         .{ "Ocircumflex", 0xd4 },   .{ "Otilde", 0xd5 },        .{ "Odiaeresis", 0xd6 },    .{ "multiply", 0xd7 },
    .{ "Oslash", 0xd8 },         .{ "Ooblique", 0xd8 },      .{ "Ugrave", 0xd9 },        .{ "Uacute", 0xda },        .{ "Ucircumflex", 0xdb },
    .{ "Udiaeresis", 0xdc },     .{ "Yacute", 0xdd },        .{ "THORN", 0xde },         .{ "Thorn", 0xde },         .{ "ssharp", 0xdf },
    .{ "agrave", 0xe0 },         .{ "aacute", 0xe1 },        .{ "acircumflex", 0xe2 },   .{ "atilde", 0xe3 },        .{ "adiaeresis", 0xe4 },
    .{ "aring", 0xe5 },          .{ "ae", 0xe6 },            .{ "ccedilla", 0xe7 },      .{ "egrave", 0xe8 },        .{ "eacute", 0xe9 },
    .{ "ecircumflex", 0xea },    .{ "ediaeresis", 0xeb },    .{ "igrave", 0xec },        .{ "iacute", 0xed },        .{ "icircumflex", 0xee },
    .{ "idiaeresis", 0xef },     .{ "eth", 0xf0 },           .{ "ntilde", 0xf1 },        .{ "ograve", 0xf2 },        .{ "oacute", 0xf3 },
    .{ "ocircumflex", 0xf4 },    .{ "otilde", 0xf5 },        .{ "odiaeresis", 0xf6 },    .{ "division", 0xf7 },      .{ "oslash", 0xf8 },
    .{ "ooblique", 0xf8 },       .{ "ugrave", 0xf9 },        .{ "uacute", 0xfa },        .{ "ucircumflex", 0xfb },   .{ "udiaeresis", 0xfc },
    .{ "yacute", 0xfd },         .{ "thorn", 0xfe },         .{ "ydiaeresis", 0xff },
});

/// USB HID usage id of evdev key `key` (linux/input-event-codes.h), the scancodes `Input.keys`
/// and the widgets use; 0 for keys without one.
pub fn hid(key: u32) u8 {
    return if (key < evdev_hid.len) evdev_hid[key] else 0;
}

const evdev_hid = [_]u8{
    0, 0x29, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2d, 0x2e, 0x2a, 0x2b, // 0: Esc 1..0 - = BkSp Tab
    0x14, 0x1a, 0x08, 0x15, 0x17, 0x1c, 0x18, 0x0c, 0x12, 0x13, 0x2f, 0x30, 0x28, 0xe0, 0x04, 0x16, // 16: q..p [ ] Enter LCtrl a s
    0x07, 0x09, 0x0a, 0x0b, 0x0d, 0x0e, 0x0f, 0x33, 0x34, 0x35, 0xe1, 0x31, 0x1d, 0x1b, 0x06, 0x19, // 32: d..l ; ' ` LShift \ z x c v
    0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xe5, 0x55, 0xe2, 0x2c, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, // 48: b n m , . / RShift KP* LAlt Space Caps F1..F5
    0x3f, 0x40, 0x41, 0x42, 0x43, 0x53, 0x47, 0x5f, 0x60, 0x61, 0x56, 0x5c, 0x5d, 0x5e, 0x57, 0x59, // 64: F6..F10 NumLk ScrLk KP7 8 9 - 4 5 6 + 1
    0x5a, 0x5b, 0x62, 0x63, 0, 0, 0x64, 0x44, 0x45, 0, 0, 0, 0, 0, 0, 0, // 80: KP2 3 0 . _ _ 102nd F11 F12
    0x58, 0xe4, 0x54, 0x46, 0xe6, 0, 0x4a, 0x52, 0x4b, 0x50, 0x4f, 0x4d, 0x51, 0x4e, 0x49, 0x4c, // 96: KPEnter RCtrl KP/ SysRq RAlt _ Home Up PgUp Left Right End Down PgDn Ins Del
    0, 0x7f, 0x81, 0x80, 0, 0x67, 0, 0x48, 0, 0, 0, 0, 0, 0xe3, 0xe7, 0x65, // 112: _ Mute Vol- Vol+ _ KP= _ Pause ... LMeta RMeta Compose
};

const testing = std.testing;

test "xkb: the German keymap types what its keys say, with Shift, Caps Lock and AltGr" {
    const km: Keymap = .parse(@embedFile("testdata/de.xkb"));
    // Evdev 30 is the key labelled A, 21 is the German Z (QWERTZ), 12 is ß.
    try testing.expectEqual(@as(u21, 'a'), km.text(30, 0));
    try testing.expectEqual(@as(u21, 'A'), km.text(30, mod_shift));
    try testing.expectEqual(@as(u21, 'A'), km.text(30, mod_lock));
    try testing.expectEqual(@as(u21, 'a'), km.text(30, mod_lock | mod_shift));
    try testing.expectEqual(@as(u21, 0xe6), km.text(30, mod_level3)); // æ
    try testing.expectEqual(@as(u21, 'z'), km.text(21, 0));
    try testing.expectEqual(@as(u21, 0xdf), km.text(12, 0)); // ß
    try testing.expectEqual(@as(u21, '?'), km.text(12, mod_shift));
    try testing.expectEqual(@as(u21, '\\'), km.text(12, mod_level3));
    // Caps Lock does not shift ß: its levels are not a letter pair.
    try testing.expectEqual(@as(u21, 0xdf), km.text(12, mod_lock));
    try testing.expectEqual(@as(u21, 0xf6), km.text(39, 0)); // ö
    try testing.expectEqual(@as(u21, 0xd6), km.text(39, mod_lock));
    try testing.expectEqual(@as(u21, '!'), km.text(2, mod_shift));
    try testing.expectEqual(@as(u21, 0x2032), km.text(41, mod_level3)); // U2032, a Unicode keysym
    try testing.expectEqual(@as(u21, ' '), km.text(57, mod_shift));
    // Keys that type nothing: Escape, BackSpace, Return, a dead key, Shift itself, unknown keys.
    for ([_]u32{ 1, 14, 28, 41, 42, 100, 300 }) |k| try testing.expectEqual(@as(u21, 0), km.text(k, 0));
}

test "xkb: evdev keys to HID scancodes and modifier bits to Mods" {
    try testing.expectEqual(@as(u8, 0x04), hid(30)); // A
    try testing.expectEqual(@as(u8, 0x19), hid(47)); // V: paste with Ctrl
    try testing.expectEqual(@as(u8, 0x2a), hid(14)); // BackSpace
    try testing.expectEqual(@as(u8, 0x28), hid(28)); // Enter
    try testing.expectEqual(@as(u8, 0x50), hid(105)); // Left
    try testing.expectEqual(@as(u8, 0x4c), hid(111)); // Delete
    try testing.expectEqual(@as(u8, 0xe3), hid(125)); // Super
    try testing.expectEqual(@as(u8, 0), hid(500));
    try testing.expectEqual(Input.Mods{ .shift = true, .ctrl = true, .cmd = true }, mods(mod_shift | mod_ctrl | mod_super | mod_lock));
}
