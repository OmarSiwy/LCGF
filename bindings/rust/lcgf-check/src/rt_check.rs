//! The runtime front end from Rust (`lcgf::runtime`): bench/scenes/' scenes built each frame,
//! their draw lists written in bindings/check/dump.zig's format for run.sh to compare with Zig.
//!
//!   lcgf-rt-check <form|list|text|springs|resize|idle|kit> <frames> <out.bin> [nodes depth]
//!
//! `kit` is the gate's own scene (bindings/check/rt_dump.zig's `Kit`): formatted text, the
//! widgets by options, and springs and tweens on a colour and an array.
//!   lcgf-rt-check rows <in.bin>   (lcgf-rt-dump rows' styles: `Row::from` must equal Zig's rows)

mod scenes;

use lcgf::runtime::{Context, Row, Size, Style};
use std::alloc::{Layout, alloc_zeroed, dealloc};

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
    let kit_scene = args[1] == "kit";
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
        let th = *ctx.theme();
        let mut input = lcgf::Input::default();
        for k in 0..frames {
            if kit_scene {
                Kit::input(&mut input, k);
            } else {
                state.input(&mut input, k);
            }
            // The bench scenes only hover; the gate also presses, so clicks and drags cross too.
            input.buttons = if k % 6 < 2 { lcgf::Input::LEFT } else { 0 };
            // Whether a frame is needed crosses the seam too (an `int` in lcgf.h).
            out.extend_from_slice(&(ctx.needs_frame(&input) as u32).to_le_bytes());
            let mut f = ctx.begin(&input);
            if kit_scene {
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
            out.extend_from_slice(bytes(d.customs()));
            out.extend_from_slice(&u32::MAX.to_le_bytes());
            out.extend_from_slice(&u32::MAX.to_le_bytes());
            out.extend_from_slice(&wake.to_bits().to_le_bytes());
        }
    }
    unsafe { dealloc(mem.as_mut_ptr(), layout) };
    std::fs::write(&args[3], out).expect("write");
}
