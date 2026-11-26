//! LCGF from Rust.
//!
//! A UI is a spec. `ui!` takes it inline and `include_ui!` takes it from a `.zon` file. At
//! compile time the macro runs `lcgf-gen`, which runs the same `plan` the Zig compiler runs, and
//! expands to a module with the tables, the `State` struct, the `Widget` enum and a `Ui` with one
//! setter per field. A frame is one call through the C seam (`lcgf.h`) into the prebuilt liblcgf.
//! Its draw list is read in place, as slices over its columns. Nothing allocates, nothing is
//! dispatched at run time, and the caller owns every byte.
//!
//! ```ignore
//! lcgf::ui! {
//!     state Mixer { title: &'static str = "Mixer", muted: bool = false, volume: f32 = 0.5 }
//!     col(pad: 8, gap: 4) {
//!         label(title)
//!         checkbox(id: mute, bind: muted, text: title)
//!         slider(id: volume, bind: volume)
//!     }
//! }
//! let mut buf = Box::new(lcgf::Buffer::<{ mixer::BYTES }>::new());
//! let mut ui = mixer::Ui::new(&mut buf)?;
//! ui.set_volume(0.8);
//! let frame = ui.frame(&input);
//! for q in frame.draw.quads() { /* &[Quad] */ }
//! if frame.events.clicked(mixer::Widget::Mute) { /* ... */ }
//! ```

#![no_std]

pub use lcgf_macros::{include_shader, include_ui, ui};

pub mod ct;
pub mod gpu;
pub mod runtime;

use core::marker::PhantomData;

/// Alignment of the UI's buffer.
pub const COLUMN_ALIGN: usize = 64;
const NO_WIDGET: u32 = 0xffff_ffff;

/// Why the tables or the buffer were refused (`lcgf_ui_init`).
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    NotTables = 1,
    Version = 2,
    LayoutHash = 3,
    Truncated = 4,
    BufferTooSmall = 5,
    Unaligned = 6,
}

/// A string field: a pointer and a length, as the tables lay it out. It borrows `'static`
/// bytes, so a frame can never outlive what it shows.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Str {
    ptr: *const u8,
    len: usize,
}

impl Str {
    pub const fn new(s: &'static str) -> Self {
        Self {
            ptr: s.as_ptr(),
            len: s.len(),
        }
    }
    pub fn as_str(&self) -> &'static str {
        // SAFETY: built only from a `&'static str`.
        unsafe { core::str::from_utf8_unchecked(core::slice::from_raw_parts(self.ptr, self.len)) }
    }
}

impl From<&'static str> for Str {
    fn from(s: &'static str) -> Self {
        Self::new(s)
    }
}

/// What the host tells a frame (`lcgf_input`).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Input {
    pub viewport: [f32; 2],
    /// Logical pixels; `[-1, -1]` outside the window.
    pub pointer: [f32; 2],
    pub dt: f32,
    pub scale: f32,
    /// `Input::LEFT`, `RIGHT`, `MIDDLE`.
    pub buttons: u32,
    /// `Input::SHIFT`, `CTRL`, `ALT`, `CMD`.
    pub mods: u32,
    /// This frame's keys, in order (`Input::keys`); Tab moves focus.
    pub events: *const KeyEvent,
    pub events_len: u32,
}

/// A key event (`lcgf_key_event`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct KeyEvent {
    /// 0 press, 1 release, 2 repeat, 3 text.
    pub kind: u8,
    pub mods: u8,
    pub code: u8,
    pub pad: u8,
    pub at: u32,
    pub len: u32,
}

impl Input {
    pub const LEFT: u32 = 1;
    pub const RIGHT: u32 = 2;
    pub const MIDDLE: u32 = 4;
    pub const SHIFT: u32 = 1;
    pub const CTRL: u32 = 2;
    pub const ALT: u32 = 4;
    pub const CMD: u32 = 8;
    pub const TAB: u8 = 0x2b;

