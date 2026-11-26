//! The runtime front end from Rust (`lcgf::runtime`): bench/scenes/' scenes built each frame,
//! their draw lists written in bindings/check/dump.zig's format for run.sh to compare with Zig.
//!
//!   lcgf-rt-check <form|list|text|springs|resize|idle|kit> <frames> <out.bin> [nodes depth]
//!
//! `kit` is the gate's own scene (bindings/check/rt_dump.zig's `Kit`): formatted text, the
//! widgets by options, and springs and tweens on a colour and an array.
//!   lcgf-rt-check rows <in.bin>   (lcgf-rt-dump rows' styles: `Row::from` must equal Zig's rows)

mod scenes;

use lcgf::canvas;
use lcgf::runtime::{Context, Id, Row, Size, Style};
use std::alloc::{Layout, alloc_zeroed, dealloc};

/// An aligned, zeroed buffer that lives as long as the program.
fn leak(n: usize) -> &'static mut [u8] {
    let layout = Layout::from_size_align(n.max(1), lcgf::COLUMN_ALIGN).unwrap();
    unsafe { std::slice::from_raw_parts_mut(alloc_zeroed(layout), n) }
}

/// bindings/check/rt_dump.zig's `Plot`: a canvas batch through `lcgf::canvas`, two canvas nodes.
struct Plot {
    s: canvas::Canvas<'static>,
    all: [canvas::Range; 1],
}

const PLOT_LAYERS: [canvas::Layer; 3] = [
    canvas::Layer { stroke: 0xffe6e6e6, fill: 0, width: 1.0, flags: 3 },
    canvas::Layer { stroke: 0xffffc85a, fill: 0xb4a05a28, width: 1.5, flags: 3 },
    canvas::Layer { stroke: 0xff3c78ff, fill: 0xff3cc8ff, width: 2.0, flags: 2 },
];
const PLOT_MARKS: [canvas::Override; 1] = [canvas::Override { range: canvas::Range { first: 2, count: 3 }, color: 0xff00ff80 }];
const PLOT_SUB: [canvas::Range; 1] = [canvas::Range { first: 1, count: 4 }];

impl Plot {
    fn new() -> Self {
        use canvas::*;
        let mut s = Canvas::new(leak(Canvas::bytes(32, 16, 8)), 32, 16, 8).expect("canvas");
        for i in 0..8u32 {
            let x = (i * 100) as i32;
            let cap = [Cap::Butt, Cap::Square, Cap::Round][(i % 3) as usize];
            s.segment([x, 0], [x + 80, (50 * (i % 3)) as i32], &Line { weight: (i % 4 + 1) as u8, cap, dash: ((i % 2) * 2) as u8, ..Default::default() });
        }
        s.polyline(&[[0, 200], [150, 260], [300, 200], [450, 300]], &Line { cap: Cap::Round, dash: 1, ..Default::default() });
        s.rect([500, 0], [700, 150], &Rect { layer: 1, radius: 20, ..Default::default() });
        s.circle([800, 100], 60, &Rect { layer: 2, ..Default::default() });
        s.arc([100, 400], 80, &Arc { layer: 1, cap: Cap::Round, dash: 2, start: 0.5, sweep: 4.0, ..Default::default() });
        s.polygon(&[[300, 350], [500, 380], [420, 500], [350, 450]], &Area { layer: 1, stroke: true, ..Default::default() });
        s.glyphs("Hi", [600, 400], &Text { px: 40, turns: 1, ..Default::default() });
        let all = [Range { first: 0, count: s.len() }];
        Self { s, all }
    }

    fn input(input: &mut lcgf::Input, k: u32) {
        input.viewport = [400.0, 300.0];
        input.pointer = [((k * 17) % 400) as f32 + 0.5, ((k * 11) % 300) as f32 + 0.5];
        input.dt = 1.0 / 60.0;
    }

