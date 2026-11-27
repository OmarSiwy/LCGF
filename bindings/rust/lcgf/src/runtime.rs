//! LCGF's runtime front end from Rust: build the UI each frame in code, as a Zig program does
//! with `ctx.begin(&in)` and `f.open(...)`. A style becomes its row here (`Row::from`, folded
//! at compile time when the style is constant), and `open` and `leaf` store it into the frame's
//! columns inline (`lcgf_frame_view`); the rest is one direct call each into the prebuilt liblcgf
//! (`lcgf.h`, generated from src/abi/api.zig). Your buffer holds everything.
//!
//! ```ignore
//! let mut ctx = runtime::Context::new(&mut buf, limits)?;
//! let mut f = ctx.begin(&input);
//! f.open(Id::from("toolbar"), &Style { dir: Dir::X, gap: 8.0, fill: th.panel, ..Style::DEFAULT });
//! if runtime::button(&mut f, Id::from("reset"), "Reset").clicked() { resets += 1; }
//! f.close();
//! let (draw, wake) = f.end();
//! ```

use crate::{DrawList, Input, RawFrame, Status};
use core::marker::PhantomData;

/// A node's identity: FNV-1a of its name, never 0 (`Id.hash` in Zig, inline here).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Id(pub u32);

impl Id {
    pub const NONE: Self = Self(0);
    pub const fn from(name: &str) -> Self {
        Self::from_bytes(name.as_bytes())
    }
    /// The id of a name of any bytes.
    pub const fn from_bytes(b: &[u8]) -> Self {
        let mut h: u32 = 0x811c9dc5;
        let mut i = 0;
        while i < b.len() {
            h = (h ^ b[i] as u32).wrapping_mul(0x01000193);
            i += 1;
        }
        Self(h + (h == 0) as u32)
    }
    /// A child id, for nodes made in a loop (`Id.with`).
    pub const fn with(self, n: u32) -> Self {
        let mut x = self.0 ^ n.wrapping_add(0x9E3779B9);
        x = (x ^ (x >> 16)).wrapping_mul(0x85EBCA6B);
        x = (x ^ (x >> 13)).wrapping_mul(0xC2B2AE35);
        x ^= x >> 16;
        Self(x + (x == 0) as u32)
    }
}

pub const fn rgb(r: u8, g: u8, b: u8) -> u32 {
    r as u32 | (g as u32) << 8 | (b as u32) << 16 | 0xff << 24
}

include!("types.rs");

/// What a widget reports this frame.
#[derive(Clone, Copy, Debug)]
pub struct Response(pub u8);

impl Response {
    pub fn hovered(self) -> bool {
        self.0 & 1 != 0
    }
    pub fn held(self) -> bool {
        self.0 & 2 != 0
    }
    pub fn clicked(self) -> bool {
        self.0 & 16 != 0
    }
    pub fn focused(self) -> bool {
        self.0 & 32 != 0
    }
}

/// A context's sizes (`lcgf_limits`, Zig's `Limits`): `Limits { nodes: 256, ..Limits::default() }`.
pub type Limits = crate::sys::lcgf_limits;

impl Default for Limits {
    fn default() -> Self {
        crate::sys::LCGF_LIMITS_DEFAULT
    }
}

/// A node's row as the library stores it (`lcgf_row`, Zig's `Template`). `Row::from` is
/// `Template.from`, run here (at compile time in a `const`), so only the row crosses the seam.
/// The `Frame` calls that take a `Style` make the row inline; the `_row` calls take one made.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Row {
    pub min: [f32; 2],
    pub max: [f32; 2],
    pub grow: [f32; 2],
    pub pct: [f32; 2],
    pub pad_lo: [f32; 2],
    pub pad_hi: [f32; 2],
    pub offset: [f32; 2],
    pub scroll: [f32; 2],
    pub main: [f32; 2],
    pub gap: f32,
    pub flow: f32,
    pub shrink: f32,
    pub align_main: f32,
    pub align_cross: f32,
    pub clips: u32,
    pub sense: u32,
    pub params: [f32; 4],
    pub fill: u32,
    pub border_color: u32,
    pub radius: f32,
    pub texture: u32,
    pub material: u32,
    pub role: u32,
    pub value: f32,
    pub text: u32,
    pub custom: u32,
    pub own: u32,
    pub border: f32,
    pub uv: [f32; 4],
    pub radii: [f32; 4],
    pub opacity: f32,
    pub transform: [f32; 6],
    pub transform_origin: [f32; 2],
    pub paint_reference: u32,
    pub paint_outset: [f32; 4],
    pub prepared_texture: u32,
    pub paint_revision: u32,
    pub participation: u32,
    pub cursor: u32,
}
const _: () = assert!(core::mem::size_of::<Row>() == 66 * 4);

