//! Explicit bounded line-break tailoring over the pinned Unicode 16 UAX14 opportunities.
//! The native `unicode` mode preserves the existing conformant default. Other modes apply
//! CSS Text 3's listed CJK strictness distinctions, without claiming dictionary-based Thai
//! or an automatically selected locale. Mandatory breaks and grapheme boundaries are owned
//! by the caller; glue, joiners, whitespace and opening punctuation retain their protection.
//! https://www.w3.org/TR/css-text-3/#line-break-property

const property = @import("../unicode/property.zig");
const optional = @import("../unicode/style_properties.zig");

pub const Mode = enum { unicode, normal, strict, loose, anywhere };
pub const WritingSystem = enum { other, japanese, chinese };
pub const Options = struct { mode: Mode = .unicode, writing_system: WritingSystem = .other };

fn iteration(cp: u21) bool {
    return switch (cp) {
        0x3005, 0x303b, 0x309d, 0x309e, 0x30fd, 0x30fe => true,
        else => false,
    };
}
fn centered(cp: u21) bool {
    return switch (cp) {
        0x30fb, 0xff1a, 0xff1b, 0xff65, 0x203c, 0x2047, 0x2048, 0x2049, 0xff01, 0xff1f => true,
        else => false,
    };
}

/// A pair of adjacent shaped grapheme bases, with the original UAX14 decision. These
/// explicit native rules permit the CJK exceptions but never introduce a break inside a
/// shaped cluster. `anywhere` is the separate deliberate override of glue/joiner policies.
pub fn allowed(before: u21, after: u21, standard: bool, options: Options) bool {
    if (options.mode == .unicode) return standard;
    if (options.mode == .anywhere) return true;
    const a = property.line(before);
    const b = property.line(after);
    if (a.lb == .WJ or b.lb == .WJ or a.lb == .GL or b.lb == .GL or a.lb == .ZWJ or b.lb == .ZWJ or b.lb == .CM) return standard;
    // UAX14 context rules such as OP SP* must not be bypassed by a pair exception.
    if (a.lb == .OP or a.lb == .QU or b.lb == .QU or a.lb == .SP or a.lb == .ZW or b.lb == .SP or b.lb == .ZW) return standard;
    const cjk = options.writing_system == .japanese or options.writing_system == .chinese;
    const loose = options.mode == .loose;
    if (after == 0x301c or after == 0x30a0) return cjk and options.mode != .strict;
    if (after == 0x2010 or after == 0x2013) return loose and a.lb == .ID;
    if (b.lb == .CJ or iteration(after)) return loose;
    if (a.lb == .IN and b.lb == .IN) return loose;
    if (centered(after)) return cjk and loose;
    if ((b.lb == .PO and optional.cjkWidth(after)) or (a.lb == .PR and optional.cjkWidth(before))) return cjk and loose;
    return standard;
}
