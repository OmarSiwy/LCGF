//! System font discovery on Windows, through DirectWrite font enumeration.
//!
//! Outside the tiers (it calls an OS API), reached through system.zig. The COM interfaces are
//! declared by hand as vtable slot numbers (docs/DEPENDENCIES.md: small APIs need no header
//! translation), in the order of dwrite.h. `find` walks the system font collection
//! (IDWriteFactory::GetSystemFontCollection), takes each family's regular face
//! (GetFirstMatchingFont), and returns the first one that has the character
//! (IDWriteFont::HasCharacter) and TrueType outlines, the outlines src/text/raster/ reads:
//! its file path (IDWriteLocalFontFileLoader) and face index (IDWriteFontFace::GetIndex).
//!
//! ponytail: family order is the collection's, not the system's fallback order. The latter is
//! IDWriteFactory2::GetSystemFontFallback, which needs an IDWriteTextAnalysisSource object
//! implemented here; add it when the enumeration order picks visibly worse fonts.

const std = @import("std");
const Found = @import("system.zig").Found;

const HRESULT = i32;
const BOOL = c_int;
const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

/// A COM object: a pointer to its vtable. Methods are called by slot number.
const Com = extern struct {
    vtbl: [*]const *const anyopaque,

    fn call(o: *Com, comptime slot: usize, comptime F: type) *const F {
        return @ptrCast(o.vtbl[slot]);
    }

    fn release(o: *Com) void {
        _ = o.call(2, fn (*Com) callconv(.winapi) u32)(o);
    }
};

const iid_factory: Guid = .{ .a = 0xb859ee5a, .b = 0xd838, .c = 0x4b5b, .d = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };
const iid_local_loader: Guid = .{ .a = 0xb2d9f3ec, .b = 0xc9fe, .c = 0x4a11, .d = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 } };
const factory_type_shared = 0;
const weight_normal = 400;
const stretch_normal = 5;
const style_normal = 0;
const face_type_truetype = 1;
const face_type_truetype_collection = 2;

extern "dwrite" fn DWriteCreateFactory(factory_type: c_int, iid: *const Guid, factory: *?*Com) callconv(.winapi) HRESULT;

pub const Discovery = struct {
    factory: *Com,
    collection: *Com,

    pub fn init() error{Unavailable}!Discovery {
        var factory: ?*Com = null;
        if (DWriteCreateFactory(factory_type_shared, &iid_factory, &factory) < 0) return error.Unavailable;
        const f = factory orelse return error.Unavailable;
        var collection: ?*Com = null;
        // IDWriteFactory::GetSystemFontCollection (slot 3).
        if (f.call(3, fn (*Com, *?*Com, BOOL) callconv(.winapi) HRESULT)(f, &collection, 0) < 0 or collection == null) {
            f.release();
            return error.Unavailable;
        }
        return .{ .factory = f, .collection = collection.? };
    }

    pub fn deinit(d: *Discovery) void {
        d.collection.release();
        d.factory.release();
    }

    /// The first system face with TrueType outlines that has `cp`: its path, written into
    /// `path` as UTF-8, and its index in the file. Null when no face has it.
    pub fn find(d: *Discovery, cp: u21, path: []u8) error{NoSpace}!?Found {
        const c = d.collection;
        // IDWriteFontCollection::GetFontFamilyCount (3), GetFontFamily (4).
        const families = c.call(3, fn (*Com) callconv(.winapi) u32)(c);
        for (0..families) |i| {
            var family: ?*Com = null;
            if (c.call(4, fn (*Com, u32, *?*Com) callconv(.winapi) HRESULT)(c, @intCast(i), &family) < 0) continue;
            const fam = family orelse continue;
            defer fam.release();
            var font: ?*Com = null;
            // IDWriteFontFamily::GetFirstMatchingFont (7).
            if (fam.call(7, fn (*Com, c_int, c_int, c_int, *?*Com) callconv(.winapi) HRESULT)(fam, weight_normal, stretch_normal, style_normal, &font) < 0) continue;
            const fnt = font orelse continue;
            defer fnt.release();
            var has: BOOL = 0;
            // IDWriteFont::HasCharacter (12).
            if (fnt.call(12, fn (*Com, u32, *BOOL) callconv(.winapi) HRESULT)(fnt, cp, &has) < 0 or has == 0) continue;
            if (try located(fnt, path)) |found| return found;
        }
        return null;
    }
};

/// The file and index of `font`, or null when it is not a TrueType face in a local file.
fn located(font: *Com, path: []u8) error{NoSpace}!?Found {
    var face: ?*Com = null;
    // IDWriteFont::CreateFontFace (13).
    if (font.call(13, fn (*Com, *?*Com) callconv(.winapi) HRESULT)(font, &face) < 0) return null;
    const ff = face orelse return null;
    defer ff.release();
    // IDWriteFontFace::GetType (3), GetFiles (4), GetIndex (5).
    const kind = ff.call(3, fn (*Com) callconv(.winapi) c_int)(ff);
    if (kind != face_type_truetype and kind != face_type_truetype_collection) return null;
    var count: u32 = 1;
    var file: ?*Com = null;
    if (ff.call(4, fn (*Com, *u32, ?*?*Com) callconv(.winapi) HRESULT)(ff, &count, &file) < 0) return null;
    const fl = file orelse return null;
    defer fl.release();
    const index = ff.call(5, fn (*Com) callconv(.winapi) u32)(ff);

    // IDWriteFontFile::GetReferenceKey (3), GetLoader (4).
    var key: ?*const anyopaque = null;
    var key_size: u32 = 0;
    if (fl.call(3, fn (*Com, *?*const anyopaque, *u32) callconv(.winapi) HRESULT)(fl, &key, &key_size) < 0) return null;
    var loader: ?*Com = null;
    if (fl.call(4, fn (*Com, *?*Com) callconv(.winapi) HRESULT)(fl, &loader) < 0) return null;
    const ld = loader orelse return null;
    defer ld.release();
    // Only fonts loaded from local files have a path (IUnknown::QueryInterface, 0).
    var local: ?*Com = null;
    if (ld.call(0, fn (*Com, *const Guid, *?*Com) callconv(.winapi) HRESULT)(ld, &iid_local_loader, &local) < 0) return null;
    const lo = local orelse return null;
    defer lo.release();
    // IDWriteLocalFontFileLoader::GetFilePathLengthFromKey (4), GetFilePathFromKey (5).
    var len: u32 = 0;
    if (lo.call(4, fn (*Com, ?*const anyopaque, u32, *u32) callconv(.winapi) HRESULT)(lo, key, key_size, &len) < 0) return null;
    var wide: [1024]u16 = undefined;
    if (len + 1 > wide.len) return error.NoSpace;
    if (lo.call(5, fn (*Com, ?*const anyopaque, u32, [*]u16, u32) callconv(.winapi) HRESULT)(lo, key, key_size, &wide, len + 1) < 0) return null;
    // UTF-8 needs at most 3 bytes per UTF-16 unit.
    if (path.len < @as(usize, len) * 3) return error.NoSpace;
    const n = std.unicode.utf16LeToUtf8(path, wide[0..len]) catch return null;
    return .{ .path = path[0..n], .index = index };
}