// Template.from's selects: on a tie or a NaN, the second operand (the style's bound).
#[inline(always)]
const fn fmax(a: f32, b: f32) -> f32 {
    if a > b { a } else { b }
}
#[inline(always)]
const fn fmin(a: f32, b: f32) -> f32 {
    if a < b { a } else { b }
}

impl Row {
    pub const DEFAULT: Self = Self::from(&Style::DEFAULT);

    #[inline(always)]
    pub const fn from(s: &Style) -> Self {
        const K_MIN: [f32; 4] = [0.0, 1.0, 0.0, 0.0];
        const K_MAX: [f32; 4] = [0.0, 1.0, 0.0, 0.0];
        const C_MAX: [f32; 4] = [f32::INFINITY, 0.0, f32::INFINITY, f32::INFINITY];
        const K_GROW: [f32; 4] = [0.0, 0.0, 1.0, 0.0];
        const K_PCT: [f32; 4] = [0.0, 0.0, 0.0, 1.0];
        const C_PCT: [f32; 4] = [-1.0, -1.0, -1.0, 0.0];
        const FACTOR: [f32; 3] = [0.0, 0.5, 1.0];
        const NONE: u32 = 0xffff_ffff;
        let (k0, k1) = ((s.size[0].kind & 3) as usize, (s.size[1].kind & 3) as usize);
        let (v0, v1) = (s.size[0].v, s.size[1].v);
        let along_y = s.dir as u32 as f32;
        // The fill tints the texture; a texture with no fill shows its own colours (white tint).
        let untinted = ((s.texture & 0xffff) != 0 && (s.fill >> 24) == 0) as u32;
        let t = &s.transform;
        let mut off = s.border != 0.0 || s.opacity != 1.0;
        off |=
            t[0] != 1.0 || t[1] != 0.0 || t[2] != 0.0 || t[3] != 1.0 || t[4] != 0.0 || t[5] != 0.0;
        off |= s.uv[0] != 0.0 || s.uv[1] != 0.0 || s.uv[2] != 1.0 || s.uv[3] != 1.0;
        off |= s.radii[0] >= 0.0 || s.radii[1] >= 0.0 || s.radii[2] >= 0.0 || s.radii[3] >= 0.0;
        let r = s.radius;
        let c = &s.radii;
        Self {
            min: [
                fmax(v0 * K_MIN[k0], s.min[0]),
                fmax(v1 * K_MIN[k1], s.min[1]),
            ],
            max: [
                fmin(v0 * K_MAX[k0] + C_MAX[k0], s.max[0]),
                fmin(v1 * K_MAX[k1] + C_MAX[k1], s.max[1]),
            ],
            grow: [v0 * K_GROW[k0], v1 * K_GROW[k1]],
            pct: [v0 * K_PCT[k0] + C_PCT[k0], v1 * K_PCT[k1] + C_PCT[k1]],
            pad_lo: [s.pad[0], s.pad[1]],
            pad_hi: [s.pad[2], s.pad[3]],
            offset: s.offset,
            scroll: s.scroll,
            main: [1.0 - along_y, along_y],
            gap: s.gap,
            flow: if s.floating != 0 { 0.0 } else { 1.0 },
            shrink: if s.shrink != 0 { 1.0 } else { 0.0 },
            align_main: FACTOR[s.main as usize],
            align_cross: FACTOR[s.cross as usize],
            clips: (s.clip != 0) as u32,
            sense: 0,
            params: s.params,
            fill: s.fill | 0u32.wrapping_sub(untinted),
            border_color: s.border_color,
            radius: r,
            texture: s.texture & 0xffff,
            material: s.material & 0xffff,
            role: s.role as u32 & 0xff,
            value: s.value,
            text: NONE,
            custom: NONE,
            own: off as u32
                | (s.clip != 0) as u32
                | (s.paint_outset[0] != 0.0
                    || s.paint_outset[1] != 0.0
                    || s.paint_outset[2] != 0.0
                    || s.paint_outset[3] != 0.0
                    || s.cursor != NONE
                    || s.paint_reference != NONE
                    || (s.participation & 0xff) != 15) as u32,
            border: s.border,
            uv: s.uv,
            radii: [
                if c[0] < 0.0 { r } else { c[0] },
                if c[1] < 0.0 { r } else { c[1] },
                if c[2] < 0.0 { r } else { c[2] },
                if c[3] < 0.0 { r } else { c[3] },
            ],
            opacity: s.opacity,
            transform: s.transform,
            transform_origin: s.transform_origin,
            paint_reference: s.paint_reference,
            paint_outset: s.paint_outset,
            prepared_texture: 0,
            paint_revision: 0,
            participation: s.participation & 0xff,
            cursor: if s.cursor == NONE {
                255
            } else {
                s.cursor & 0xff
            },
        }
    }
}

