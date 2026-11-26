//! The Rust side of the static UIs' gate (bindings/check/run.sh): the comptime examples' `.zon`
//! (src/abi/testdata/static/) through `include_ui!(.., static)` and `lcgf::StaticUi` (liblcgf's
//! static frame, specialized per UI by this crate's build script), over the frames of
//! bindings/check/ct_dump.zig, dumped in its format. The dump must equal Zig's comptime
//! pipeline's.
//!
//!   lcgf-ct-check <mixer|card|settings|badge|dash|todo|feed|controls|palette|meter> <frames> <out.bin|--bench> [partial]
//!
//! Field k of frame f's state is what src/abi/ct.zig's `stateFor` makes (see `text`, `flag`,
//! `count`, `pick` and `value`).

use lcgf::{Buffer, DrawList, Input, KeyEvent, Str};

lcgf::include_ui!("static/mixer.zon", static);
lcgf::include_ui!("static/card.zon", static);
lcgf::include_ui!("static/settings.zon", static);
lcgf::include_ui!("static/badge.zon", static);
lcgf::include_ui!("static/dash.zon", static);
lcgf::include_ui!("static/todo.zon", static);
lcgf::include_ui!("static/feed.zon", static);
lcgf::include_ui!("static/controls.zon", static);
lcgf::include_ui!("static/palette.zon", static);
lcgf::include_ui!("static/meter.zon", static);

const TEXTS: [&str; 7] = [
    "",
    "Mixer",
    "Battery 82%",
    "x",
    "a much longer label than its box",
    "Settings",
    "0123456789",
];

fn text(f: u32, k: u32) -> Str {
    Str::new(TEXTS[((f + 3 * k) % TEXTS.len() as u32) as usize])
}
fn flag(f: u32, k: u32) -> bool {
    (f + k) % 3 != 0
}
fn count(f: u32, k: u32) -> u32 {
    if f % 2 == 0 {
        (f + k) % 11
    } else {
        (7919 * f + k) % 200000
    }
}
fn pick(f: u32, k: u32) -> u8 {
    ((f + k) % 2) as u8
}
fn color(f: u32, k: u32) -> u32 {
    ((13 * f + 40 * k) % 256) | (((7 * f) % 256) << 8) | (((90 * k) % 256) << 16) | (255 << 24)
}
fn value(f: u32, k: u32) -> f32 {
    ((131 * f + 17 * k) % 5000) as f32 * 0.75
}

fn viewport(f: u32) -> (f32, f32) {
    (
        (40 + (f * 37) % 761) as f32 + (f % 4) as f32 / 4.0,
        (30 + (f * 23) % 571) as f32,
    )
}

fn put(o: &mut Vec<u8>, v: u32) {
    o.extend_from_slice(&v.to_le_bytes());
}

fn bytes<T>(o: &mut Vec<u8>, s: &[T]) {
    // SAFETY: plain-old-data columns read as bytes.
    o.extend_from_slice(unsafe {
        core::slice::from_raw_parts(s.as_ptr().cast::<u8>(), core::mem::size_of_val(s))
    });
}

fn dump(o: &mut Vec<u8>, d: &DrawList) {
    put(o, d.quads().len() as u32);
    bytes(o, d.quads());
    put(o, d.runs().len() as u32);
    bytes(o, d.runs());
    put(o, d.strings().len() as u32);
    o.extend_from_slice(d.strings());
    let n = d.command_count();
    put(o, n);
    let cmds: Vec<_> = (0..n).map(|i| d.command(i)).collect();
    o.extend(cmds.iter().map(|c| c.kind as u8));
    for c in &cmds {
        put(o, c.first);
    }
    for c in &cmds {
        put(o, c.count);
    }
    for c in &cmds {
        put(o, c.key);
    }
}

/// Frame f's input, as bindings/check/ct_dump.zig makes it.
fn input_of(f: u32, tab: &[KeyEvent; 1]) -> Input {
    let mut input = Input::default();
    input.pointer = [
        ((f / 6 * 11) % 150 + f % 6) as f32 + 0.25,
        ((f / 6 * 5) % 56) as f32 + 0.25,
    ];
    input.buttons = if f % 6 < 3 { Input::LEFT } else { 0 };
    if f % 5 == 0 { input.keys(tab) } else { input }
}

fn tab_of(f: u32) -> [KeyEvent; 1] {
    [KeyEvent {
        kind: 0,
        mods: if f % 15 == 5 { Input::SHIFT as u8 } else { 0 },
        code: Input::TAB,
        pad: 0,
        at: 0,
        len: 0,
    }]
}

