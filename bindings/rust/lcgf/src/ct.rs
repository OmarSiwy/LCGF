//! Static UIs compiled in Rust. The comptime pipeline (Zig's ct_layout and ct_paint,
//! src/abi/ct.zig's frame) as generics over a UI's tables, which `include_ui!(.., static)`
//! writes as associated consts of a `Tables` impl. Every row count, style value and paint
//! template is a compile-time constant here, as it is to Zig's compiler, so they fold into the
//! passes. Nothing crosses the C seam: the UI is a value of its own, with no buffer.
//!
//! The passes are src/layout/layout.zig's (prepare, applyText, fit, resolve, place, finalize)
//! without their flex terms, src/text/protocol.zig's Mono measure and src/draw/paint.zig's
//! encode, ported operation for operation: the same IEEE operations in the same order (Rust
//! never fuses a*b+c), min and max as the selects of `simd.maxF`/`simd.minF`, `@round` as
//! `round` below. bindings/check/run.sh holds the draw lists byte-identical to Zig's.

use crate::{DrawList, Quad, RawDraw, Str, TextRun};
use core::marker::PhantomData;

#[inline(always)]
const fn f(bits: u32) -> f32 {
    f32::from_bits(bits)
}
/// `simd.maxF`: a > b ? a : b. A tie or a NaN `a` gives `b`.
#[inline(always)]
fn max_f(a: f32, b: f32) -> f32 {
    if a > b { a } else { b }
}
/// `simd.minF`: a < b ? a : b.
#[inline(always)]
fn min_f(a: f32, b: f32) -> f32 {
    if a < b { a } else { b }
}
#[inline(always)]
fn b01(c: bool) -> f32 {
    if c { 1.0 } else { 0.0 }
}
/// `@round` on four lanes: half away from zero, the sign of zero kept, without std and without
/// a conversion. Below 2^23, `(|x| + 2^23) - 2^23` is |x| rounded half to even, exactly; a `.5`
/// that went down to even goes up by one. At or above 2^23, and for NaN and the infinities, `x`
/// is its own rounding. Lane-wise and branch-free, so it becomes one vector of each operation.
#[inline(always)]
fn round4(x: [f32; 4]) -> [f32; 4] {
    const BIG: f32 = 8_388_608.0;
    let mut out = [0.0; 4];
    for k in 0..4 {
        let a = f32::from_bits(x[k].to_bits() & 0x7fff_ffff);
        let even = (a + BIG) - BIG;
        let r = even + b01(even - a == -0.5);
        let signed = f32::from_bits((r.to_bits() & 0x7fff_ffff) | (x[k].to_bits() & 0x8000_0000));
        out[k] = if a < BIG { signed } else { x[k] };
    }
    out
}

/// One dynamic region of a tree: kind 1 list, 2 when, 3 choice; `alts` indexes the tree's
/// choice windows; `scroll` is 1 for a windowed list; `height` an f32's bits.
#[derive(Clone, Copy, Debug)]
pub struct Region {
    pub kind: u32,
    pub row: u32,
    pub end: u32,
    pub stride: u32,
    pub max: u32,
    pub alts: u32,
    pub scroll: u32,
    pub height: u32,
}