impl From<&Style> for Row {
    #[inline(always)]
    fn from(s: &Style) -> Self {
        Row::from(s)
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Look {
    params: [f32; 4],
    fill: u32,
    border_color: u32,
    radius: f32,
    texture: u16,
    material: u16,
}

#[repr(C)]
struct Extra {
    border: f32,
    uv: [f32; 4],
    radii: [f32; 4],
    opacity: f32,
    transform: [f32; 6],
    transform_origin: [f32; 2],
    paint_reference: u32,
    paint_outset: [f32; 4],
    prepared_texture: u32,
    paint_revision: u32,
    participation: u8,
    active_participation: u8,
    cursor: u8,
    active_cursor: u8,
    // alpha, world and clip_radii follow; paint writes them, a push does not.
    _paint: [f32; 11],
}

/// The frame's tree, where a row is pushed (`lcgf_view`, src/abi/view.zig's `CView`).
#[repr(C)]
#[derive(Clone, Copy)]
struct View {
    len: *mut u32,
    xlen: *mut u32,
    overflow: *mut bool,
    depth: *mut u32,
    status: *mut u8,
    cap: u32,
    depth_cap: u32,
    stack: *mut u32,
    id: *mut u32,
    parent: *mut u32,
    end: *mut u32,
    min: [*mut f32; 2],
    max: [*mut f32; 2],
    grow: [*mut f32; 2],
    pct: [*mut f32; 2],
    pad_lo: [*mut f32; 2],
    pad_hi: [*mut f32; 2],
    offset: [*mut f32; 2],
    scroll: [*mut f32; 2],
    main: [*mut f32; 2],
    gap: *mut f32,
    nkids: *mut f32,
    flow: *mut f32,
    shrink: *mut f32,
    align_main: *mut f32,
    align_cross: *mut f32,
    clips: *mut u8,
    sense: *mut u8,
    look: *mut Look,
    role: *mut u8,
    value: *mut f32,
    text: *mut u32,
    custom: *mut u32,
    extra: *mut u32,
    scope: *mut u32,
    x_node: *mut u32,
    x_row: *mut Extra,
}

include!("rows.rs");

/// The bit of `View::status` that `enter` sets when the stack overflows (`LCGF_DEPTH_BIT`).
const DEPTH_BIT: u32 = sys::LCGF_DEPTH_BIT;

impl View {
    /// `Tree.pushRow` into the columns `lcgf_frame_view` gave, what Zig's inlined `open` does, with
    /// no call: the stores are generated from Zig's types (rows.rs, tools/abi-gen); what is here
    /// is the rest of pushRow. bindings/check/run.sh holds the frames byte-identical.
    #[inline(always)]
    unsafe fn push(&self, id: u32, r: &Row) -> u32 {
        unsafe {
            let parent_in = *self.stack.add(*self.depth as usize - 1);
            let n = *self.len;
            let i = n.min(self.cap - 1);
            *self.overflow |= n >= self.cap;
            *self.len = i + 1;
            // Full, the last row is rewritten: the parent is clamped below it (parent < row).
            let parent = parent_in.min(i.saturating_sub(1));
            let (iu, pu) = (i as usize, parent as usize);
            *self.id.add(iu) = id;
            *self.parent.add(iu) = parent;
            *self.end.add(iu) = i + 1;
            store_node(self, iu, r);
            // Participation narrows down the tree; without layout the node collapses.
            let up = if i == 0 {
                15
            } else {
                (*self.x_row.add(*self.scope.add(pu) as usize)).active_participation
            };
            let mut active = r.participation as u8 & up;
            if active & 1 == 0 {
                active = 0;
                collapse_node(self, iu);
            }
            *self.role.add(iu) &= 0u8.wrapping_sub((active >> 3) & 1);
            *self.sense.add(iu) &= 0u8.wrapping_sub((active >> 2) & 1);
            // Counted in its parent, its own count cleared (the root is its own parent).
            *self.nkids.add(pu) += *self.flow.add(iu);
            *self.nkids.add(iu) = 0.0;
            // The extras row, appended when the row has one.
            let own = r.own != 0;
            let x = (*self.xlen).min(self.cap);
            *self.xlen = x + r.own;
            *self.extra.add(iu) = if own { x } else { 0 };
            *self.scope.add(iu) = 0;
            *self.scope.add(iu) = if own { x } else { *self.scope.add(pu) };
            if !own {
                return i;
            }
            *self.x_node.add(x as usize) = i;
            let e = &mut *self.x_row.add(x as usize);
            store_extra(e, r);
            // A reference to this row or a later one paints from the node itself (Tree.pushRow).
            e.paint_reference = if r.paint_reference < i {
                r.paint_reference
            } else {
                u32::MAX
            };
            e.active_participation = active;
            e.active_cursor = if r.cursor != 255 {
                r.cursor as u8
            } else if i == 0 {
                255
            } else {
                (*self.x_row.add(*self.scope.add(pu) as usize)).active_cursor
            };
            i
        }
    }

    /// `Frame.enter`: too deep, the deepest slot is reused and the overflow flagged.
    #[inline(always)]
    unsafe fn enter(&self, i: u32) -> u32 {
        unsafe {
            let depth = *self.depth;
            let d = depth.min(self.depth_cap - 1);
            *self.status |= ((depth >= self.depth_cap) as u8) << DEPTH_BIT;
            *self.stack.add(d as usize) = i;
            *self.depth = d + 1;
            i
        }
    }
}

type Rt = *mut u8;

use crate::sys;

/// `lcgf_frame`: a frame in progress, two pointers only the library reads.
type RawFrameH = sys::lcgf_frame;
type FrameP = *mut sys::lcgf_frame;

/// The same bits as C's type: the crate's own types are laid out as lcgf.h's (checked below).
#[inline(always)]
fn c<T, U>(p: *const T) -> *const U {
    p.cast()
}
#[inline(always)]
fn c_<T, U>(p: *const T) -> *const U {
    p.cast()
}

const _: () = {
    use core::mem::size_of;
    assert!(size_of::<Style>() == size_of::<sys::lcgf_style>());
    assert!(size_of::<TextStyle>() == size_of::<sys::lcgf_text_style>());
    assert!(size_of::<Theme>() == size_of::<sys::lcgf_theme>());
    assert!(size_of::<Row>() == size_of::<sys::lcgf_row>());
    assert!(size_of::<Limits>() == size_of::<sys::lcgf_limits>());
    assert!(size_of::<Spring>() == size_of::<sys::lcgf_spring>());
    assert!(size_of::<View>() == size_of::<sys::lcgf_view>());
    assert!(size_of::<Extra>() == size_of::<sys::lcgf_extra>());
    assert!(size_of::<Look>() == size_of::<sys::lcgf_look>());
};

/// The runtime front end in your buffer.
pub struct Context<'a> {
    rt: Rt,
    theme: Theme,
    label: TextStyle,
    frame: RawFrameH,
    last: core::mem::MaybeUninit<RawFrame>,
    _buf: PhantomData<&'a mut [u8]>,
}

impl<'a> Context<'a> {
    /// Bytes a context of `limits` needs, aligned to `COLUMN_ALIGN`.
    pub fn bytes(limits: &Limits) -> usize {
        unsafe { sys::lcgf_context_required_bytes(c(limits)) }
    }