    fn options<'a>(k: u32, ranges: &'a [canvas::Range], overrides: &'a [canvas::Override]) -> canvas::Options<'a> {
        canvas::Options {
            camera: canvas::Camera { origin: [(k * 7) as i64, -((k * 3) as i64)], scale: 0.5 + 0.25 * (k % 4) as f32, offset: [10.0, 10.0], zoom: (1 + k % 3) as f32 },
            layers: &PLOT_LAYERS,
            zoom_scale: k % 2 == 1,
            ranges,
            overrides,
        }
    }

    fn build(&mut self, f: &mut lcgf::runtime::Frame<'_>, k: u32) {
        if k % 10 == 9 {
            let n = self.s.len();
            self.s.kill((k / 10) % n);
        }
        f.open(Id::from("plot-root"), &Style { size: [Size::FILL, Size::FILL], ..Style::DEFAULT });
        // SAFETY: the batch and everything the options borrow live until the program ends.
        unsafe {
            f.canvas(Id::from("plot"), &Style { size: [Size::FILL, Size::FILL], ..Style::DEFAULT }, &self.s, &Self::options(k, &self.all, &PLOT_MARKS));
            f.canvas(Id::from("overlay"), &Style { size: [Size::px(120.0), Size::px(80.0)], floating: 1, ..Style::DEFAULT }, &self.s, &Self::options(k, &PLOT_SUB, &[]));
        }
        f.close();
    }
}

/// bindings/check/rt_dump.zig's `Kit`, in this crate's words.
struct Kit {
    on: bool,
    gain: f32,
}

impl Kit {
    fn input(input: &mut lcgf::Input, k: u32) {
        input.viewport = [400.0, 300.0];
        input.pointer = [((k * 13) % 400) as f32 + 0.5, ((k * 7) % 120) as f32 + 0.5];
        input.dt = 1.0 / 60.0;
    }

    fn build(&mut self, f: &mut lcgf::runtime::Frame<'_>, k: u32) {
        use lcgf::runtime::{
            ButtonOptions, CheckboxOptions, Color, Ease, Id, SliderOptions, TextStyle, rgb,
        };
        f.open(
            Id::from("kit"),
            &Style {
                pad: [8.0; 4],
                gap: 4.0,
                ..Style::DEFAULT
            },
        );
        lcgf::label!(f, "Frame {}: {:.2}", k, k as f32 * 0.25);
        lcgf::text!(
            f,
            &TextStyle {
                px: 16.0,
                color: rgb(255, 200, 0),
                ..TextStyle::DEFAULT
            },
            "items {}",
            k % 7
        );
        let mut ui = f.kit();
        ui.button(Id::from("save"), ButtonOptions { label: "Save" });
        ui.checkbox(
            Id::from("loud"),
            &mut self.on,
            CheckboxOptions { label: "Loud" },
        );
        ui.slider(
            Id::from("gain"),
            &mut self.gain,
            SliderOptions { min: 0.0, max: 4.0 },
        );
        let phase = (k / 30) % 2 == 0;
        let ink = f.animate(
            Id::from("ink"),
            Color::from(if phase {
                rgb(200, 40, 40)
            } else {
                rgb(40, 40, 200)
            }),
        );
        let bx = f.animate(Id::from("box"), [if phase { 40.0f32 } else { 90.0 }, 12.0]);
        let bar = f.tween(
            Id::from("slide"),
            if (k / 45) % 2 == 0 { 20.0f32 } else { 120.0 },
            0.5,
            Ease::OutCubic,
        );
        f.leaf(
            Id::from("swatch"),
            &Style {
                size: [Size::px(bx[0]), Size::px(bx[1])],
                fill: ink.rgba(),
                ..Style::DEFAULT
            },
        );
        f.leaf(
            Id::from("bar"),
            &Style {
                size: [Size::px(bar), Size::px(6.0)],
                fill: rgb(90, 90, 90),
                ..Style::DEFAULT
            },
        );
        // rt_dump.zig's styled subtree: participation all, hidden (1) and collapsed (0) in turn.
        let part = [15u32, 1, 0][((k / 20) % 3) as usize];
        f.open(
            Id::from("styled"),
            &Style {
                participation: part,
                cursor: 1,
                dir: lcgf::runtime::Dir::X,
                gap: 4.0,
                ..Style::DEFAULT
            },
        );
        let card = f.leaf(
            Id::from("card"),
            &Style {
                size: [Size::px(40.0), Size::px(20.0)],
                fill: rgb(60, 120, 60),
                radii: [2.0, 6.0, 2.0, 6.0],
                ..Style::DEFAULT
            },
        );
        f.leaf(
            Id::from("ring"),
            &Style {
                floating: 1,
                border: 1.0,
                border_color: rgb(240, 240, 240),
                paint_reference: card,
                paint_outset: [2.0; 4],
                ..Style::DEFAULT
            },
        );
        f.leaf(
            Id::from("tilt"),
            &Style {
                size: [Size::px(20.0), Size::px(20.0)],
                fill: rgb(120, 60, 60),
                transform: [1.0, 0.25, 0.0, 1.0, 0.0, 0.0],
                transform_origin: [0.0, 0.0],
                ..Style::DEFAULT
            },
        );
        f.leaf(
            Id::from("plain"),
            &Style {
                size: [Size::px(10.0), Size::px(10.0)],
                fill: rgb(60, 60, 120),
                ..Style::DEFAULT
            },
        );
        f.close();
        f.close();
    }
}