    /// This frame's key events; they must outlive the frame.
    pub fn keys(mut self, events: &[KeyEvent]) -> Self {
        self.events = events.as_ptr();
        self.events_len = events.len() as u32;
        self
    }

    /// The key events `keys` set.
    pub fn key_events(&self) -> &[KeyEvent] {
        if self.events_len == 0 {
            &[]
        } else {
            // SAFETY: set from a slice by `keys`, which must outlive the frame.
            unsafe { core::slice::from_raw_parts(self.events, self.events_len as usize) }
        }
    }
}

impl Default for Input {
    fn default() -> Self {
        Self {
            viewport: [800.0, 600.0],
            pointer: [-1.0, -1.0],
            dt: 1.0 / 60.0,
            scale: 1.0,
            buttons: 0,
            mods: 0,
            events: core::ptr::null(),
            events_len: 0,
        }
    }
}

/// One instanced quad (`lcgf_quad`): rounded box, clip, fill, border.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quad {
    pub rect: [f32; 4],
    pub clip: [f32; 4],
    pub params: [f32; 4],
    pub uv: [f32; 4],
    pub radii: [f32; 4],
    pub fill: u32,
    pub border_color: u32,
    pub border: f32,
    pub opacity: f32,
    pub xform: [f32; 6],
    pub clip_radii: [f32; 4],
}

/// One run of text (`lcgf_text_run`); its bytes are `DrawList::text(run)`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextRun {
    pub rect: [f32; 4],
    pub clip: [f32; 4],
    pub start: u32,
    pub bytes: u32,
    pub px: f32,
    pub color: u32,
    pub font: u32,
    pub opacity: f32,
    pub xform: [f32; 6],
    pub clip_radii: [f32; 4],
}

/// A rectangle the host draws itself (`lcgf_custom_draw`).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CustomDraw {
    pub rect: [f32; 4],
    pub clip: [f32; 4],
    pub data: u64,
    pub id: u32,
    pub node: u32,
    pub xform: [f32; 6],
    pub clip_radii: [f32; 4],
    pub opacity: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct RawDraw {
    quads: *const Quad,
    quad_len: u32,
    run_len: u32,
    runs: *const TextRun,
    strings: *const u8,
    strings_len: usize,
    cmd_kind: *const u8,
    cmd_first: *const u32,
    cmd_count: *const u32,
    cmd_key: *const u32,
    cmd_len: u32,
    custom_len: u32,
    customs: *const CustomDraw,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub(crate) struct RawFrame {
    draw: RawDraw,
    widget: u32,
    value: f32,
    focus: u32,
    wake: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum CmdKind {
    Quads = 0,
    Text = 1,
    Custom = 2,
}

/// One draw command: a batch of quads sharing a texture and material (`key`), a text run, or a
/// custom draw.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Command {
    pub kind: CmdKind,
    pub first: u32,
    pub count: u32,
    pub key: u32,
}

/// A frame's draw list, read in place. It borrows the UI, so it cannot outlive the next frame.
#[derive(Clone, Copy)]
pub struct DrawList<'a> {
    raw: RawDraw,
    _ui: PhantomData<&'a ()>,
}

unsafe fn slice<'a, T>(p: *const T, n: u32) -> &'a [T] {
    if n == 0 {
        &[]
    } else {
        unsafe { core::slice::from_raw_parts(p, n as usize) }
    }
}