    pub fn new(buf: &'a mut [u8], limits: &Limits) -> Result<Self, Status> {
        // Rows are made here, so the library must lay them out as this crate does.
        if unsafe { sys::lcgf_layout() } != sys::LCGF_LAYOUT {
            return Err(Status::LayoutHash);
        }
        let r = unsafe { sys::lcgf_context_init(buf.as_mut_ptr().cast(), buf.len(), c(limits)) };
        if r != 0 {
            return Err(unsafe { core::mem::transmute::<i32, Status>(r) });
        }
        let theme = Theme::DEFAULT;
        let mut label = core::mem::MaybeUninit::<TextStyle>::uninit();
        let label = unsafe {
            sys::lcgf_label_text(c(&theme), label.as_mut_ptr().cast());
            label.assume_init()
        };
        Ok(Self {
            rt: buf.as_mut_ptr(),
            theme,
            label,
            frame: RawFrameH {
                p_: [core::ptr::null_mut(); 2],
            },
            last: core::mem::MaybeUninit::uninit(),
            _buf: PhantomData,
        })
    }

    pub fn theme(&self) -> &Theme {
        &self.theme
    }

    /// Bytes [`enable_canvas`](Self::enable_canvas) needs for `limits`, aligned to a pointer.
    pub fn canvas_bytes(limits: &Limits) -> usize {
        unsafe { sys::lcgf_context_canvas_bytes(c(limits)) }
    }