fn bytes<T>(s: &[T]) -> &[u8] {
    unsafe { std::slice::from_raw_parts(s.as_ptr().cast(), std::mem::size_of_val(s)) }
}

// A row made at compile time: the style is folded away, only the row is left in the binary.
const PANEL: Row = Row::from(&Style {
    dir: lcgf::runtime::Dir::X,
    size: [Size::px(120.0), Size::FILL],
    gap: 4.0,
    ..Style::DEFAULT
});
const _: () = assert!(PANEL.min[0] == 120.0 && PANEL.max[0] == 120.0 && PANEL.grow[1] == 1.0);
const _: () = assert!(PANEL.text == u32::MAX && PANEL.own == 0 && PANEL.radii[0] == 0.0);

fn rows(path: &str) {
    let data = std::fs::read(path).expect("read");
    let (sw, rw) = (std::mem::size_of::<Style>(), std::mem::size_of::<Row>());
    assert!(
        !data.is_empty() && data.len() % (sw + rw) == 0,
        "not a row sweep"
    );
    let mut bad = 0;
    let n = data.len() / (sw + rw);
    for (k, pair) in data.chunks_exact(sw + rw).enumerate() {
        let st: Style = unsafe { std::ptr::read_unaligned(pair.as_ptr().cast()) };
        let zig = &pair[sw..];
        let mine = Row::from(&st);
        let mut lib = Row::DEFAULT;
        unsafe { lcgf::runtime::lcgf_row_from_style(&st, &mut lib) };
        if bytes(&[mine]) != zig || bytes(&[lib]) != zig {
            if bad < 5 {
                for (i, (a, z)) in bytes(&[mine]).chunks(4).zip(zig.chunks(4)).enumerate() {
                    if a != z {
                        eprintln!("style {k} word {i}: Rust {a:02x?}, Zig {z:02x?}");
                    }
                }
            }
            bad += 1;
        }
    }
    if bad > 0 {
        eprintln!("{bad} of {n} rows differ");
        std::process::exit(1);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 3 && args[1] == "rows" {
        return rows(&args[2]);
    }
    assert!(
        args.len() == 4 || args.len() == 6,
        "usage: lcgf-rt-check <scene> <frames> <out.bin>"
    );
    let plot_scene = args[1] == "canvas";
    let kit_scene = plot_scene || args[1] == "kit";
    let scene = scenes::NAMES
        .iter()
        .find(|(n, _)| kit_scene || *n == args[1])
        .expect("unknown scene")
        .1;
    let mut kit = Kit {
        on: false,
        gain: 1.0,
    };
    let frames: u32 = args[2].parse().expect("frames");

    // The style the library has for `Style::DEFAULT` must be this crate's: the words are the
    // contract.
    let mut lib = Style::DEFAULT;
    unsafe { lcgf::runtime::lcgf_default_style(&mut lib) };
    assert!(
        bytes(&[lib]) == bytes(&[Style::DEFAULT]),
        "Style::DEFAULT is not the library's default style"
    );

    let mut state = scenes::State::new(scene);
    let mut limits = state.limits();
    if kit_scene {
        (limits.nodes, limits.texts, limits.anims) = (64, 64, 64);
    }
    if args.len() == 6 {
        limits.nodes = args[4].parse().expect("nodes");
        limits.depth = args[5].parse().expect("depth");
    }
    let n = Context::bytes(&limits);
    let layout = Layout::from_size_align(n, lcgf::COLUMN_ALIGN).unwrap();
    let mem = unsafe { std::slice::from_raw_parts_mut(alloc_zeroed(layout), n) };
    let mut out = Vec::new();
    {
        let mut ctx = Context::new(mem, &limits).expect("context");
        let mut plot = None;
        if plot_scene {
            ctx.enable_canvas(leak(Context::canvas_bytes(&limits))).expect("canvas rows");
            plot = Some(Plot::new());
        }
        let th = *ctx.theme();
        let mut input = lcgf::Input::default();
        for k in 0..frames {
            if plot_scene {
                Plot::input(&mut input, k);
            } else if kit_scene {
                Kit::input(&mut input, k);
            } else {
                state.input(&mut input, k);
            }
            // The bench scenes only hover; the gate also presses, so clicks and drags cross too.
            input.buttons = if k % 6 < 2 { lcgf::Input::LEFT } else { 0 };
            // Whether a frame is needed crosses the seam too (an `int` in lcgf.h).
            out.extend_from_slice(&(ctx.needs_frame(&input) as u32).to_le_bytes());
            let mut f = ctx.begin(&input);
            if let Some(p) = plot.as_mut() {
                p.build(&mut f, k);
            } else if kit_scene {
                kit.build(&mut f, k);
            } else {
                state.build(&mut f, &th);
            }
            let (d, wake) = ctx.end();
            out.extend_from_slice(&(d.quads().len() as u32).to_le_bytes());
            out.extend_from_slice(bytes(d.quads()));
            out.extend_from_slice(&(d.runs().len() as u32).to_le_bytes());
            out.extend_from_slice(bytes(d.runs()));
            out.extend_from_slice(&(d.strings().len() as u32).to_le_bytes());
            out.extend_from_slice(d.strings());
            out.extend_from_slice(&d.command_count().to_le_bytes());
            for i in 0..d.command_count() {
                let c = d.command(i);
                for w in [c.kind as u32, c.first, c.count, c.key] {
                    out.extend_from_slice(&w.to_le_bytes());
                }
            }
            out.extend_from_slice(&(d.customs().len() as u32).to_le_bytes());
            let at = out.len();
            out.extend_from_slice(bytes(d.customs()));
            // A canvas's damage key hashes the batch's address, which differs between processes.
            if plot_scene {
                let size = core::mem::size_of::<lcgf::CustomDraw>();
                for i in 0..d.customs().len() {
                    out[at + i * size + 32..at + i * size + 40].fill(0);
                }
            }
            out.extend_from_slice(&u32::MAX.to_le_bytes());
            out.extend_from_slice(&u32::MAX.to_le_bytes());
            out.extend_from_slice(&wake.to_bits().to_le_bytes());
            if let Some(p) = plot.as_mut() {
                out.extend_from_slice(&p.s.len().to_le_bytes());
                let hit = p.s.hit(&Plot::options(k, &p.all, &PLOT_MARKS), input.pointer[0], input.pointer[1], 2.0);
                out.extend_from_slice(&hit.unwrap_or(u32::MAX).to_le_bytes());
                p.s.clear_dirty();
            }
        }
    }
    unsafe { dealloc(mem.as_mut_ptr(), layout) };
    std::fs::write(&args[3], out).expect("write");
}
