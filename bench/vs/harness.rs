//! Shared driver for the Rust comparison harnesses (bench/vs/egui, iced, slint): the Rust twin of
//! bench/vs/harness.h, with the same scenes, input per frame, output lines and `--idle` protocol.
//! A harness includes it with `#[path = "../../harness.rs"] mod harness;`.
#![allow(dead_code)]

use std::io::{Read, Write};
use std::time::Instant;

pub const FRAMES: u32 = 3000;
pub const SCENES: [&str; 6] = ["form", "list", "text", "springs", "resize", "idle"];
pub const FORM: usize = 0;
pub const LIST: usize = 1;
pub const TEXT: usize = 2;
pub const SPRINGS: usize = 3;
pub const RESIZE: usize = 4;
pub const IDLE: usize = 5;

/// The input bench/scenes/ gives frame k. Equal inputs mean nothing changed (`tick` is the
/// springs scene's frame count, zero elsewhere).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Input {
    pub w: f32,
    pub h: f32,
    pub px: f32,
    pub py: f32,
    pub dt: f32,
    pub scroll: u32,
    pub tick: u32,
}

pub fn input(scene: usize, k: u32) -> Input {
    let mut i = Input { w: 800.0, h: 600.0, px: 0.0, py: 0.0, dt: 1.0 / 60.0, scroll: 0, tick: 0 };
    match scene {
        FORM => (i.px, i.py) = ((20 + (k * 7) % 760) as f32, (20 + (k * 13) % 560) as f32),
        LIST => {
            (i.w, i.h, i.px, i.py) = (1280.0, 800.0, 640.0, (10 + (k * 13) % 780) as f32);
            i.scroll = (k * 997) % (100_000 * 24 - 800);
        }
        TEXT => (i.w, i.h, i.px, i.py) = (1280.0, 800.0, (20 + (k * 7) % 1240) as f32, (20 + (k * 13) % 760) as f32),
        SPRINGS => (i.w, i.h, i.tick) = (1280.0, 800.0, k),
        RESIZE => (i.w, i.h, i.px, i.py) = ((320 + (k * 37) % 1600) as f32, (240 + (k * 53) % 1000) as f32, 100.0, 100.0),
        _ => (i.px, i.py) = (400.0, 300.0),
    }
    i
}

pub const FORM_NAMES: [&str; 21] = [
    "Name", "Email", "Phone", "Street", "City", "Postcode", "Country", "Company", "Title", "Team", "Manager",
    "Website", "Timezone", "Language", "Currency", "Theme", "Font", "Density", "Backup", "Sync", "Alerts",
];
pub const LIST_NAMES: [&str; 7] = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"];
pub const PROSE: [&str; 4] = [
    "Columns of rows replace trees of objects: every pass walks a few dense arrays from start to end, so the cache sees one stream per field and the vector units take eight rows at a time.",
    "A frame is rebuilt from scratch, laid out in a handful of passes and painted into a draw list that a renderer submits as it is. Nothing outlives the frame except what the caller keeps.",
    "Text is measured once per run and wrapped against the width the layout grants; lines break at spaces, and a word wider than the line is broken where it overflows.",
    "Idle costs nothing: when no input arrives and no spring moves, no frame is built, so the process sleeps until the next event and the battery is left alone.",
];

/// The springs scene's 1,000 springs, stepped as prototype/ui.zig `Anims.step` does.
pub struct Springs {
    pub x: [f32; 1000],
    v: [f32; 1000],
    started: bool,
}

impl Default for Springs {
    fn default() -> Self {
        Springs { x: [0.0; 1000], v: [0.0; 1000], started: false }
    }
}

pub fn spring_target(tick: u32, i: u32) -> f32 {
    if (tick / 30 + i) % 2 == 1 { 40.0 } else { 4.0 }
}

impl Springs {
    pub fn step(&mut self, tick: u32, dt: f32) {
        let h = dt.min(1.0 / 30.0);
        for i in 0..1000 {
            let t = spring_target(tick, i as u32);
            if !self.started {
                self.x[i] = t;
                self.v[i] = 0.0;
            }
            let acc = 170.0 * (t - self.x[i]) - 26.0 * self.v[i];
            self.v[i] += acc * h;
            self.x[i] += self.v[i] * h;
        }
        self.started = true;
    }
}

/// Blocks on stdin until it closes: the host loop of a library without an event loop of its own.
pub fn block_on_stdin() {
    let mut byte = [0u8; 1];
    loop {
        match std::io::stdin().read(&mut byte) {
            Ok(0) => break,
            Ok(_) => (),
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
            Err(_) => break,
        }
    }
}

/// Parses `--scene NAME` / `--idle`, then times `frame` (which returns what it emitted, zero for a
/// poll it skipped) or prints "ready" after one frame and calls `idle`.
pub fn main(framework: &str, mut frame: impl FnMut(usize, u32) -> u64, idle: impl FnOnce()) {
    let mut scene = FORM;
    let mut is_idle = false;
    let mut hold = false;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--idle" => (is_idle, scene) = (true, IDLE),
            "--hold-after-scene" => hold = true,
            "--scene" => {
                let name = args.next().expect("--scene NAME");
                scene = SCENES.iter().position(|s| *s == name).unwrap_or_else(|| panic!("unknown scene {name}"));
            }
            _ => panic!("usage: [--scene NAME] [--idle | --hold-after-scene]"),
        }
    }
    assert!(!(hold && is_idle), "--idle and --hold-after-scene are mutually exclusive");
    let mut out = std::io::stdout().lock();
    if is_idle {
        let n = frame(scene, 0);
        writeln!(out, "ready framework={framework} out={n}").unwrap();
        out.flush().unwrap();
        idle();
        return;
    }
    let mut samples = Vec::with_capacity(FRAMES as usize);
    let (mut sink, mut last, mut built) = (0u64, 0u64, 0u64);
    for k in 0..FRAMES {
        let t0 = Instant::now();
        last = frame(scene, k);
        samples.push(t0.elapsed().as_nanos() as u64);
        sink += last;
        built += (last != 0) as u64;
    }
    samples.sort_unstable();
    let us = |i: usize| samples[i] as f64 / 1000.0;
    let n = FRAMES as usize;
    writeln!(out, "framework={framework} scene={} frames={built} polls={FRAMES} out={last} sink={sink}", SCENES[scene]).unwrap();
    writeln!(out, "{:<10} {:>9} {:>9}", "pass", "median us", "p99 us").unwrap();
    writeln!(out, "{:<10} {:9.1} {:9.1}", "frame", us(n / 2), us(n * 99 / 100)).unwrap();
    if hold {
        writeln!(out, "scene complete").unwrap();
        out.flush().unwrap();
        block_on_stdin();
    }
}
