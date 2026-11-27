//! The Rust side of the bindings' gate (bindings/check/run.sh): a generated UI run frame by
//! frame, its draw lists written in the dump format of bindings/check/dump.zig.
//!
//!   lcgf-check <toolbar|mixer|panel> <inputs.txt> <out.bin>
//!   lcgf-check <toolbar|mixer|panel> <inputs.txt> --bench   (ns per frame, 200 passes)
//!
//! The toolbar comes from its `.zon` file (`include_ui!`), the mixer and the panel from the
//! `ui!` DSL: all go through lcgf-gen while this crate compiles.

lcgf::include_ui!("toolbar.zon");

// The panel through the DSL: regions, a custom draw node and a sprung slider.
lcgf::ui! {
    state Panel {
        title: &'static str = "Panel",
        show: bool = true,
        show_text: &'static str = "Details",
        len: u32 = 2,
        mode: u8 = 0,
        spring level: f32 = 0.25,
    }
    col(pad: 8, gap: 4, fill: theme(panel)) {
        row(gap: 8, cross: center) {
            checkbox(id: show_box, bind: show, text: show_text)
            slider(id: level, bind: level)
        }
        col(when: show, gap: 2) {
            label(title)
            text("{} at {.2}, {} rows", title, level, len)
            custom(id: view, data: 7, size: (px(60), px(20)))
        }
        list(count: len, max: 4, gap: 2) {
            row(gap: 4) {
                label(title)
                col(size: (px(12), px(8)), fill: theme(accent))
            }
        }
        choice(select: mode) {
            col(size: (px(16), px(16)), fill: theme(control))
            row(gap: 4) {
                label(title)
                button(id: more, text: title)
            }
        }
    }
}

lcgf::ui! {
    state Mixer { title: &'static str = "Mixer", mute_text: &'static str = "Mute", muted: bool = false, volume: f32 = 0.5, pan: f32 = 0.0 }
    col(pad: 8, gap: 4, fill: theme(panel)) {
        label(title)
        row(size: (fill, fit), gap: 8, cross: center) {
            checkbox(id: mute, bind: muted, text: mute_text)
            slider(id: volume, bind: volume)
        }
        row(gap: 8) {
            label(title)
            slider(id: pan, bind: pan)
        }
    }
}

fn dump<W: lcgf::WidgetEnum>(out: &mut Vec<u8>, f: &lcgf::Frame<'_, W>) {
    fn bytes<T>(s: &[T]) -> &[u8] {
        unsafe { std::slice::from_raw_parts(s.as_ptr().cast(), std::mem::size_of_val(s)) }
    }
    let d = &f.draw;
    out.extend_from_slice(&(d.quads().len() as u32).to_le_bytes());
    out.extend_from_slice(bytes(d.quads()));
    out.extend_from_slice(&(d.runs().len() as u32).to_le_bytes());
    out.extend_from_slice(bytes(d.runs()));
    out.extend_from_slice(&(d.strings().len() as u32).to_le_bytes());
    out.extend_from_slice(d.strings());
    out.extend_from_slice(&d.command_count().to_le_bytes());
    for i in 0..d.command_count() {
        let c = d.command(i);
        for v in [c.kind as u32, c.first, c.count, c.key] {
            out.extend_from_slice(&v.to_le_bytes());
        }
    }
    out.extend_from_slice(&(d.customs().len() as u32).to_le_bytes());
    out.extend_from_slice(bytes(d.customs()));
    out.extend_from_slice(&f.events.slot().unwrap_or(u32::MAX).to_le_bytes());
    out.extend_from_slice(&f.events.focus_slot().unwrap_or(u32::MAX).to_le_bytes());
    out.extend_from_slice(&f.events.wake().to_bits().to_le_bytes());
}

/// One line of the input script: a frame (with its Tab presses), or `set <field> <value>`.
enum Line {
    Frame(lcgf::Input),
    Set(String, u32),
}

static TAB: [lcgf::KeyEvent; 1] = [lcgf::KeyEvent {
    kind: 0,
    mods: 0,
    code: lcgf::Input::TAB,
    _pad: 0,
    at: 0,
    len: 0,
}];

fn inputs(path: &str) -> Vec<Line> {
    std::fs::read_to_string(path)
        .expect("inputs")
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.first() == Some(&"set") {
                return Some(Line::Set(f[1].to_string(), f[2].parse().ok()?));
            }
            if f.len() < 3 {
                return None;
            }
            let tab = f.get(3).map_or(false, |t| *t != "0");
            let input = lcgf::Input {
                pointer: [f[0].parse().ok()?, f[1].parse().ok()?],
                buttons: f[2].parse().ok()?,
                ..Default::default()
            };
            Some(Line::Frame(if tab { input.keys(&TAB) } else { input }))
        })
        .collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    assert!(
        args.len() == 4,
        "usage: lcgf-check <toolbar|mixer|panel> <inputs.txt> <out.bin>"
    );
    let mut out = Vec::new();
    let lines = inputs(&args[2]);
    let bench = args[3] == "--bench";
    // Bench: 200 passes over the inputs; the sink keeps the frames from being dropped.
    macro_rules! run {
        ($ui:expr, $set:expr) => {
            if bench {
                let mut sink = 0u32;
                let mut n = 0usize;
                let t0 = std::time::Instant::now();
                for _ in 0..200 {
                    for l in &lines {
                        if let Line::Frame(input) = l {
                            sink = sink.wrapping_add($ui.frame(input).draw.quads().len() as u32);
                            n += 1;
                        }
                    }
                }
                let ns = t0.elapsed().as_nanos() as f64 / n as f64;
                println!("{} rust: {ns:.0} ns/frame (sink {sink})", args[1]);
                return;
            }
            for l in &lines {
                match l {
                    Line::Set(field, v) => $set(&mut $ui, field.as_str(), *v),
                    Line::Frame(input) => {
                        let f = $ui.frame(input);
                        dump(&mut out, &f);
                    }
                }
            }
        };
    }
    match args[1].as_str() {
        "mixer" => {
            let mut buf = Box::new(lcgf::Buffer::<{ mixer::BYTES }>::new());
            let mut ui = mixer::Ui::new(&mut buf).expect("lcgf_ui_init");
            run!(ui, |_: &mut mixer::Ui, _: &str, _: u32| {});
        }
        "panel" => {
            let mut buf = Box::new(lcgf::Buffer::<{ panel::BYTES }>::new());
            let mut ui = panel::Ui::new(&mut buf).expect("lcgf_ui_init");
            run!(ui, |ui: &mut panel::Ui, field: &str, v: u32| match field {
                "len" => ui.set_len(v),
                "mode" => ui.set_mode(v as u8),
                _ => {}
            });
        }
        _ => {
            let mut buf = Box::new(lcgf::Buffer::<{ toolbar::BYTES }>::new());
            let mut ui = toolbar::Ui::new(&mut buf).expect("lcgf_ui_init");
            ui.set_layer("Layer 0".into()); // a setter: one store
            run!(ui, |_: &mut toolbar::Ui, _: &str, _: u32| {});
        }
    }
    std::fs::write(&args[3], &out).unwrap();
}
