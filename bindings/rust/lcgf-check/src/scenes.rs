//! The scenes of bench/scenes/ (form, list, text, springs, resize, idle) written with
//! `lcgf::runtime`, frame for frame what the Zig ones build (bindings/check/run.sh holds them to
//! it). bench/vs/lcgf-rust includes this file too.

use lcgf::Input;
use lcgf::runtime::{self, Align, Dir, Frame, Id, Limits, Size, Style, TextStyle, Theme};
use std::fmt::Write;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Scene {
    Form,
    List,
    Text,
    Springs,
    Resize,
    Idle,
}

pub const NAMES: [(&str, Scene); 6] = [
    ("form", Scene::Form),
    ("list", Scene::List),
    ("text", Scene::Text),
    ("springs", Scene::Springs),
    ("resize", Scene::Resize),
    ("idle", Scene::Idle),
];

const FORM_NAMES: [&str; 21] = [
    "Name", "Email", "Phone", "Street", "City", "Postcode", "Country", "Company", "Title", "Team",
    "Manager", "Website", "Timezone", "Language", "Currency", "Theme", "Font", "Density", "Backup",
    "Sync", "Alerts",
];
const TOTAL: u32 = 100_000;
const ROW_H: u32 = 24;
const VISIBLE: u32 = 800 / ROW_H + 2;
const LIST_NAMES: [&str; 7] = [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf",
];
const PROSE: [&str; 4] = [
    "Columns of rows replace trees of objects: every pass walks a few dense arrays from start to end, so the cache sees one stream per field and the vector units take eight rows at a time.",
    "A frame is rebuilt from scratch, laid out in a handful of passes and painted into a draw list that a renderer submits as it is. Nothing outlives the frame except what the caller keeps.",
    "Text is measured once per run and wrapped against the width the layout grants; lines break at spaces, and a word wider than the line is broken where it overflows.",
    "Idle costs nothing: when no input arrives and no spring moves, no frame is built, so the process sleeps until the next event and the battery is left alone.",
];

/// A scene and the state it keeps between frames.
pub struct State {
    pub scene: Scene,
    checks: [bool; 21],
    values: [f32; 21],
    scroll: u32,
    tick: u32,
    buf: String,
}

impl State {
    pub fn new(scene: Scene) -> Self {
        Self {
            scene,
            checks: [false; 21],
            values: [0.5; 21],
            scroll: 0,
            tick: 0,
            buf: String::new(),
        }
    }

    /// Nodes the scene needs (bench/vs/harness.h's `vs_capacity`).
    pub fn limits(&self) -> Limits {
        let n = if self.scene == Scene::Springs {
            2048
        } else {
            256
        };
        Limits {
            nodes: n,
            texts: n,
            customs: 64,
            strings: 32 * 1024,
            anims: n,
            depth: 64,
        }
    }

    /// Built every poll: their state changes outside the input (bench/scenes `every`).
    #[allow(dead_code)] // bench/vs/lcgf-rust's
    pub fn every(&self) -> bool {
        matches!(self.scene, Scene::List | Scene::Springs)
    }

    pub fn input(&mut self, input: &mut Input, k: u32) {
        match self.scene {
            Scene::Form => {
                input.viewport = [800.0, 600.0];
                input.pointer = [(20 + (k * 7) % 760) as f32, (20 + (k * 13) % 560) as f32];
            }
            Scene::List => {
                input.viewport = [1280.0, 800.0];
                input.pointer = [640.0, (10 + (k * 13) % 780) as f32];
                self.scroll = (k * 997) % (TOTAL * ROW_H - 800);
            }
            Scene::Text => {
                input.viewport = [1280.0, 800.0];
                input.pointer = [(20 + (k * 7) % 1240) as f32, (20 + (k * 13) % 760) as f32];
            }
            Scene::Springs => {
                input.viewport = [1280.0, 800.0];
                input.dt = 1.0 / 60.0;
                self.tick = k;
            }
            Scene::Resize => {
                input.viewport = [
                    (320 + (k * 37) % 1600) as f32,
                    (240 + (k * 53) % 1000) as f32,
                ];
                input.pointer = [100.0, 100.0];
            }
            Scene::Idle => {
                input.viewport = [800.0, 600.0];
                input.pointer = [400.0, 300.0];
            }
        }
    }

    pub fn build(&mut self, f: &mut Frame<'_>, th: &Theme) {
        match self.scene {
            Scene::Form | Scene::Idle => self.form(f, th),
            Scene::List => self.list(f, th),
            Scene::Text | Scene::Resize => self.text(f, th),
            Scene::Springs => self.springs(f, th),
        }
    }

