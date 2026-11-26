//! The canvas batch (lcgf.h `lcgf_canvas_*`, Zig's `lcgf.canvas.Instances`): many 2D
//! primitives in your buffer, filled once or when they change, drawn each frame by
//! [`Frame::canvas`](crate::runtime::Frame::canvas) under a camera. Points are `i32` world
//! units; a `width` of 0 is the layer's, in logical pixels.

use crate::sys;
use core::marker::PhantomData;

/// How a segment or an arc ends.
#[repr(u8)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Cap {
    #[default]
    Butt,
    Square,
    Round,
}

/// Segments and polylines. `dash` n is 2n logical px on, 2n off, along the chain.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Line {
    pub layer: u8,
    pub weight: u8,
    pub cap: Cap,
    pub dash: u8,
    pub width: u32,
}
impl Default for Line {
    fn default() -> Self {
        Self {
            layer: 0,
            weight: 1,
            cap: Cap::Butt,
            dash: 0,
            width: 0,
        }
    }
}

/// Rects and circles.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Rect {
    pub layer: u8,
    pub weight: u8,
    pub fill: bool,
    pub stroke: bool,
    pub radius: u32,
    pub width: u32,
}
impl Default for Rect {
    fn default() -> Self {
        Self {
            layer: 0,
            weight: 1,
            fill: true,
            stroke: true,
            radius: 0,
            width: 0,
        }
    }
}

/// Arcs: from `start` through `sweep` radians (negative runs the other way).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Arc {
    pub layer: u8,
    pub weight: u8,
    pub cap: Cap,
    pub dash: u8,
    pub start: f32,
    pub sweep: f32,
    pub width: u32,
}
impl Default for Arc {
    fn default() -> Self {
        Self {
            layer: 0,
            weight: 1,
            cap: Cap::Butt,
            dash: 0,
            start: 0.0,
            sweep: core::f32::consts::TAU,
            width: 0,
        }
    }
}

/// Polygons, filled by the nonzero rule.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Area {
    pub layer: u8,
    pub weight: u8,
    pub fill: bool,
    pub stroke: bool,
    pub width: u32,
}
impl Default for Area {
    fn default() -> Self {
        Self {
            layer: 0,
            weight: 1,
            fill: true,
            stroke: false,
            width: 0,
        }
    }
}

/// A line of monospaced glyphs, `px` world units tall, turned `turns` quarter turns.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Text {
    pub px: u32,
    pub layer: u8,
    pub turns: u8,
    pub pad: [u8; 2],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Range {
    pub first: u32,
    pub count: u32,
}

/// Rows of `range` drawn in `color` (rgba8) instead of their layer's; the last match wins.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Override {
    pub range: Range,
    pub color: u32,
}

/// One palette row: stroke and fill (rgba8), width at weight 1 (logical px), flags (bit 0
/// fills drawn, bit 1 visible).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Layer {
    pub stroke: u32,
    pub fill: u32,
    pub width: f32,
    pub flags: u32,
}

/// World point `origin` drawn `offset` logical px from the node's corner, `scale` px a unit.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Camera {
    pub origin: [i64; 2],
    pub scale: f32,
    pub offset: [f32; 2],
    pub zoom: f32,
}
impl Default for Camera {
    fn default() -> Self {
        Self {
            origin: [0, 0],
            scale: 1.0,
            offset: [0.0, 0.0],
            zoom: 1.0,
        }
    }
}

/// What a canvas node draws.
#[derive(Clone, Copy, Debug, Default)]
pub struct Options<'a> {
    pub camera: Camera,
    pub layers: &'a [Layer],
    pub zoom_scale: bool,
    pub ranges: &'a [Range],
    pub overrides: &'a [Override],
}

#[repr(C)]
pub(crate) struct RawOptions {
    camera: Camera,
    layers: *const Layer,
    layers_len: usize,
    zoom_scale: u32,
    ranges: *const Range,
    ranges_len: usize,
    overrides: *const Override,
    overrides_len: usize,
}

impl Options<'_> {
    pub(crate) fn raw(&self) -> RawOptions {
        RawOptions {
            camera: self.camera,
            layers: self.layers.as_ptr(),
            layers_len: self.layers.len(),
            zoom_scale: self.zoom_scale as u32,
            ranges: self.ranges.as_ptr(),
            ranges_len: self.ranges.len(),
            overrides: self.overrides.as_ptr(),
            overrides_len: self.overrides.len(),
        }
    }
}

pub(crate) type Raw = *mut sys::lcgf_canvas;

/// A range as the library returns it.
fn range(r: sys::lcgf_canvas_range) -> Range {
    Range {
        first: r.first,
        count: r.count,
    }
}

/// The crate's option types are laid out as lcgf.h's (checked below).
fn c<T, U>(p: &T) -> *const U {
    (p as *const T).cast()
}