    /// Lets frames hold canvas nodes ([`Frame::canvas`]), their rows kept in `buf`.
    pub fn enable_canvas(&mut self, buf: &'a mut [u8]) -> Result<(), Status> {
        let r = unsafe {
            sys::lcgf_context_enable_canvas(self.rt.cast(), buf.as_mut_ptr().cast(), buf.len())
        };
        if r != 0 {
            return Err(unsafe { core::mem::transmute::<i32, Status>(r) });
        }
        Ok(())
    }

    /// Whether this input needs a frame (a host that sleeps between events asks first).
    pub fn needs_frame(&mut self, input: &Input) -> bool {
        unsafe { sys::lcgf_context_needs_frame(self.rt.cast(), c(input)) != 0 }
    }

    /// Begins a frame; build it, then [`Frame::end`] it.
    pub fn begin(&mut self, input: &Input) -> Frame<'_> {
        let mut view = core::mem::MaybeUninit::<View>::uninit();
        let view = unsafe {
            sys::lcgf_context_begin(self.rt.cast(), c(input), &mut self.frame);
            sys::lcgf_frame_view(&mut self.frame, view.as_mut_ptr().cast());
            view.assume_init()
        };
        Frame {
            f: &mut self.frame,
            theme: &self.theme,
            label: &self.label,
            view,
            last: &mut self.last,
        }
    }
}

/// A frame being built: it borrows its context, and what its canvas nodes draw, until its draw
/// list (from [`end`](Frame::end)) is dropped.
pub struct Frame<'f> {
    f: FrameP,
    theme: *const Theme,
    label: *const TextStyle,
    view: View,
    last: &'f mut core::mem::MaybeUninit<RawFrame>,
}

impl<'f> Frame<'f> {
    /// Lays out and paints the frame. The draw list keeps the context, and every canvas batch
    /// and option the frame drew, borrowed while it is used; with the seconds until a frame is
    /// needed though nothing happened.
    pub fn end(self) -> (DrawList<'f>, f32) {
        let f = unsafe {
            sys::lcgf_frame_end(self.f, self.last.as_mut_ptr().cast());
            self.last.assume_init_read()
        };
        (
            DrawList {
                raw: f.draw,
                _ui: PhantomData,
            },
            f.wake,
        )
    }