    fn form(&mut self, f: &mut Frame<'_>, th: &Theme) {
        let base = Id::from("form");
        f.open(
            base,
            &Style {
                size: [Size::FILL, Size::FILL],
                pad: [12.0; 4],
                gap: 4.0,
                fill: th.panel,
                ..Style::DEFAULT
            },
        );
        f.text(
            "Account settings",
            &TextStyle {
                px: 20.0,
                color: th.text,
                ..TextStyle::DEFAULT
            },
        );
        f.leaf(
            Id::NONE,
            &Style {
                size: [Size::FILL, Size::px(1.0)],
                fill: th.control_hot,
                ..Style::DEFAULT
            },
        );
        let label = TextStyle {
            px: th.text_px,
            color: th.text,
            ..TextStyle::DEFAULT
        };
        for r in 0..21u32 {
            let id = base.with(r);
            let name = FORM_NAMES[r as usize];
            f.open(
                id,
                &Style {
                    dir: Dir::X,
                    size: [Size::FILL, Size::FIT],
                    gap: th.gap,
                    cross: Align::Center,
                    ..Style::DEFAULT
                },
            );
            f.text_styled(
                name,
                &label,
                &Style {
                    size: [Size::px(90.0), Size::FIT],
                    ..Style::DEFAULT
                },
            );
            f.open(
                id.with(1),
                &Style {
                    size: [Size::grow(1.0), Size::FIT],
                    pad: [4.0; 4],
                    fill: th.control,
                    border_color: th.control_hot,
                    border: 1.0,
                    radius: th.radius,
                    ..Style::DEFAULT
                },
            );
            runtime::label(f, name);
            f.close();
            runtime::checkbox(f, id.with(2), &mut self.checks[r as usize], "On");
            runtime::slider(f, id.with(3), &mut self.values[r as usize], 0.0, 1.0);
            f.close();
        }
        f.open(
            base.with(1000),
            &Style {
                dir: Dir::X,
                size: [Size::FILL, Size::FIT],
                gap: th.gap,
                main: Align::End,
                ..Style::DEFAULT
            },
        );
        runtime::button(f, base.with(1001), "Cancel");
        runtime::button(f, base.with(1002), "Reset");
        runtime::button(f, base.with(1003), "Save");
        f.close();
        f.close();
    }

    fn list(&mut self, f: &mut Frame<'_>, th: &Theme) {
        let first = self.scroll / ROW_H;
        let end = (first + VISIBLE).min(TOTAL);
        f.open(
            Id::from("list"),
            &Style {
                size: [Size::FILL, Size::FILL],
                clip: 1,
                scroll: [0.0, self.scroll as f32],
                ..Style::DEFAULT
            },
        );
        f.leaf(
            Id::NONE,
            &Style {
                size: [Size::FILL, Size::px((first * ROW_H) as f32)],
                ..Style::DEFAULT
            },
        );
        let fills = [th.panel, th.control];
        for r in first..end {
            f.open(
                Id::NONE,
                &Style {
                    dir: Dir::X,
                    size: [Size::FILL, Size::px(ROW_H as f32)],
                    pad: [8.0, 0.0, 8.0, 0.0],
                    gap: th.gap,
                    cross: Align::Center,
                    fill: fills[(r % 2) as usize],
                    ..Style::DEFAULT
                },
            );
            self.buf.clear();
            let _ = write!(self.buf, "Row {r}");
            runtime::label(f, &self.buf);
            runtime::label(f, LIST_NAMES[(r % 7) as usize]);
            f.leaf(
                Id::NONE,
                &Style {
                    size: [Size::px(12.0), Size::px(12.0)],
                    fill: th.accent,
                    ..Style::DEFAULT
                },
            );
            f.close();
        }
        f.leaf(
            Id::NONE,
            &Style {
                size: [Size::FILL, Size::px(((TOTAL - end) * ROW_H) as f32)],
                ..Style::DEFAULT
            },
        );
        f.close();
    }

    fn text(&mut self, f: &mut Frame<'_>, th: &Theme) {
        f.open(
            Id::from("text"),
            &Style {
                dir: Dir::X,
                size: [Size::FILL, Size::FILL],
                pad: [12.0; 4],
                gap: 16.0,
                clip: 1,
                ..Style::DEFAULT
            },
        );
        f.open(
            Id::NONE,
            &Style {
                size: [Size::px(160.0), Size::FILL],
                gap: 2.0,
                ..Style::DEFAULT
            },
        );
        for i in 0..120 {
            self.buf.clear();
            let _ = write!(self.buf, "Chapter {}", i + 1);
            runtime::label(f, &self.buf);
        }
        f.close();
        f.open(
            Id::NONE,
            &Style {
                size: [Size::grow(1.0), Size::FIT],
                gap: 8.0,
                shrink: 1,
                ..Style::DEFAULT
            },
        );
        let heading = TextStyle {
            px: 20.0,
            color: th.text,
            ..TextStyle::DEFAULT
        };
        let body = TextStyle {
            px: th.text_px,
            color: th.text,
            wrap: 1,
            ..TextStyle::DEFAULT
        };
        for s in 0..12 {
            self.buf.clear();
            let _ = write!(self.buf, "Section {}", s + 1);
            f.text(&self.buf, &heading);
            for p in 0..4 {
                f.text(PROSE[(s + p) % 4], &body);
            }
        }
        f.close();
        f.close();
    }

    fn springs(&mut self, f: &mut Frame<'_>, th: &Theme) {
        let base = Id::from("springs");
        let targets = [4.0, 40.0];
        f.open(
            base,
            &Style {
                size: [Size::FILL, Size::FILL],
                pad: [8.0; 4],
                gap: 2.0,
                ..Style::DEFAULT
            },
        );
        for r in 0..40u32 {
            f.open(
                Id::NONE,
                &Style {
                    dir: Dir::X,
                    gap: 2.0,
                    ..Style::DEFAULT
                },
            );
            for c in 0..25u32 {
                let i = r * 25 + c;
                let w = f.animate(base.with(i), targets[((self.tick / 30 + i) % 2) as usize]);
                f.leaf(
                    Id::NONE,
                    &Style {
                        size: [Size::px(w), Size::px(16.0)],
                        fill: th.accent,
                        ..Style::DEFAULT
                    },
                );
            }
            f.close();
        }
        f.close();
    }
}
