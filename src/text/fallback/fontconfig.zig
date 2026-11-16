//! System font discovery on Linux, through fontconfig.
//!
//! Outside the tiers (it calls a system library), reached through system.zig. libfontconfig
//! is opened at run time (dlopen of libfontconfig.so.1, the soname every distribution ships)
//! and its few functions are looked up by name, so building needs no headers, no pkg-config
//! and no library on the build machine, and a system without fontconfig gets
//! `error.Unavailable` instead of a program that does not start.
//!
//! `find` is the fallback query of fontconfig's own clients (Pango, Chromium): a "sans-serif"
//! pattern with the character in its charset, configured (FcConfigSubstitute,
//! FcDefaultSubstitute) and sorted (FcFontSort), then the first font in that order whose
//! charset has the character and whose outlines are TrueType (fontformat "TrueType", what
//! src/text/raster/ reads; this skips CFF and bitmap fonts).

const std = @import("std");
const Found = @import("system.zig").Found;

const Pattern = opaque {};
const CharSet = opaque {};
const Config = opaque {};
const FontSet = extern struct { nfont: c_int, sfont: c_int, fonts: [*]*Pattern };
const result_match = 0;
const match_pattern = 0;

const Api = struct {
    FcInitLoadConfigAndFonts: *const fn () callconv(.c) ?*Config,
    FcConfigDestroy: *const fn (*Config) callconv(.c) void,
    FcPatternCreate: *const fn () callconv(.c) ?*Pattern,
    FcPatternDestroy: *const fn (*Pattern) callconv(.c) void,
    FcPatternAddString: *const fn (*Pattern, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    FcPatternAddCharSet: *const fn (*Pattern, [*:0]const u8, *const CharSet) callconv(.c) c_int,
    FcPatternGetString: *const fn (*const Pattern, [*:0]const u8, c_int, *?[*:0]const u8) callconv(.c) c_int,
    FcPatternGetInteger: *const fn (*const Pattern, [*:0]const u8, c_int, *c_int) callconv(.c) c_int,
    FcPatternGetCharSet: *const fn (*const Pattern, [*:0]const u8, c_int, *?*CharSet) callconv(.c) c_int,
    FcCharSetCreate: *const fn () callconv(.c) ?*CharSet,
    FcCharSetDestroy: *const fn (*CharSet) callconv(.c) void,
    FcCharSetAddChar: *const fn (*CharSet, u32) callconv(.c) c_int,
    FcCharSetHasChar: *const fn (*const CharSet, u32) callconv(.c) c_int,
    FcConfigSubstitute: *const fn (*Config, *Pattern, c_int) callconv(.c) c_int,
    FcDefaultSubstitute: *const fn (*Pattern) callconv(.c) void,
    FcFontSort: *const fn (*Config, *Pattern, c_int, ?*anyopaque, *c_int) callconv(.c) ?*FontSet,
    FcFontSetDestroy: *const fn (*FontSet) callconv(.c) void,
};

pub const Discovery = struct {
    lib: std.DynLib,
    api: Api,
    config: *Config,

    pub fn init() error{Unavailable}!Discovery {
        var lib = std.DynLib.open("libfontconfig.so.1") catch return error.Unavailable;
        errdefer lib.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names, @typeInfo(Api).@"struct".field_types) |name, T|
            @field(api, name) = lib.lookup(T, name) orelse return error.Unavailable;
        const config = api.FcInitLoadConfigAndFonts() orelse return error.Unavailable;
        return .{ .lib = lib, .api = api, .config = config };
    }

    pub fn deinit(d: *Discovery) void {
        d.api.FcConfigDestroy(d.config);
        d.lib.close();
    }

    /// The first TrueType face, in fontconfig's order for sans-serif text, that has `cp`: its
    /// path, written into `path`, and its index in the file. Null when no face has it, or
    /// when fontconfig fails to build the query.
    pub fn find(d: *Discovery, cp: u21, path: []u8) error{NoSpace}!?Found {
        const a = &d.api;
        const pat = a.FcPatternCreate() orelse return null;
        defer a.FcPatternDestroy(pat);
        const want = a.FcCharSetCreate() orelse return null;
        defer a.FcCharSetDestroy(want);
        if (a.FcCharSetAddChar(want, cp) == 0) return null;
        if (a.FcPatternAddString(pat, "family", "sans-serif") == 0) return null;
        if (a.FcPatternAddCharSet(pat, "charset", want) == 0) return null;
        if (a.FcConfigSubstitute(d.config, pat, match_pattern) == 0) return null;
        a.FcDefaultSubstitute(pat);
        var res: c_int = 0;
        const set = a.FcFontSort(d.config, pat, 1, null, &res) orelse return null;
        defer a.FcFontSetDestroy(set);
        for (set.fonts[0..@intCast(set.nfont)]) |font| {
            var cs: ?*CharSet = null;
            if (a.FcPatternGetCharSet(font, "charset", 0, &cs) != result_match) continue;
            if (a.FcCharSetHasChar(cs.?, cp) == 0) continue;
            var format: ?[*:0]const u8 = null;
            if (a.FcPatternGetString(font, "fontformat", 0, &format) != result_match) continue;
            if (!std.mem.eql(u8, std.mem.span(format.?), "TrueType")) continue;
            var file: ?[*:0]const u8 = null;
            if (a.FcPatternGetString(font, "file", 0, &file) != result_match) continue;
            var index: c_int = 0;
            if (a.FcPatternGetInteger(font, "index", 0, &index) != result_match) index = 0;
            const name = std.mem.span(file.?);
            if (name.len > path.len) return error.NoSpace;
            @memcpy(path[0..name.len], name);
            // The high 16 bits number a variable font's named instance; the face is the low.
            return .{ .path = path[0..name.len], .index = @as(u32, @bitCast(index)) & 0xffff };
        }
        return null;
    }
};