    #[inline(always)]
    pub fn open(&mut self, id: Id, s: &Style) -> u32 {
        self.open_row(id, &Row::from(s))
    }
    #[inline(always)]
    pub fn open_row(&mut self, id: Id, r: &Row) -> u32 {
        // SAFETY: the view is this frame's (`begin`), and the frame borrows the context.
        unsafe { self.view.enter(self.view.push(id.0, r)) }
    }
    pub fn close(&mut self) {
        unsafe { sys::lcgf_frame_close(self.f) }
    }
    #[inline(always)]
    pub fn leaf(&mut self, id: Id, s: &Style) -> u32 {
        self.leaf_row(id, &Row::from(s))
    }
    #[inline(always)]
    pub fn leaf_row(&mut self, id: Id, r: &Row) -> u32 {
        unsafe {
            let i = self.view.enter(self.view.push(id.0, r));
            // push set the leaf's end; only pop the slot `enter` took (`Frame.finishLeaf`).
            *self.view.depth = (*self.view.depth).max(2) - 1;
            i
        }
    }
    pub fn text(&mut self, s: &str, ts: &TextStyle) -> u32 {
        unsafe { sys::lcgf_frame_text(self.f, s.as_ptr(), s.len(), c(ts)) }
    }
    pub fn text_styled(&mut self, s: &str, ts: &TextStyle, st: &Style) -> u32 {
        unsafe { sys::lcgf_frame_text_styled(self.f, s.as_ptr(), s.len(), c(ts), c(st)) }
    }
    /// A node the host draws itself: its rect comes back in the draw list's customs.
    #[inline(always)]
    pub fn custom(&mut self, id: Id, s: &Style, data: u64) -> u32 {
        self.custom_row(id, &Row::from(s), data)
    }
    #[inline(always)]
    pub fn custom_row(&mut self, id: Id, r: &Row, data: u64) -> u32 {
        unsafe { sys::lcgf_frame_custom_row(self.f, id.0, c(r), data) }
    }
    /// A node that draws `o.ranges` of `c` under `o.camera` (`Frame.canvas`); needs
    /// [`Context::enable_canvas`]. `u32::MAX` past the limits' customs. The draw list reads
    /// `c` and what `o` borrows, so both stay borrowed until it is dropped.
    pub fn canvas(
        &mut self,
        id: Id,
        s: &Style,
        c: &'f crate::canvas::Canvas<'_>,
        o: &crate::canvas::Options<'f>,
    ) -> u32 {
        let raw = o.raw();
        unsafe { sys::lcgf_frame_canvas(self.f, id.0, c_(s), c.raw().cast(), c_(&raw)) }
    }
    /// A value that eases toward `target` on a spring keyed by `id` (`Frame.animate`): an
    /// `f32`, or anything [`Animatable`] (a [`Color`], an array, a tuple, a type of yours),
    /// each number on its own spring keyed `id.with(k)`, as in Zig.
    pub fn animate<T: Animatable>(&mut self, id: Id, target: T) -> T {
        self.animate_with(id, target, Spring::default())
    }
    pub fn animate_with<T: Animatable>(&mut self, id: Id, target: T, sp: Spring) -> T {
        let f = self.f;
        each(id, target, |id, x| unsafe {
            sys::lcgf_frame_animate(f, id.0, x, c(&sp))
        })
    }
    /// A value that moves to `target` over `seconds` along `ease` (`Frame.tween`), keyed as
    /// `animate` keys.
    pub fn tween<T: Animatable>(&mut self, id: Id, target: T, seconds: f32, ease: Ease) -> T {
        let f = self.f;
        each(id, target, |id, x| unsafe {
            sys::lcgf_frame_tween(f, id.0, x, seconds, ease as u32)
        })
    }
    /// Text of `args` (`format_args!`) written straight into the frame's strings: no buffer of
    /// yours, cut where the strings end. `lcgf::text!(f, &ts, "Gain {:.1}", g)` writes it.
    pub fn text_fmt(&mut self, ts: &TextStyle, args: core::fmt::Arguments<'_>) -> u32 {
        let n = self.write_room(args);
        unsafe { sys::lcgf_frame_text_written(self.f, n, c(ts)) }
    }
    /// `label` of `args`, written as `text_fmt` writes: `lcgf::label!(f, "Gain {:.1}", g)`.
    pub fn label_fmt(&mut self, args: core::fmt::Arguments<'_>) -> u32 {
        let n = self.write_room(args);
        unsafe { sys::lcgf_frame_text_written(self.f, n, c(self.label)) }
    }
    fn write_room(&mut self, args: core::fmt::Arguments<'_>) -> usize {
        struct Room {
            p: *mut u8,
            cap: usize,
            len: usize,
            want: usize,
        }
        impl core::fmt::Write for Room {
            fn write_str(&mut self, s: &str) -> core::fmt::Result {
                let n = s.len().min(self.cap - self.len);
                // SAFETY: `p` is the frame's free strings, `cap` bytes (`lcgf_frame_room`).
                unsafe { core::ptr::copy_nonoverlapping(s.as_ptr(), self.p.add(self.len), n) };
                self.len += n;
                self.want += s.len();
                Ok(())
            }
        }
        let mut cap = 0usize;
        let p = unsafe { sys::lcgf_frame_room(self.f, &mut cap) };
        let mut room = Room {
            p,
            cap,
            len: 0,
            want: 0,
        };
        let _ = core::fmt::write(&mut room, args);
        // What did not fit is reported as the library reports a cut string.
        room.want
    }
}