/// One UI's frames: `set` writes the state for frame f, then a frame runs, then frame f's
/// input: the event's widget row, value bits and the focus row.
fn run<'a, T: lcgf::StaticSpec>(
    name: &str,
    frames: u32,
    out: &str,
    mut ui: lcgf::StaticUi<'a, T>,
    set: impl Fn(&mut T::State, u32),
    event: impl Fn(&T::Event) -> (u32, u32),
) {
    let bench = out == "--bench";
    let mut o = Vec::new();
    let mut ev = Vec::new();
    let mut best = u128::MAX;
    let reps_: u32 = std::env::var("LCGF_REPS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(50);
    for _ in 0..(if bench { reps_ } else { 1 }) {
        let t0 = std::time::Instant::now();
        for f in 0..frames {
            set(&mut ui.state, f);
            let (w, h) = viewport(f);
            let d = ui.frame(w, h);
            if !bench {
                dump(&mut o, &d);
                let tab = tab_of(f);
                let input = input_of(f, &tab);
                let mut e = [u32::MAX, 0, u32::MAX];
                if let Some(x) = ui.pointer(&input) {
                    (e[0], e[1]) = event(&x);
                }
                ui.focus_keys(&input, Input::TAB);
                if let Some(w) = ui.focus() {
                    e[2] = T::widget_row(w);
                }
                for v in e {
                    put(&mut ev, v);
                }
            }
        }
        best = best.min(t0.elapsed().as_nanos());
    }
    if bench {
        println!(
            "ct {name:<9} {:<7} {:>7} ns/frame",
            "rust",
            best / frames as u128
        );
    } else {
        std::fs::write(out, o).expect("writing the dump");
        std::fs::write(format!("{out}.events"), ev).expect("writing the events");
    }
}

/// UI `m`'s frames, `set` writing frame f's state.
macro_rules! static_ui {
    ($m:ident, $name:expr, $frames:expr, $out:expr, |$s:ident, $f:ident| $set:block) => {{
        let buffer: &'static mut Buffer<{ $m::BYTES }> = Box::leak(Box::new(Buffer::new()));
        let ui =
            $m::Ui::new(buffer.bytes(), $m::State::default()).expect("the tables and the buffer");
        run(
            $name,
            $frames,
            $out,
            ui,
            |$s: &mut $m::State, $f| $set,
            |e: &$m::Event| (e.widget().row(), e.value().map(f32::to_bits).unwrap_or(0)),
        )
    }};
}

/// `partial`: bindings/check/ct_dump.zig's relayout and patch replay. `full` sets frame f's
/// state and runs a frame, `text` changes one label's field and lays it out again, `colors`
/// changes and patches the colour fields; `draw` gives the draw list and the dirty set.
fn run_partial<U>(
    mut ui: U,
    frames: u32,
    out: &str,
    full: impl Fn(&mut U, u32),
    text: impl Fn(&mut U, u32),
    colors: impl Fn(&mut U, u32),
    draw: impl Fn(&mut U, &mut Vec<u8>),
) {
    let mut o = Vec::new();
    for f in 0..frames {
        match f % 4 {
            0 => full(&mut ui, f),
            1 | 2 => text(&mut ui, f),
            _ => colors(&mut ui, f),
        }
        draw(&mut ui, &mut o);
    }
    std::fs::write(out, o).expect("writing the dump");
}

macro_rules! partial_ui {
    ($m:ident, $frames:expr, $out:expr, full: |$s:ident, $f:ident| $full:block, text: |$u:ident, $g:ident| $text:block, colors: |$c:ident, $h:ident| $colors:block) => {{
        let buffer: &'static mut Buffer<{ $m::BYTES }> = Box::leak(Box::new(Buffer::new()));
        let ui =
            $m::Ui::new(buffer.bytes(), $m::State::default()).expect("the tables and the buffer");
        run_partial(
            ui,
            $frames,
            $out,
            |ui, $f| {
                {
                    let $s = &mut ui.state;
                    $full
                }
                let (w, h) = viewport($f);
                ui.frame(w, h);
            },
            |$u, $g| $text,
            |$c, $h| {
                $c.clear_dirty();
                $colors
            },
            |ui, o| {
                dump(o, &ui.draw());
                o.extend(ui.dirty().iter().map(|&b| (b != 0) as u8));
            },
        )
    }};
}

fn partial(ui: &str, frames: u32, out: &str) {
    match ui {
        "mixer" => partial_ui!(mixer, frames, out,
            full: |s, f| { s.title = text(f, 0); s.volume = value(f, 1); s.muted = flag(f, 2); s.pan = value(f, 3); },
            text: |u, f| { u.state.title = text(f, 0); u.relayout(mixer::Field::Title); },
            colors: |_u, _f| {}),
        "dash" => partial_ui!(dash, frames, out,
            full: |s, f| { s.title = text(f, 0); s.a = text(f, 1); s.b = text(f, 2); s.c = text(f, 3); s.level = value(f, 4); },
            text: |u, f| {
                match (f / 4 + f % 4) % 4 {
                    0 => { u.state.title = text(f, 0); u.relayout(dash::Field::Title); }
                    1 => { u.state.a = text(f, 1); u.relayout(dash::Field::A); }
                    2 => { u.state.b = text(f, 2); u.relayout(dash::Field::B); }
                    _ => { u.state.c = text(f, 3); u.relayout(dash::Field::C); }
                }
            },
            colors: |_u, _f| {}),
        "todo" => partial_ui!(todo, frames, out,
            full: |s, f| { s.title = text(f, 0); s.len = count(f, 1); s.footer = flag(f, 2); s.mode = pick(f, 3); },
            text: |u, f| { u.state.title = text(f, 0); u.relayout(todo::Field::Title); },
            colors: |_u, _f| {}),
        "palette" => partial_ui!(palette, frames, out,
        full: |s, f| { s.title = text(f, 0); s.accent = color(f, 1); s.edge = color(f, 2); },
        text: |u, f| { u.state.title = text(f, 0); u.relayout(palette::Field::Title); },
        colors: |u, f| {
            u.state.accent = color(f, 1);
            u.patch(palette::Field::Accent);
            u.state.edge = color(f, 2);
            u.patch(palette::Field::Edge);
        }),
        "meter" => partial_ui!(meter, frames, out,
        full: |s, f| { s.name = text(f, 0); s.level = value(f, 1); s.count = count(f, 2); s.on = flag(f, 3); s.peak = value(f, 4); },
        text: |u, f| {
            // Every field is shown by a formatted label: ct_dump's `labelFields` cycles them all.
            match (f / 4 + f % 4) % 5 {
                0 => { u.state.name = text(f, 0); u.relayout(meter::Field::Name); }
                1 => { u.state.level = value(f, 1); u.relayout(meter::Field::Level); }
                2 => { u.state.count = count(f, 2); u.relayout(meter::Field::Count); }
                3 => { u.state.on = flag(f, 3); u.relayout(meter::Field::On); }
                _ => { u.state.peak = value(f, 4); u.relayout(meter::Field::Peak); }
            }
        },
        colors: |_u, _f| {}),
        other => {
            eprintln!("no partial replay for {other}");
            std::process::exit(2);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: lcgf-ct-check <ui> <frames> <out.bin|--bench> [partial]");
        std::process::exit(2);
    }
    let frames: u32 = args[2].parse().expect("frames");
    let out = args[3].as_str();
    if args.get(4).map(|a| a == "partial").unwrap_or(false) {
        return partial(args[1].as_str(), frames, out);
    }
    match args[1].as_str() {
        "mixer" => static_ui!(mixer, "mixer", frames, out, |s, f| {
            s.title = text(f, 0);
            s.volume = value(f, 1);
            s.muted = flag(f, 2);
            s.pan = value(f, 3);
        }),
        "card" => static_ui!(card, "card", frames, out, |s, f| {
            s.heading = text(f, 0);
            s.body = text(f, 1);
        }),
        "settings" => static_ui!(settings, "settings", frames, out, |s, f| {
            s.title = text(f, 0);
            s.wifi = flag(f, 1);
            s.bluetooth = flag(f, 2);
            s.brightness = value(f, 3);
            s.volume = value(f, 4);
            s.dark = flag(f, 5);
            s.sleep = value(f, 6);
            s.sounds = flag(f, 7);
            s.haptics = flag(f, 8);
            s.contrast = value(f, 9);
            s.location = flag(f, 10);
        }),
        "badge" => static_ui!(badge, "badge", frames, out, |s, f| {
            s.name = text(f, 0);
            s.level = value(f, 1);
        }),
        "dash" => static_ui!(dash, "dash", frames, out, |s, f| {
            s.title = text(f, 0);
            s.a = text(f, 1);
            s.b = text(f, 2);
            s.c = text(f, 3);
            s.level = value(f, 4);
        }),
        "todo" => static_ui!(todo, "todo", frames, out, |s, f| {
            s.title = text(f, 0);
            s.len = count(f, 1);
            s.footer = flag(f, 2);
            s.mode = pick(f, 3);
        }),
        "controls" => static_ui!(controls, "controls", frames, out, |s, f| {
            s.title = text(f, 0);
            s.muted = flag(f, 1);
            s.volume = value(f, 2);
            s.pan = value(f, 3);
        }),
        "palette" => static_ui!(palette, "palette", frames, out, |s, f| {
            s.title = text(f, 0);
            s.accent = color(f, 1);
            s.edge = color(f, 2);
        }),
        "meter" => static_ui!(meter, "meter", frames, out, |s, f| {
            s.name = text(f, 0);
            s.level = value(f, 1);
            s.count = count(f, 2);
            s.on = flag(f, 3);
            s.peak = value(f, 4);
        }),
        "feed" => static_ui!(feed, "feed", frames, out, |s, f| {
            s.count = count(f, 0);
            s.scroll = value(f, 1);
        }),
        other => {
            eprintln!("unknown ui {other}");
            std::process::exit(2);
        }
    }
}