impl<'a> DrawList<'a> {
    pub fn quads(&self) -> &'a [Quad] {
        unsafe { slice(self.raw.quads, self.raw.quad_len) }
    }
    pub fn runs(&self) -> &'a [TextRun] {
        unsafe { slice(self.raw.runs, self.raw.run_len) }
    }
    pub fn customs(&self) -> &'a [CustomDraw] {
        unsafe { slice(self.raw.customs, self.raw.custom_len) }
    }
    pub fn strings(&self) -> &'a [u8] {
        if self.raw.strings_len == 0 {
            &[]
        } else {
            unsafe { core::slice::from_raw_parts(self.raw.strings, self.raw.strings_len) }
        }
    }
    pub fn text(&self, r: &TextRun) -> &'a [u8] {
        &self.strings()[r.start as usize..][..r.bytes as usize]
    }
    pub fn command_count(&self) -> u32 {
        self.raw.cmd_len
    }
    pub fn command(&self, i: u32) -> Command {
        assert!(i < self.raw.cmd_len);
        let i = i as usize;
        unsafe {
            Command {
                kind: core::mem::transmute::<u8, CmdKind>(*self.raw.cmd_kind.add(i)),
                first: *self.raw.cmd_first.add(i),
                count: *self.raw.cmd_count.add(i),
                key: *self.raw.cmd_key.add(i),
            }
        }
    }
}

/// The generated `Widget` enums: a widget's slot in widget order.
pub trait WidgetEnum: Copy {
    fn slot(self) -> u32;
}

/// What the pointer did this frame.
#[derive(Clone, Copy)]
pub struct Events<W> {
    widget: u32,
    value: f32,
    focus: u32,
    wake: f32,
    _w: PhantomData<W>,
}

impl<W: WidgetEnum> Events<W> {
    /// The widget was clicked: a button, or a checkbox (already toggled in the state).
    pub fn clicked(&self, w: W) -> bool {
        self.widget == w.slot()
    }
    /// A slider's new value (already written to the state), while it is dragged.
    pub fn slid(&self, w: W) -> Option<f32> {
        (self.widget == w.slot()).then_some(self.value)
    }
    /// The slot of the widget with an event, if any.
    pub fn slot(&self) -> Option<u32> {
        (self.widget != NO_WIDGET).then_some(self.widget)
    }
    /// The slot of the widget keyboard focus is on (Tab moves it), if any.
    pub fn focus_slot(&self) -> Option<u32> {
        (self.focus != NO_WIDGET).then_some(self.focus)
    }
    /// Seconds until the UI needs a frame though nothing happened: 0 while a spring moves.
    pub fn wake(&self) -> f32 {
        self.wake
    }
}

/// One frame's output: the draw list and the events, both borrowing the UI.
pub struct Frame<'a, W> {
    pub draw: DrawList<'a>,
    pub events: Events<W>,
}

/// An aligned buffer of exactly `N` bytes, for a generated module's `BYTES`.
#[repr(C, align(64))]
pub struct Buffer<const N: usize>([u8; N]);

impl<const N: usize> Buffer<N> {
    pub const fn new() -> Self {
        Self([0; N])
    }
    pub fn bytes(&mut self) -> &mut [u8] {
        &mut self.0
    }
}

impl<const N: usize> Default for Buffer<N> {
    fn default() -> Self {
        Self::new()
    }
}

/// A generated module's tables, aligned for the reader.
#[repr(C, align(4))]
pub struct Tables<const N: usize>(pub [u32; N]);

/// A static UI's tables (lcgf-gen --static), aligned as the frame reads them in place.
#[repr(C, align(64))]
pub struct StaticTables<const N: usize>(pub [u32; N]);

unsafe extern "C" {
    fn lcgf_ct_init(tables: *const u32, len: usize, buf: *mut u8, buf_len: usize) -> i32;
    #[cfg_attr(lcgf_lanes = "4", link_name = "lcgf_ct_frame_u32_f32_l4")]
    #[cfg_attr(lcgf_lanes = "8", link_name = "lcgf_ct_frame_u32_f32_l8")]
    #[cfg_attr(lcgf_lanes = "16", link_name = "lcgf_ct_frame_u32_f32_l16")]
    #[cfg_attr(lcgf_lanes = "auto", link_name = "lcgf_ct_frame_u32_f32_auto")]
    fn lcgf_ct_frame(ui: *mut u8, state: *const u8, width: f32, height: f32, out: *mut RawDraw);
    pub fn lcgf_ct_layout() -> u32;
}