/// `f.label_fmt(format_args!(...))`: `lcgf::label!(f, "Gain {:.1} dB", gain)`.
#[macro_export]
macro_rules! label {
    ($f:expr, $($arg:tt)*) => { $f.label_fmt(core::format_args!($($arg)*)) };
}

/// `f.text_fmt(ts, format_args!(...))`: `lcgf::text!(f, &ts, "{} items", n)`.
#[macro_export]
macro_rules! text {
    ($f:expr, $ts:expr, $($arg:tt)*) => { $f.text_fmt($ts, core::format_args!($($arg)*)) };
}

/// A colour by channel, to animate one: `Color::from(rgb(..))`, back with `rgba()`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const fn from(v: u32) -> Self {
        Self {
            r: v as u8,
            g: (v >> 8) as u8,
            b: (v >> 16) as u8,
            a: (v >> 24) as u8,
        }
    }
    pub const fn rgba(self) -> u32 {
        self.r as u32 | (self.g as u32) << 8 | (self.b as u32) << 16 | (self.a as u32) << 24
    }
}

/// What `animate` and `tween` move (src/anim/values.zig): a value's numbers, in order. An
/// integer comes back rounded half away from zero and clamped to its type. Implement it for a
/// type of yours with its numbers' count, `put` and `take`.
pub trait Animatable: Copy {
    const N: usize;
    /// Keyed by the id itself rather than `id.with(0)`: an `f32` only, as in Zig.
    const SELF_KEYED: bool = false;
    /// The value's numbers into `out[..N]`.
    fn put(&self, out: &mut [f32]);
    /// A value from `x[..N]`.
    fn take(x: &[f32]) -> Self;
}

impl Animatable for f32 {
    const N: usize = 1;
    const SELF_KEYED: bool = true;
    fn put(&self, out: &mut [f32]) {
        out[0] = *self;
    }
    fn take(x: &[f32]) -> Self {
        x[0]
    }
}

macro_rules! animatable_int {
    ($($t:ty),*) => {$(
        impl Animatable for $t {
            const N: usize = 1;
            fn put(&self, out: &mut [f32]) {
                out[0] = *self as f32;
            }
            fn take(x: &[f32]) -> Self {
                // Zig's `values.intOf`: rounded half away from zero, clamped, NaN to 0.
                unsafe { sys::lcgf_values_int_of(x[0], <$t>::MIN as i64, <$t>::MAX as i64) as $t }
            }
        }
    )*};
}
animatable_int!(u8, u16, u32, i8, i16, i32);

impl Animatable for Color {
    const N: usize = 4;
    fn put(&self, out: &mut [f32]) {
        out[..4].copy_from_slice(&[self.r as f32, self.g as f32, self.b as f32, self.a as f32]);
    }
    fn take(x: &[f32]) -> Self {
        Self {
            r: u8::take(&x[0..]),
            g: u8::take(&x[1..]),
            b: u8::take(&x[2..]),
            a: u8::take(&x[3..]),
        }
    }
}

impl<T: Animatable, const M: usize> Animatable for [T; M] {
    const N: usize = M * T::N;
    fn put(&self, out: &mut [f32]) {
        for (i, v) in self.iter().enumerate() {
            v.put(&mut out[i * T::N..]);
        }
    }
    fn take(x: &[f32]) -> Self {
        core::array::from_fn(|i| T::take(&x[i * T::N..]))
    }
}