const _: () = {
    use core::mem::size_of;
    assert!(size_of::<Line>() == size_of::<sys::lcgf_canvas_line_style>());
    assert!(size_of::<Rect>() == size_of::<sys::lcgf_canvas_box_style>());
    assert!(size_of::<Arc>() == size_of::<sys::lcgf_canvas_arc_style>());
    assert!(size_of::<Area>() == size_of::<sys::lcgf_canvas_area_style>());
    assert!(size_of::<Text>() == size_of::<sys::lcgf_canvas_text_style>());
    assert!(size_of::<RawOptions>() == size_of::<sys::lcgf_canvas_options>());
};

/// A batch in your buffer.
pub struct Canvas<'a> {
    c: Raw,
    _buf: PhantomData<&'a mut [u8]>,
}

impl<'a> Canvas<'a> {
    /// Bytes a batch of `rows` rows, `verts` polygon vertices and `dirty` dirty ranges needs,
    /// with a mark a row when `marks`, aligned to `COLUMN_ALIGN`.
    pub fn bytes(rows: u32, verts: u32, dirty: u32, marks: bool) -> usize {
        unsafe { sys::lcgf_canvas_bytes(rows, verts, dirty, marks as i32) }
    }
    /// None when `buf` is too small or not aligned to `COLUMN_ALIGN`.
    pub fn new(buf: &'a mut [u8], rows: u32, verts: u32, dirty: u32, marks: bool) -> Option<Self> {
        let c = unsafe {
            sys::lcgf_canvas_init(
                buf.as_mut_ptr().cast(),
                buf.len(),
                rows,
                verts,
                dirty,
                marks as i32,
            )
        };
        (!c.is_null()).then_some(Self {
            c,
            _buf: PhantomData,
        })
    }
    pub fn len(&self) -> u32 {
        unsafe { sys::lcgf_canvas_len(self.c) }
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
    pub fn segment(&mut self, a: [i32; 2], b: [i32; 2], o: &Line) -> u32 {
        unsafe { sys::lcgf_canvas_segment(self.c, a[0], a[1], b[0], b[1], c(o)) }
    }
    pub fn polyline(&mut self, points: &[[i32; 2]], o: &Line) -> Range {
        range(unsafe { sys::lcgf_canvas_polyline(self.c, points.as_ptr(), points.len(), c(o)) })
    }
    pub fn rect(&mut self, lo: [i32; 2], hi: [i32; 2], o: &Rect) -> u32 {
        unsafe { sys::lcgf_canvas_rect(self.c, lo[0], lo[1], hi[0], hi[1], c(o)) }
    }
    pub fn circle(&mut self, at: [i32; 2], r: u32, o: &Rect) -> u32 {
        unsafe { sys::lcgf_canvas_circle(self.c, at[0], at[1], r, c(o)) }
    }
    pub fn arc(&mut self, at: [i32; 2], r: u32, o: &Arc) -> u32 {
        unsafe { sys::lcgf_canvas_arc(self.c, at[0], at[1], r, c(o)) }
    }
    pub fn polygon(&mut self, points: &[[i32; 2]], o: &Area) -> u32 {
        unsafe { sys::lcgf_canvas_polygon(self.c, points.as_ptr(), points.len(), c(o)) }
    }
    pub fn glyph(
        &mut self,
        anchor: [i32; 2],
        size: [u32; 2],
        uv: [f32; 4],
        layer: u8,
        turns: u8,
    ) -> u32 {
        unsafe {
            sys::lcgf_canvas_glyph(
                self.c, anchor[0], anchor[1], size[0], size[1], &uv, layer, turns,
            )
        }
    }
    pub fn glyphs(&mut self, s: &str, at: [i32; 2], o: &Text) -> Range {
        range(unsafe { sys::lcgf_canvas_glyphs(self.c, s.as_ptr(), s.len(), at[0], at[1], c(o)) })
    }
    pub fn kill(&mut self, row: u32) {
        unsafe { sys::lcgf_canvas_kill(self.c, row) }
    }
    /// Row `row` in `color` (rgba8) over its layer and any override; 0 for none. Needs `marks`.
    pub fn mark(&mut self, row: u32, color: u32) {
        unsafe { sys::lcgf_canvas_mark(self.c, row, color) }
    }
    pub fn reset(&mut self) {
        unsafe { sys::lcgf_canvas_reset(self.c) }
    }
    /// Once every renderer that draws the batch has prepared its frame.
    pub fn clear_dirty(&mut self) {
        unsafe { sys::lcgf_canvas_clear_dirty(self.c) }
    }
    /// The topmost row within `slop` logical px of (x, y), from the node's corner.
    pub fn hit(&self, o: &Options<'_>, x: f32, y: f32, slop: f32) -> Option<u32> {
        let raw = o.raw();
        let r = unsafe { sys::lcgf_canvas_hit(self.c, c(&raw), x, y, slop) };
        (r != u32::MAX).then_some(r)
    }
    pub(crate) fn raw(&self) -> Raw {
        self.c
    }
}