/// One tree of a UI's tables, `n` rows per column, floats as bits.
pub struct Block {
    pub n: usize,
    pub parent: &'static [u32],
    pub min: [&'static [u32]; 2],
    pub max: [&'static [u32]; 2],
    pub grow: [&'static [u32]; 2],
    pub pct: [&'static [u32]; 2],
    pub pad_lo: [&'static [u32]; 2],
    pub pad_hi: [&'static [u32]; 2],
    pub offset: [&'static [u32]; 2],
    pub scroll: [&'static [u32]; 2],
    pub main: [&'static [u32]; 2],
    pub gap: &'static [u32],
    pub gap_total: &'static [u32],
    pub flow: &'static [u32],
    pub shrink: &'static [u32],
    pub align_main: &'static [u32],
    pub align_cross: &'static [u32],
    pub clips: &'static [u8],
    pub border: &'static [u32],
    pub label_rows: &'static [u32],
    pub regions: &'static [Region],
    pub alts: &'static [[u32; 2]],
}

/// A UI's tables, as `include_ui!(.., static)` writes them.
pub trait Tables {
    type State;
    /// The generated widget enum: one variant per widget, valued by its row.
    type Widget: Copy + PartialEq + core::fmt::Debug;
    /// The generated event enum: `Mute`, `Volume(f32)`: one variant per widget, a slider's
    /// carrying its value.
    type Event: Copy + core::fmt::Debug;
    /// The generated field enum, for `relayout` and `patch`.
    type Field: Copy;
    /// Per field: the rows its labels move (first, last), `u32::MAX` twice when none.
    const SPANS: &'static [[u32; 2]];
    /// ct_paint.Patches' entries, by template: field, template, target (0 fill, 1 border).
    const PATCHES: &'static [[u32; 4]];
    fn field_index(f: Self::Field) -> usize;
    /// Colour field `field`'s rgba bits.
    fn color(s: &Self::State, field: usize) -> u32;
    /// Widget rows in widget order; which are sliders; the focus order (widget slots).
    const WIDGET_ROWS: &'static [u32];
    const WIDGET_SLIDER: &'static [bool];
    const FOCUS_ORDER: &'static [u32];
    fn widget(slot: usize) -> Self::Widget;
    fn event(slot: usize, value: f32) -> Self::Event;
    const N: usize;
    const LABELS: usize;
    const QUADS: usize;
    const BATCHES: usize;
    const REGIONS: usize;
    const SLOT_COUNT: usize;
    const COORD: u32;
    const STRING_CAP: usize;
    const FOLDED: bool;
    const LIVE: bool;
    const WINDOWS: bool;
    const HAS_CHILD_CLIP: bool;
    const ROOT_WHEN: bool;
    const SLOTS_SHARED: bool;
    const TEXT_PX: u32;
    const TEXT_FONT: u32;
    const ADVANCE: u32;
    const LINE: u32;
    const FULL: Block;
    const SKEL: Block;
    const EXPAND_BASE: &'static [u32];
    const EXPAND_REL: [&'static [u32]; 2];
    const EXPAND_SIZE: [&'static [u32]; 2];
    const EXPAND_KEEP: &'static [u32];
    const PAINT_NODE: &'static [u32];
    const CLIP_NODE: &'static [u32];
    const KEYS: &'static [u32];
    const TEMPLATES: &'static [[u32; 34]];
    const BATCH_FIRST: &'static [u32];
    const BATCH_COUNT: &'static [u32];
    const BATCH_KEY: &'static [u32];
    /// node, parent, quad_end, padding (4 f32), colour.
    const LABEL_PLANS: &'static [[u32; 8]];
    const SLOT_OF: &'static [u32];
    const SLOT_DEFAULTS: &'static [u32];
    /// The labels' text, in label order, written to `o` (string fields, and formats as the
    /// generator wrote them out); `end[k]` is where label k's bytes end.
    fn texts(s: &Self::State, o: &mut Sink<'_>, end: &mut [u32]);
    /// The regions' selectors (a count, a condition, a choice) and scroll offsets.
    fn select(s: &Self::State, n: &mut [u32], scroll: &mut [f32]);
}

/// Where a static UI's label text goes (src/core/fmt.zig's `Sink`): the rest of the frame's
/// strings. What does not fit is dropped byte by byte, as every engine drops it.
pub struct Sink<'a> {
    buf: &'a mut [u8],
    pub len: usize,
}

impl<'a> Sink<'a> {
    pub fn new(buf: &'a mut [u8]) -> Self {
        Self { buf, len: 0 }
    }
    #[inline(always)]
    pub fn put(&mut self, b: &[u8]) {
        let n = b.len().min(self.buf.len() - self.len);
        self.buf[self.len..self.len + n].copy_from_slice(&b[..n]);
        self.len += n;
    }
    #[inline(always)]
    pub fn put_str(&mut self, s: Str) {
        self.put(s.as_str().as_bytes());
    }
    #[inline(always)]
    pub fn put_bool(&mut self, v: bool) {
        self.put(if v { b"true" } else { b"false" });
    }
    /// In decimal.
    #[inline(always)]
    pub fn put_uint(&mut self, v: u64) {
        let mut d = [0u8; 20];
        let at = decimal(&mut d, v, 1);
        self.put(&d[at..]);
    }
    /// `v` with `prec` decimals: widened to f64, times 10^prec, rounded half away from zero;
    /// the sign only on a non-zero result; `nan`, and `inf` or `-inf` for an infinity or a
    /// result of 10^18 or more.
    #[inline(always)]
    pub fn put_f32(&mut self, v: f32, prec: usize) {
        if v.is_nan() {
            return self.put(b"nan");
        }
        const POW10: [f64; 7] = [1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0, 1000000.0];
        let scaled = round_half_away(v as f64 * POW10[prec]);
        if scaled.abs() >= 1e18 {
            return self.put(if v < 0.0 { b"-inf" } else { b"inf" });
        }
        if scaled < 0.0 {
            self.put(b"-");
        }
        let mut d = [0u8; 20];
        let at = decimal(&mut d, scaled.abs() as u64, prec + 1);
        self.put(&d[at..20 - prec]);
        if prec > 0 {
            self.put(b".");
            self.put(&d[20 - prec..]);
        }
    }
}

/// `v` in decimal at the end of `d`, at least `min_digits` long; returns where it starts.
#[inline(always)]
fn decimal(d: &mut [u8; 20], mut v: u64, min_digits: usize) -> usize {
    let mut at = 20;
    while v != 0 || 20 - at < min_digits {
        at -= 1;
        d[at] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    at
}

/// `f64::round` (half away from zero), exact, without std: below 2^52 the truncation and the
/// difference from it are exact; at or above it every f64 is an integer. NaN is not passed.
#[inline(always)]
fn round_half_away(x: f64) -> f64 {
    if !(x.abs() < 4503599627370496.0) {
        return x;
    }
    let t = x as i64 as f64;
    let diff = x - t;
    if diff >= 0.5 {
        t + 1.0
    } else if diff <= -0.5 {
        t - 1.0
    } else {
        t
    }
}

/// One region's selection this frame.
#[derive(Clone, Copy, Default)]
struct Select {
    n: u32,
    offset: f32,
}

/// ct_dynamic's `selectWindow`: the live copies of a windowed list scrolled `scroll` px.
fn select_window(count: u32, visible: u32, height: f32, scroll: f32) -> Select {
    let h = height as f64;
    let max_scroll = count.saturating_sub(visible) as f64 * h;
    let s = scroll as f64;
    let px = (if s > 0.0 { s } else { 0.0 }).min(max_scroll);
    // px >= 0, so truncation is floor.
    let first = (px / h) as u32;
    let offset = (px - first as f64 * h) as f32;
    Select {
        n: (count - first).min(visible + (offset > 0.0) as u32),
        offset,
    }
}

/// Per-frame columns of one tree of `N` rows.
struct Scratch<const N: usize> {
    fit: [[f32; N]; 2],
    nat: [[f32; N]; 2],
    grow_sum: [[f32; N]; 2],
    grow_inv: [[f32; N]; 2],
    used: [[f32; N]; 2],
    size: [[f32; N]; 2],
    pos: [[f32; N]; 2],
    cursor: [f32; N],
    max: [[f32; N]; 2],
    flow: [f32; N],
    nkids: [f32; N],
    gap_total: [f32; N],
    scroll: [[f32; N]; 2],
    mask: [u32; N],
}

impl<const N: usize> Scratch<N> {
    const ZERO: Self = Self {
        fit: [[0.0; N]; 2],
        nat: [[0.0; N]; 2],
        grow_sum: [[0.0; N]; 2],
        grow_inv: [[0.0; N]; 2],
        used: [[0.0; N]; 2],
        size: [[0.0; N]; 2],
        pos: [[0.0; N]; 2],
        cursor: [0.0; N],
        max: [[0.0; N]; 2],
        flow: [0.0; N],
        nkids: [0.0; N],
        gap_total: [0.0; N],
        scroll: [[0.0; N]; 2],
        mask: [0; N],
    };

    #[inline(always)]
    fn max_<T: Tables>(&self, b: &Block, a: usize, i: usize) -> f32 {
        if T::LIVE {
            self.max[a][i]
        } else {
            f(b.max[a][i])
        }
    }
    #[inline(always)]
    fn flow_<T: Tables>(&self, b: &Block, i: usize) -> f32 {
        if T::LIVE { self.flow[i] } else { f(b.flow[i]) }
    }
    #[inline(always)]
    fn gap_total_<T: Tables>(&self, b: &Block, i: usize) -> f32 {
        if T::LIVE {
            self.gap_total[i]
        } else {
            f(b.gap_total[i])
        }
    }
    #[inline(always)]
    fn scroll_<T: Tables>(&self, b: &Block, a: usize, i: usize) -> f32 {
        if T::WINDOWS {
            self.scroll[a][i]
        } else {
            f(b.scroll[a][i])
        }
    }

    /// ct_dynamic.Regions.mask.
    #[inline(always)]
    fn live_mask<T: Tables>(&mut self, b: &Block, sel: &[Select]) {
        self.mask = [!0; N];
        for (g, r) in b.regions.iter().enumerate() {
            let first = if r.kind == 2 { r.row } else { r.row + 1 };
            let (lo, len) = match r.kind {
                1 => (first, sel[g].n.min(r.max) * r.stride),
                2 => (first, sel[g].n.min(1) * (r.end - r.row)),
                _ => {
                    let w = b.alts[(r.alts + sel[g].n.min(r.max)) as usize];
                    (w[0], w[1])
                }
            };
            for j in first..r.end {
                self.mask[j as usize] &= 0u32.wrapping_sub((j.wrapping_sub(lo) < len) as u32);
            }
        }
    }

    #[inline(always)]
    fn fit<T: Tables, const A: usize>(&mut self, b: &Block, first: usize, last: usize) {
        let a = A;
        for i in (first + 1..last).rev() {
            let content = self.fit[a][i] + f(b.main[a][i]) * self.gap_total_::<T>(b, i);
            let mut nat = content + f(b.pad_lo[a][i]) + f(b.pad_hi[a][i]);
            nat = min_f(max_f(nat, f(b.min[a][i])), self.max_::<T>(b, a, i));
            self.nat[a][i] = nat;
            let p = b.parent[i] as usize;
            let contrib = nat * self.flow_::<T>(b, i);
            let fp = self.fit[a][p];
            let sum = fp + contrib;
            let mx = if fp < contrib { contrib } else { fp };
            self.fit[a][p] = if f(b.main[a][p]) != 0.0 { sum } else { mx };
            self.grow_sum[a][p] += f(b.grow[a][i]) * self.flow_::<T>(b, i);
        }
        // The root of the span has no parent to fold into.
        let content = self.fit[a][first] + f(b.main[a][first]) * self.gap_total_::<T>(b, first);
        let nat = content + f(b.pad_lo[a][first]) + f(b.pad_hi[a][first]);
        self.nat[a][first] = min_f(max_f(nat, f(b.min[a][first])), self.max_::<T>(b, a, first));
        for j in first..last {
            self.grow_inv[a][j] = 1.0 / max_f(self.grow_sum[a][j], 1e-6);
        }
    }

    #[inline(always)]
    fn resolve<T: Tables, const A: usize>(&mut self, b: &Block, first: usize, last: usize) {
        let a = A;
        let m = 0.0f32;
        for i in first + 1..last {
            let p = b.parent[i] as usize;
            let nat = self.nat[a][i];
            let main = f(b.main[a][p]);
            let taken = self.fit[a][p] + self.gap_total_::<T>(b, p);
            let fl = self.flow_::<T>(b, i);
            let pct = f(b.pct[a][i]);
            let grow = f(b.grow[a][i]);
            let has_pct = b01(pct >= 0.0);
            let keep = 1.0 - has_pct;
            let across = (1.0 - main) * b01(grow > 0.0);
            let k0 = nat * keep * (1.0 - fl * across);
            let k1 = has_pct * pct + keep * fl * across;
            let k2 = keep * fl * main * grow * self.grow_inv[a][p];
            let inner = max_f(self.size[a][p] - f(b.pad_lo[a][p]) - f(b.pad_hi[a][p]), 0.0);
            let mut s = k0 + k1 * inner + k2 * max_f(inner - taken, 0.0);
            let room = max_f(inner - main * (taken - nat) - (1.0 - main) * m, 0.0);
            let cut = f(b.shrink[i]) * fl * max_f(s - room, 0.0);
            s -= cut;
            s = min_f(max_f(s, f(b.min[a][i])), self.max_::<T>(b, a, i));
            self.size[a][i] = s;
            self.used[a][p] += (s + m) * fl;
        }
    }

    #[inline(always)]
    fn place<T: Tables>(&mut self, b: &Block, first: usize, last: usize) {
        let (m, m_lo) = (0.0f32, 0.0f32);
        for i in first + 1..last {
            let p = b.parent[i] as usize;
            let fl = self.flow_::<T>(b, i);
            for a in 0..2 {
                let inner = self.size[a][p] - f(b.pad_lo[a][p]) - f(b.pad_hi[a][p]);
                let lead = max_f(inner - self.used[a][p] - self.gap_total_::<T>(b, p), 0.0)
                    * f(b.align_main[p]);
                let cross = f(b.align_cross[p]);
                let across = max_f(inner - self.size[a][i] - m, 0.0) * cross + m_lo;
                let along = lead + self.cursor[p] + m_lo;
                let in_flow = across + f(b.main[a][p]) * (along - across);
                self.pos[a][i] = self.pos[a][p] + f(b.pad_lo[a][p]) - self.scroll_::<T>(b, a, p)
                    + fl * in_flow
                    + f(b.offset[a][i]);
            }
            let step = self.size[0][i] * f(b.main[0][p]) + self.size[1][i] * f(b.main[1][p]);
            let advance = step + f(b.gap[p]);
            self.cursor[p] += advance * fl;
        }
    }

    /// `Plain.passesLiveText`: every pass but finalize.
    #[inline(always)]
    fn passes<T: Tables>(
        &mut self,
        b: &Block,
        w: &[f32],
        h: &[f32],
        sel: &[Select],
        vw: f32,
        vh: f32,
    ) {
        if T::LIVE {
            self.live_mask::<T>(b, sel);
            for i in 0..N {
                for a in 0..2 {
                    self.max[a][i] = f(b.max[a][i] & self.mask[i]);
                }
                self.flow[i] = f(b.flow[i] & self.mask[i]);
                self.nkids[i] = 0.0;
            }
            for j in 1..N {
                self.nkids[b.parent[j] as usize] += self.flow[j];
            }
            if T::WINDOWS {
                for a in 0..2 {
                    for i in 0..N {
                        self.scroll[a][i] = f(b.scroll[a][i]);
                    }
                }
                for (g, r) in b.regions.iter().enumerate() {
                    if r.scroll != 0 {
                        self.scroll[1][r.row as usize] = sel[g].offset;
                    }
                }
            }
            for i in 0..N {
                self.gap_total[i] = f(b.gap[i]) * max_f(self.nkids[i] - 1.0, 0.0);
            }
        }
        self.fit = [[0.0; N]; 2];
        self.grow_sum = [[0.0; N]; 2];
        self.used = [[0.0; N]; 2];
        self.cursor = [0.0; N];
        let shown = !T::ROOT_WHEN || sel[0].n != 0;
        for k in 0..T::LABELS {
            self.fit[0][b.label_rows[k] as usize] = w[k];
        }
        self.fit::<T, 0>(b, 0, N);
        self.size[0][0] = if shown { vw } else { 0.0 };
        self.resolve::<T, 0>(b, 0, N);
        for k in 0..T::LABELS {
            self.fit[1][b.label_rows[k] as usize] = h[k];
        }
        self.fit::<T, 1>(b, 0, N);
        self.size[1][0] = if shown { vh } else { 0.0 };
        self.resolve::<T, 1>(b, 0, N);
        self.pos[0][0] = 0.0;
        self.pos[1][0] = 0.0;
        self.place::<T>(b, 0, N);
    }

    /// `Plain.relayout` over the subtree [first, last): the accumulators of its rows cleared,
    /// every label's extent applied, and fit, resolve and place over the span only. The span's
    /// root keeps its size and position.
    #[inline(always)]
    fn relayout_span<T: Tables>(
        &mut self,
        b: &Block,
        w: &[f32],
        h: &[f32],
        first: usize,
        last: usize,
    ) {
        for a in 0..2 {
            for i in first..last {
                self.fit[a][i] = 0.0;
                self.grow_sum[a][i] = 0.0;
                self.used[a][i] = 0.0;
            }
        }
        for i in first..last {
            self.cursor[i] = 0.0;
        }
        for k in 0..T::LABELS {
            self.fit[0][b.label_rows[k] as usize] = w[k];
        }
        self.fit::<T, 0>(b, first, last);
        self.resolve::<T, 0>(b, first, last);
        for k in 0..T::LABELS {
            self.fit[1][b.label_rows[k] as usize] = h[k];
        }
        self.fit::<T, 1>(b, first, last);
        self.resolve::<T, 1>(b, first, last);
        self.place::<T>(b, first, last);
    }
}

/// A static UI over tables `T`: a value holding the state and its frame's columns, no buffer.
/// The const parameters are sizes lcgf-gen writes for the UI (rows, skeleton rows, labels,
/// quads + 1, runs + 1, ops); use the generated `<name>::Ui`.
pub struct Ui<
    T: Tables,
    const N: usize,
    const SN: usize,
    const L: usize,
    const Q: usize,
    const R: usize,
    const O: usize,
> {
    pub state: T::State,
    pressed: u32,
    down: bool,
    focus: Option<T::Widget>,
    vis: [[f32; N]; 4],
    strings_len: usize,
    dirty: [bool; Q],
    full: Scratch<N>,
    skel: Scratch<SN>,
    rect: [[f32; N]; 4],
    child_clip: [[f32; 4]; N],
    visible: [u8; N],
    slot_source: [u32; N],
    sel: [Select; N],
    w: [f32; L],
    h: [f32; L],
    spans: [[u32; 2]; L],
    strings: [u8; 1024],
    quads: [Quad; Q],
    runs: [TextRun; R],
    op_kind: [u8; O],
    op_key: [u32; O],
    op_ref: [u32; O],
    cmd_kind: [u8; O],
    cmd_first: [u32; O],
    cmd_count: [u32; O],
    cmd_key: [u32; O],
    raw: RawDraw,
    _t: PhantomData<T>,
}

const INF: f32 = f32::INFINITY;
const NONE: u32 = u32::MAX;

/// One keyboard shortcut (ct_events.Shortcut): a scancode, the modifiers that must be held
/// exactly (`Input::SHIFT`, ...) and the widget it activates.
#[derive(Clone, Copy, Debug)]
pub struct Shortcut<W> {
    pub code: u8,
    pub mods: u8,
    pub widget: W,
}

impl<
    T: Tables,
    const N: usize,
    const SN: usize,
    const L: usize,
    const Q: usize,
    const R: usize,
    const O: usize,
> Ui<T, N, SN, L, Q, R, O>
{
    const QUAD0: Quad = Quad {
        rect: [0.0; 4],
        clip: [0.0; 4],
        params: [0.0; 4],
        uv: [0.0; 4],
        radii: [0.0; 4],
        fill: 0,
        border_color: 0,
        border: 0.0,
        opacity: 0.0,
        xform: [0.0; 6],
        clip_radii: [0.0; 4],
    };
    const RUN0: TextRun = TextRun {
        rect: [0.0; 4],
        clip: [0.0; 4],
        start: 0,
        bytes: 0,
        px: 0.0,
        color: 0,
        font: 0,
        opacity: 1.0,
        xform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
        clip_radii: [0.0; 4],
    };

    pub fn new(state: T::State) -> Self {
        assert!(T::STRING_CAP <= 1024 && T::N == N && T::REGIONS <= N);
        Self {
            state,
            pressed: NONE,
            down: false,
            focus: None,
            vis: [[0.0; N]; 4],
            strings_len: 0,
            dirty: [false; Q],
            full: Scratch::ZERO,
            skel: Scratch::ZERO,
            rect: [[0.0; N]; 4],
            child_clip: [[0.0; 4]; N],
            visible: [0; N],
            slot_source: [0; N],
            sel: [Select::default(); N],
            w: [0.0; L],
            h: [0.0; L],
            spans: [[0; 2]; L],
            strings: [0; 1024],
            quads: [Self::QUAD0; Q],
            runs: [Self::RUN0; R],
            op_kind: [0; O],
            op_key: [0; O],
            op_ref: [0; O],
            cmd_kind: [0; O],
            cmd_first: [0; O],
            cmd_count: [0; O],
            cmd_key: [0; O],
            raw: RawDraw {
                quads: core::ptr::null(),
                quad_len: 0,
                run_len: 0,
                runs: core::ptr::null(),
                strings: core::ptr::null(),
                strings_len: 0,
                cmd_kind: core::ptr::null(),
                cmd_first: core::ptr::null(),
                cmd_count: core::ptr::null(),
                cmd_key: core::ptr::null(),
                cmd_len: 0,
                custom_len: 0,
                customs: core::ptr::null(),
            },
            _t: PhantomData,
        }
    }

    pub fn state(&self) -> &T::State {
        &self.state
    }

    /// One frame in a `width` x `height` viewport: the labels' text and the regions' selectors
    /// from the state, laid out and painted. The draw list borrows the UI.
    pub fn frame(&mut self, width: f32, height: f32) -> DrawList<'_> {
        self.gather();
        self.select();
        self.layout(width, height);
        self.paint(self.strings_len);
        self.patch_all();
        self.draw()
    }

    /// The last frame's draw list.
    pub fn draw(&self) -> DrawList<'_> {
        DrawList {
            raw: self.raw,
            _ui: PhantomData,
        }
    }

    /// Lays out again only what `field` moves (ct_layout's `relayout`), after a frame: the
    /// subtree of the common relayout boundary of its labels, from tables made at compile
    /// time (constant once inlined with a literal field). A field no label shows moves
    /// nothing. Then a full repaint, as `frame`'s. Last frame's viewport and selection stay.
    #[inline(always)]
    pub fn relayout(&mut self, field: T::Field) -> DrawList<'_> {
        let span = T::SPANS[T::field_index(field)];
        if span[0] == NONE {
            return self.draw();
        }
        self.gather();
        let (vw, vh) = (self.full.size[0][0], self.full.size[1][0]);
        if T::FOLDED || (span[0] == 0 && !T::LIVE) {
            // The whole tree: the folded passes, or a field shown above every boundary.
            self.layout(vw, vh);
        } else {
            let (first, last) = (span[0] as usize, span[1] as usize);
            self.full
                .relayout_span::<T>(&T::FULL, &self.w, &self.h, first, last);
            self.finalize(first, last);
        }
        self.paint(self.strings_len);
        self.patch_all();
        self.draw()
    }

    /// Writes `field`'s colour into the quads bound to it (ct_paint's `Patches.apply`): the rgb
    /// of their fill or border, their alpha kept, and marks them dirty. No layout, no paint.
    #[inline(always)]
    pub fn patch(&mut self, field: T::Field) {
        self.patch_index(T::field_index(field));
    }

    /// The draw list's quads a patch changed since `clear_dirty`; all of them after a frame.
    pub fn dirty(&self) -> &[bool] {
        &self.dirty[..T::QUADS]
    }
    pub fn clear_dirty(&mut self) {
        self.dirty = [false; Q];
    }

    #[inline(always)]
    fn patch_index(&mut self, fi: usize) {
        let bits = T::color(&self.state, fi);
        let (mut cursor, mut seen) = (0usize, 0u32);
        for p in T::PATCHES {
            if p[0] as usize != fi {
                continue;
            }
            let k = p[1] as usize;
            let mut row = k as u32;
            if self.raw.quad_len as usize != T::QUADS {
                for j in cursor..k {
                    seen += self.shown(j);
                }
                cursor = k;
                row = if self.shown(k) != 0 {
                    seen
                } else {
                    NONE
                };
            }
            if row == NONE {
                continue;
            }
            let q = &mut self.quads[row as usize];
            if p[2] == 0 {
                q.fill = (q.fill & 0xff00_0000) | (bits & 0x00ff_ffff);
            } else {
                q.border_color = (q.border_color & 0xff00_0000) | (bits & 0x00ff_ffff);
            }
            self.dirty[row as usize] = true;
        }
    }

    /// Every field's patches (`applyAll`); every quad dirty.
    #[inline(always)]
    fn patch_all(&mut self) {
        if !T::PATCHES.is_empty() {
            for fi in 0..T::SPANS.len() {
                self.patch_index(fi);
            }
        }
        self.dirty = [true; Q];
    }

    /// The labels' text, gathered into the frame's strings in label order, and measured.
    #[inline(always)]
    fn gather(&mut self) {
        let mut end = [0u32; L];
        let mut o = Sink::new(&mut self.strings[..T::STRING_CAP]);
        T::texts(&self.state, &mut o, &mut end);
        let mut at = 0usize;
        for k in 0..T::LABELS {
            let len = end[k] as usize - at;
            self.spans[k] = [at as u32, len as u32];
            at = end[k] as usize;
            self.w[k] = len as f32 * f(T::TEXT_PX) * f(T::ADVANCE);
            self.h[k] = f(T::TEXT_PX) * f(T::LINE);
        }
        self.strings_len = at;
    }

    /// The regions' selections from the state.
    #[inline(always)]
    fn select(&mut self) {
        if T::REGIONS > 0 {
            let mut n = [0u32; N];
            let mut scroll = [0f32; N];
            T::select(&self.state, &mut n, &mut scroll);
            for g in 0..T::REGIONS {
                let r = T::FULL.regions[g];
                self.sel[g] = if r.scroll != 0 {
                    select_window(n[g], r.max - 1, f(r.height), scroll[g])
                } else {
                    Select {
                        n: n[g],
                        offset: 0.0,
                    }
                };
            }
        }
    }

    /// Every pass over the whole tree (through the skeleton when folded), then finalize.
    #[inline(always)]
    fn layout(&mut self, width: f32, height: f32) {
        if !T::FOLDED {
            self.full
                .passes::<T>(&T::FULL, &self.w, &self.h, &self.sel, width, height);
        } else {
            self.skel
                .passes::<T>(&T::SKEL, &self.w, &self.h, &self.sel, width, height);
            for j in 0..N {
                let b = T::EXPAND_BASE[j] as usize;
                for a in 0..2 {
                    self.full.pos[a][j] = self.skel.pos[a][b] + f(T::EXPAND_REL[a][j]);
                    self.full.size[a][j] =
                        self.skel.size[a][b] * f(T::EXPAND_KEEP[j]) + f(T::EXPAND_SIZE[a][j]);
                }
            }
            if T::REGIONS > 0 {
                self.full.live_mask::<T>(&T::FULL, &self.sel);
            }
        }
        if T::SLOTS_SHARED {
            self.slot_source[..T::SLOT_COUNT].copy_from_slice(T::SLOT_DEFAULTS);
            for i in 0..N {
                if self.full.mask[i] != 0 {
                    self.slot_source[T::SLOT_OF[i] as usize] = i as u32;
                }
            }
        }
        self.finalize(0, N);
    }

    /// Pixel-snapped rects, then clip rects and visibility (layout.finalize).
    #[inline(always)]
    fn finalize(&mut self, first: usize, last: usize) {
        let b = &T::FULL;
        for j in first..last {
            let (x, y) = (self.full.pos[0][j], self.full.pos[1][j]);
            // Four lanes of one row at once, so the rounding vectorizes.
            let r = round4([x, y, x + self.full.size[0][j], y + self.full.size[1][j]]);
            for k in 0..4 {
                self.rect[k][j] = r[k];
            }
        }
        const SIGN: [f32; 4] = [1.0, 1.0, -1.0, -1.0];
        if first == 0 {
            self.child_clip[0] = [-INF; 4];
        }
        for i in first..last {
            let inherited = self.child_clip[b.parent[i] as usize];
            let mut clip = [0.0; 4];
            let mut out = [0.0; 4];
            for k in 0..4 {
                let r = self.rect[k][i] * SIGN[k];
                let v = max_f(r, inherited[k]);
                let inner = if b.clips[i] != 0 {
                    r + f(b.border[i])
                } else {
                    -INF
                };
                clip[k] = max_f(inherited[k], inner);
                out[k] = v * SIGN[k];
                self.vis[k][i] = out[k];
            }
            self.child_clip[i] = clip;
            self.visible[i] = ((out[0] < out[2]) as u8) & ((out[1] < out[3]) as u8);
        }
    }

    /// The topmost widget under (x, y) in the last frame's layout (ct_events.at): half-open
    /// edges, and the latest widget wins where widgets overlap.
    pub fn at(&self, x: f32, y: f32) -> Option<T::Widget> {
        let k = self.at_slot(x, y);
        if k == NONE {
            None
        } else {
            Some(T::widget(k as usize))
        }
    }

    /// This frame's pointer event (ct_events.pointer): a press picks the widget under the
    /// pointer; a checkbox is clicked when the release is over it too; a slider reports its
    /// value every frame it is held.
    pub fn pointer(&mut self, input: &crate::Input) -> Option<T::Event> {
        let down = input.buttons & crate::Input::LEFT != 0;
        let (x, y) = (input.pointer[0], input.pointer[1]);
        if down && !self.down {
            self.pressed = self.at_slot(x, y);
        }
        self.down = down;
        let k = self.pressed;
        if k == NONE {
            return None;
        }
        if !down {
            self.pressed = NONE;
        }
        let k = k as usize;
        if T::WIDGET_SLIDER[k] {
            if !down {
                return None;
            }
            let r = self.vis_of(T::WIDGET_ROWS[k] as usize);
            let x0 = r[0];
            let span = r[2] - x0;
            let v = 0.0f32.max(((x - x0) / span.max(f32::MIN_POSITIVE)).min(1.0));
            return Some(T::event(k, v));
        }
        if down || self.at_slot(x, y) != k as u32 {
            return None;
        }
        Some(T::event(k, 0.0))
    }

    /// The widget Tab (`back` false) or Shift+Tab moves focus to from `from`, wrapping
    /// (ct_events.nextFocus).
    pub fn next_focus(from: Option<T::Widget>, back: bool) -> Option<T::Widget> {
        let len = T::FOCUS_ORDER.len();
        if len == 0 {
            return None;
        }
        let at = from.and_then(|w| {
            T::FOCUS_ORDER
                .iter()
                .position(|&k| T::widget(k as usize) == w)
        });
        let k = match at {
            None => {
                if back {
                    len - 1
                } else {
                    0
                }
            }
            Some(a) => {
                if back {
                    (a + len - 1) % len
                } else {
                    (a + 1) % len
                }
            }
        };
        Some(T::widget(T::FOCUS_ORDER[k] as usize))
    }

    /// Moves focus for every Tab press and repeat in this frame's keys; Shift goes back.
    pub fn focus_keys(&mut self, input: &crate::Input, tab: u8) {
        for e in input.key_events() {
            if e.code != tab || (e.kind != 0 && e.kind != 2) {
                continue;
            }
            self.focus = Self::next_focus(self.focus, e.mods & crate::Input::SHIFT as u8 != 0);
        }
    }
    pub fn focus(&self) -> Option<T::Widget> {
        self.focus
    }
    pub fn set_focus(&mut self, w: Option<T::Widget>) {
        self.focus = w;
    }

    /// The widget a shortcut of `list` activates for key `code` with exactly `mods` held.
    pub fn shortcut(list: &[Shortcut<T::Widget>], code: u8, mods: u8) -> Option<T::Widget> {
        list.iter()
            .find(|s| s.code == code && s.mods & 0xf == mods & 0xf)
            .map(|s| s.widget)
    }

    fn at_slot(&self, x: f32, y: f32) -> u32 {
        let mut found = NONE;
        for (k, &row) in T::WIDGET_ROWS.iter().enumerate() {
            let r = self.vis_of(row as usize);
            if x >= r[0] && x < r[2] && y >= r[1] && y < r[3] {
                found = k as u32;
            }
        }
        found
    }

    /// The visible rect of row i as the comptime UI keeps it, in its coordinate type.
    fn vis_of(&self, i: usize) -> [f32; 4] {
        let g = self.geometry(i);
        let mut r = [
            self.vis[0][g],
            self.vis[1][g],
            self.vis[2][g],
            self.vis[3][g],
        ];
        if T::COORD != 0 {
            let hi = ((1i64 << (T::COORD - 1)) - 1) as f32;
            let lo = -hi - 1.0;
            for x in &mut r {
                *x = (if *x < lo {
                    lo
                } else if *x > hi {
                    hi
                } else {
                    *x
                }) as i32 as f32;
            }
        }
        r
    }

    #[inline(always)]
    fn geometry(&self, i: usize) -> usize {
        if T::SLOTS_SHARED {
            self.slot_source[T::SLOT_OF[i] as usize] as usize
        } else {
            i
        }
    }

    /// Rect of row i as the comptime UI keeps it: in its coordinate type.
    #[inline(always)]
    fn rect_of(&self, i: usize) -> [f32; 4] {
        let g = self.geometry(i);
        let mut r = [
            self.rect[0][g],
            self.rect[1][g],
            self.rect[2][g],
            self.rect[3][g],
        ];
        if T::COORD != 0 {
            let hi = ((1i64 << (T::COORD - 1)) - 1) as f32;
            let lo = -hi - 1.0;
            for x in &mut r {
                *x = (if *x < lo {
                    lo
                } else if *x > hi {
                    hi
                } else {
                    *x
                }) as i32 as f32;
            }
        }
        r
    }

    #[inline(always)]
    fn clip_of(&self, i: usize) -> [f32; 4] {
        if !T::HAS_CHILD_CLIP {
            return [-INF, -INF, INF, INF];
        }
        let c = self.child_clip[self.geometry(i)];
        [c[0], c[1], -c[2], -c[3]]
    }

    /// Whether template k paints this frame (ct.zig's `shown`): present, and its paint bounds
    /// (a shadow grows by three sigma) inside its parent's clip have area.
    #[inline(always)]
    fn shown(&self, k: usize) -> u32 {
        let i = T::PAINT_NODE[k] as usize;
        // SAFETY: as in emit_quads.
        let q: Quad = unsafe { core::mem::transmute(T::TEMPLATES[k]) };
        let (r, c) = (self.rect_of(i), self.clip_of(T::CLIP_NODE[k] as usize));
        let sigma = q.params[1];
        let g = if q.params[0].to_bits() == 3 && sigma.is_finite() { sigma.max(0.0) * 3.0 } else { 0.0 };
        let b = [(r[0] - g).max(c[0]), (r[1] - g).max(c[1]), (r[2] + g).min(c[2]), (r[3] + g).min(c[3])];
        let present = if T::REGIONS > 0 { self.visible[i] as u32 } else { 1 };
        present & ((b[0] < b[2]) & (b[1] < b[3])) as u32
    }

    #[inline(always)]
    fn emit_quads(&mut self, first: usize, end: usize, quad: &mut u32, op: &mut u32) {
        for k in first..end {
            let i = T::PAINT_NODE[k] as usize;
            // SAFETY: `Quad` is 34 f32/u32 fields, `repr(C)`, as the template's words.
            let mut q: Quad = unsafe { core::mem::transmute(T::TEMPLATES[k]) };
            q.rect = self.rect_of(i);
            q.clip = self.clip_of(T::CLIP_NODE[k] as usize);
            self.quads[*quad as usize] = q;
            self.op_kind[*op as usize] = 0;
            self.op_key[*op as usize] = T::KEYS[k];
            self.op_ref[*op as usize] = *quad;
            let shown = self.shown(k);
            *quad += shown;
            *op += shown;
        }
    }

    /// paint.encode: consecutive quad ops with equal keys form one command.
    #[inline(always)]
    fn encode(&mut self, op_len: u32) {
        let (mut n, mut first, mut count, mut prev_key) = (0u32, 0u32, 0u32, 0u32);
        let mut prev_kind = 0xffu8;
        for j in 0..op_len as usize {
            let kind = self.op_kind[j];
            let key = self.op_key[j];
            let brk = (kind != 0) as u32 | (kind != prev_kind) as u32 | (key != prev_key) as u32;
            n += brk;
            let k = (n - 1) as usize;
            self.cmd_kind[k] = kind;
            self.cmd_key[k] = key;
            first = if brk != 0 { self.op_ref[j] } else { first };
            count = if brk != 0 { 0 } else { count } + 1;
            self.cmd_first[k] = first;
            self.cmd_count[k] = count;
            prev_kind = kind;
            prev_key = key;
        }
        self.raw.cmd_len = n;
    }

    /// ct_paint's `emit` and `emitLiveText`.
    #[inline(always)]
    fn paint(&mut self, strings_len: usize) {
        let (mut quad, mut op) = (0u32, 0u32);
        if T::LABELS == 0 {
            self.emit_quads(0, T::QUADS, &mut quad, &mut op);
            if quad as usize == T::QUADS {
                for b in 0..T::BATCHES {
                    self.cmd_kind[b] = 0;
                    self.cmd_first[b] = T::BATCH_FIRST[b];
                    self.cmd_count[b] = T::BATCH_COUNT[b];
                    self.cmd_key[b] = T::BATCH_KEY[b];
                }
                self.raw.cmd_len = T::BATCHES as u32;
            } else {
                self.encode(op);
            }
            self.raw.run_len = 0;
        } else {
            let (mut first, mut r) = (0usize, 0u32);
            for l in 0..T::LABELS {
                let plan = T::LABEL_PLANS[l];
                self.emit_quads(first, plan[2] as usize, &mut quad, &mut op);
                first = plan[2] as usize;
                let mut rect = self.rect_of(plan[0] as usize);
                for k in 0..4 {
                    rect[k] += f(plan[3 + k]);
                }
                self.runs[r as usize] = TextRun {
                    rect,
                    clip: self.clip_of(plan[1] as usize),
                    start: self.spans[l][0],
                    bytes: self.spans[l][1],
                    px: f(T::TEXT_PX),
                    color: plan[7],
                    font: T::TEXT_FONT,
                    opacity: 1.0,
                    xform: [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
                    clip_radii: [0.0; 4],
                };
                self.op_kind[op as usize] = 1;
                self.op_key[op as usize] = 0;
                self.op_ref[op as usize] = r;
                op += self.visible[plan[0] as usize] as u32;
                r += if T::REGIONS > 0 {
                    (self.full.mask[plan[0] as usize] != 0) as u32
                } else {
                    1
                };
            }
            self.emit_quads(first, T::QUADS, &mut quad, &mut op);
            self.raw.run_len = r;
            self.encode(op);
        }
        self.raw.quads = self.quads.as_ptr();
        self.raw.quad_len = quad;
        self.raw.runs = self.runs.as_ptr();
        self.raw.strings = self.strings.as_ptr();
        self.raw.strings_len = strings_len;
        self.raw.cmd_kind = self.cmd_kind.as_ptr();
        self.raw.cmd_first = self.cmd_first.as_ptr();
        self.raw.cmd_count = self.cmd_count.as_ptr();
        self.raw.cmd_key = self.cmd_key.as_ptr();
        self.raw.custom_len = 0;
        self.raw.customs = core::ptr::null();
    }
}