impl<A: Animatable, B: Animatable> Animatable for (A, B) {
    const N: usize = A::N + B::N;
    fn put(&self, out: &mut [f32]) {
        self.0.put(out);
        self.1.put(&mut out[A::N..]);
    }
    fn take(x: &[f32]) -> Self {
        (A::take(x), B::take(&x[A::N..]))
    }
}

/// The numbers of a value moved one by one, an f32 keyed `id`, the k-th of anything else
/// `id.with(k)`; at most 64 numbers.
fn each<T: Animatable>(id: Id, target: T, mut one: impl FnMut(Id, f32) -> f32) -> T {
    assert!(T::N <= 64, "lcgf: animate takes at most 64 numbers");
    let mut want = [0f32; 64];
    let mut got = [0f32; 64];
    target.put(&mut want);
    if T::SELF_KEYED {
        got[0] = one(id, want[0]);
    } else {
        for k in 0..T::N {
            got[k] = one(id.with(k as u32), want[k]);
        }
    }
    T::take(&got[..T::N])
}

pub fn label(f: &mut Frame<'_>, s: &str) -> u32 {
    unsafe { sys::lcgf_label(f.f, c(f.theme), s.as_ptr(), s.len()) }
}
pub fn button(f: &mut Frame<'_>, id: Id, s: &str) -> Response {
    Response(unsafe { sys::lcgf_button(f.f, c(f.theme), id.0, s.as_ptr(), s.len()) })
}
pub fn checkbox(f: &mut Frame<'_>, id: Id, value: &mut bool, s: &str) -> Response {
    Response(unsafe { sys::lcgf_checkbox(f.f, c(f.theme), id.0, value, s.as_ptr(), s.len()) })
}
pub fn slider(f: &mut Frame<'_>, id: Id, value: &mut f32, lo: f32, hi: f32) -> Response {
    Response(unsafe { sys::lcgf_slider(f.f, c(f.theme), id.0, value, lo, hi) })
}

/// A button's options: `ButtonOptions { label: "Save" }`.
#[derive(Clone, Copy, Debug, Default)]
pub struct ButtonOptions<'s> {
    pub label: &'s str,
}

/// A checkbox's options: `CheckboxOptions { label: "Mute" }`.
#[derive(Clone, Copy, Debug, Default)]
pub struct CheckboxOptions<'s> {
    pub label: &'s str,
}

/// A slider's range: `SliderOptions { max: 4.0, ..Default::default() }`.
#[derive(Clone, Copy, Debug)]
pub struct SliderOptions {
    pub min: f32,
    pub max: f32,
}

impl Default for SliderOptions {
    fn default() -> Self {
        Self { min: 0.0, max: 1.0 }
    }
}

/// The reference widgets over one frame, options by name (Zig's `widgets.on(f, th)`; the
/// library holds the theme): `let mut ui = f.kit(); ui.slider(Id::from("gain"), &mut gain,
/// SliderOptions { max: 4.0, ..Default::default() });`. The free functions above stay.
pub struct Kit<'f, 'a> {
    pub f: &'f mut Frame<'a>,
}

impl<'a> Frame<'a> {
    pub fn kit(&mut self) -> Kit<'_, 'a> {
        Kit { f: self }
    }
}

impl Kit<'_, '_> {
    pub fn label(&mut self, s: &str) -> u32 {
        label(self.f, s)
    }
    pub fn button(&mut self, id: Id, o: ButtonOptions<'_>) -> Response {
        button(self.f, id, o.label)
    }
    pub fn checkbox(&mut self, id: Id, value: &mut bool, o: CheckboxOptions<'_>) -> Response {
        checkbox(self.f, id, value, o.label)
    }
    pub fn slider(&mut self, id: Id, value: &mut f32, o: SliderOptions) -> Response {
        slider(self.f, id, value, o.min, o.max)
    }
    /// `label` of formatted text: `ui.text(format_args!("Gain {:.1}", g))`.
    pub fn text(&mut self, args: core::fmt::Arguments<'_>) -> u32 {
        self.f.label_fmt(args)
    }
}
