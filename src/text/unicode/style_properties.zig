//! Optional typography lookups. These tables are not added to the core row pipeline.
const data = @import("style_data.zig");

pub fn flags(cp: u21) u8 {
    var lo: usize = 0;
    var hi: usize = data.ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const row = data.ranges[mid];
        if (cp < row.first) hi = mid else if (cp > row.last) lo = mid + 1 else return row.flags;
    }
    return 0;
}

pub fn ambiguousWidth(cp: u21) bool {
    return flags(cp) & 1 != 0;
}

pub fn cjkWidth(cp: u21) bool {
    return flags(cp) & 9 != 0; // Ambiguous, Fullwidth or Wide; Halfwidth is not included.
}

pub const Emphasis = enum { mark, separator, skip };
pub fn emphasis(cp: u21) Emphasis {
    const bits = flags(cp);
    return if (bits & 4 != 0) .skip else if (bits & 2 != 0) .separator else .mark;
}