/// A static UI (lcgf-gen --static): the comptime pipeline over its tables, in the caller's
/// buffer. The generated `Ui` wraps it and adds a setter per field. A frame reads only the
/// labels' text from the state.
pub struct StaticUi<'a, S> {
    pub state: S,
    buf: &'a mut [u8],
}

impl<'a, S> StaticUi<'a, S> {
    /// Checks the tables once and places the UI at the start of `buf`.
    pub fn new(tables: &[u32], buf: &'a mut [u8], state: S) -> Result<Self, Status> {
        let r = unsafe { lcgf_ct_init(tables.as_ptr(), tables.len(), buf.as_mut_ptr(), buf.len()) };
        if r != 0 {
            // SAFETY: lcgf_ct_init returns 0 or one of Status's values.
            return Err(unsafe { core::mem::transmute::<i32, Status>(r) });
        }
        Ok(Self { state, buf })
    }

    /// One frame in a `width` x `height` viewport.
    pub fn frame(&mut self, width: f32, height: f32) -> DrawList<'_> {
        let mut out = core::mem::MaybeUninit::<RawDraw>::uninit();
        let raw = unsafe {
            lcgf_ct_frame(
                self.buf.as_mut_ptr(),
                (&self.state as *const S).cast(),
                width,
                height,
                out.as_mut_ptr(),
            );
            out.assume_init()
        };
        DrawList {
            raw,
            _ui: PhantomData,
        }
    }
}

unsafe extern "C" {
    fn lcgf_ui_init(tables: *const u32, len: usize, buf: *mut u8, buf_len: usize) -> i32;
    #[cfg_attr(lcgf_lanes = "4", link_name = "lcgf_frame_u32_f32_l4")]
    #[cfg_attr(lcgf_lanes = "8", link_name = "lcgf_frame_u32_f32_l8")]
    #[cfg_attr(lcgf_lanes = "16", link_name = "lcgf_frame_u32_f32_l16")]
    #[cfg_attr(lcgf_lanes = "auto", link_name = "lcgf_frame_u32_f32_auto")]
    fn lcgf_frame(ui: *mut u8, state: *mut u8, input: *const Input, out: *mut RawFrame);
    pub fn lcgf_layout_hash() -> u32;
}

/// A UI over its tables, in the caller's buffer. The generated `Ui` wraps it and adds a setter
/// per field.
pub struct Ui<'a, S, W> {
    pub state: S,
    buf: &'a mut [u8],
    _w: PhantomData<W>,
}

impl<'a, S, W: WidgetEnum> Ui<'a, S, W> {
    /// Checks the tables once and places the UI at the start of `buf`.
    pub fn new(tables: &[u32], buf: &'a mut [u8], state: S) -> Result<Self, Status> {
        let r = unsafe { lcgf_ui_init(tables.as_ptr(), tables.len(), buf.as_mut_ptr(), buf.len()) };
        if r != 0 {
            // SAFETY: lcgf_ui_init returns 0 or one of Status's values.
            return Err(unsafe { core::mem::transmute::<i32, Status>(r) });
        }
        Ok(Self {
            state,
            buf,
            _w: PhantomData,
        })
    }

    /// One frame: the pointer's event applied to the state, then built, laid out and painted.
    pub fn frame(&mut self, input: &Input) -> Frame<'_, W> {
        let mut out = core::mem::MaybeUninit::<RawFrame>::uninit();
        let f = unsafe {
            lcgf_frame(
                self.buf.as_mut_ptr(),
                (&mut self.state as *mut S).cast(),
                input,
                out.as_mut_ptr(),
            );
            out.assume_init()
        };
        Frame {
            draw: DrawList {
                raw: f.draw,
                _ui: PhantomData,
            },
            events: Events {
                widget: f.widget,
                value: f.value,
                focus: f.focus,
                wake: f.wake,
                _w: PhantomData,
            },
        }
    }
}

const _: () = assert!(core::mem::size_of::<Quad>() == 136 && core::mem::size_of::<TextRun>() == 96);
