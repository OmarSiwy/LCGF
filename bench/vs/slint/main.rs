//! The scenes of bench/scenes/ on Slint 1.18 (https://github.com/slint-ui/slint), for the
//! comparison of docs/perf/vs.md. Slint is retained, with lazily evaluated property bindings: each
//! scene's component is made once, a frame sets that frame's properties (pointer event, list
//! viewport, bar widths, window size) and calls `draw_if_needed` on a `MinimalSoftwareWindow`,
//! which evaluates the dirty bindings and layouts and redraws the dirty region with the software
//! renderer into a 32-bit buffer. So, as for LVGL, a frame includes rasterisation, which
//! bench/micro's does not, and a frame where nothing visible changed costs little and draws nothing.
//! Slint evaluates layout lazily while it renders, so there is no layout-only time to give.
//!
//! No window and no winit: a platform of our own hands Slint the software window. Widgets are
//! std-widgets (LineEdit, CheckBox, Slider, Button, ListView) in the default style; text is
//! rendered from the system fonts at 14 and 20 px. Springs come from bench/vs/harness.rs.
//! `--idle` runs Slint's own timer loop: sleep until the next timer or input.
#[path = "../harness.rs"]
mod harness;

use slint::platform::software_renderer::{MinimalSoftwareWindow, PremultipliedRgbaColor, RepaintBufferType};
use slint::platform::{Platform, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, LogicalPosition, Model, ModelRc, PhysicalSize, SharedString, VecModel};
use std::rc::Rc;
use std::time::{Duration, Instant};

slint::slint! {
    import { LineEdit, CheckBox, Slider, Button, ListView } from "std-widgets.slint";

    export global Theme {
        out property <color> text: #e6e6eb;
        out property <color> panel: #1e1f24;
        out property <color> control: #3a3c46;
        out property <color> control-hot: #4a4d5a;
        out property <color> accent: #5a8cff;
    }

    export component Form inherits Window {
        in property <[string]> names;
        background: Theme.panel;
        default-font-size: 14px;
        VerticalLayout {
            padding: 12px;
            spacing: 4px;
            alignment: start;
            Text { text: "Account settings"; font-size: 20px; color: Theme.text; }
            Rectangle { height: 1px; background: Theme.control-hot; }
            for name in names: HorizontalLayout {
                spacing: 6px;
                Text { text: name; width: 90px; vertical-alignment: center; color: Theme.text; }
                LineEdit { text: name; }
                CheckBox { text: "On"; }
                Slider { minimum: 0; maximum: 1; value: 0.5; }
            }
            HorizontalLayout {
                spacing: 6px;
                alignment: end;
                Button { text: "Cancel"; }
                Button { text: "Reset"; }
                Button { text: "Save"; }
            }
        }
    }

    export struct Row { label: string, name: string }

    export component List inherits Window {
        in property <[Row]> rows;
        in-out property <length> content-y <=> list.content-y;
        background: Theme.panel;
        default-font-size: 14px;
        list := ListView {
            for row[i] in rows: Rectangle {
                height: 24px;
                background: mod(i, 2) == 1 ? Theme.control : Theme.panel;
                HorizontalLayout {
                    padding-left: 8px;
                    padding-right: 8px;
                    spacing: 6px;
                    alignment: start;
                    Text { text: row.label; vertical-alignment: center; color: Theme.text; }
                    Text { text: row.name; vertical-alignment: center; color: Theme.text; }
                    VerticalLayout {
                        alignment: center;
                        Rectangle { width: 12px; height: 12px; background: Theme.accent; }
                    }
                }
            }
        }
    }

    export component Prose inherits Window {
        in property <[string]> chapters;
        in property <[string]> sections;
        in property <[string]> prose;
        background: Theme.panel;
        default-font-size: 14px;
        HorizontalLayout {
            padding: 12px;
            spacing: 16px;
            VerticalLayout {
                width: 160px;
                spacing: 2px;
                alignment: start;
                for c in chapters: Text { text: c; color: Theme.text; }
            }
            VerticalLayout {
                spacing: 8px;
                alignment: start;
                for s[si] in sections: VerticalLayout {
                    spacing: 8px;
                    Text { text: s; font-size: 20px; color: Theme.text; }
                    for p in 4: Text { text: prose[mod(si + p, 4)]; wrap: word-wrap; color: Theme.text; }
                }
            }
        }
    }

    export component Springs inherits Window {
        in property <[length]> widths;
        background: Theme.panel;
        VerticalLayout {
            padding: 8px;
            spacing: 2px;
            alignment: start;
            for r in 40: HorizontalLayout {
                spacing: 2px;
                alignment: start;
                for c in 25: Rectangle { width: widths[r * 25 + c]; height: 16px; background: Theme.accent; }
            }
        }
    }
}

/// The list's 100,000 rows, made on demand: ListView asks only for the rows it shows.
struct Rows;
impl Model for Rows {
    type Data = Row;
    fn row_count(&self) -> usize {
        100_000
    }
    fn row_data(&self, r: usize) -> Option<Row> {
        Some(Row { label: SharedString::from(format!("Row {r}")), name: harness::LIST_NAMES[r % 7].into() })
    }
    fn model_tracker(&self) -> &dyn slint::ModelTracker {
        &()
    }
}

struct Host {
    window: Rc<MinimalSoftwareWindow>,
    start: Instant,
}
impl Platform for Host {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.window.clone())
    }
    fn duration_since_start(&self) -> Duration {
        self.start.elapsed()
    }
}

fn strings(v: impl Iterator<Item = String>) -> ModelRc<SharedString> {
    ModelRc::new(VecModel::from(v.map(SharedString::from).collect::<Vec<_>>()))
}

/// Keeps the scene's component alive and gives the frame loop its changing properties.
enum Scene {
    Form(Form),
    List(List),
    Prose(Prose),
    Springs(Springs, Rc<VecModel<f32>>, harness::Springs),
}

fn make(scene: usize) -> Scene {
    match scene {
        harness::LIST => {
            let c = List::new().unwrap();
            c.set_rows(ModelRc::new(Rows));
            Scene::List(c)
        }
        harness::TEXT | harness::RESIZE => {
            let c = Prose::new().unwrap();
            c.set_chapters(strings((1..=120).map(|i| format!("Chapter {i}"))));
            c.set_sections(strings((1..=12).map(|i| format!("Section {i}"))));
            c.set_prose(strings(harness::PROSE.iter().map(|p| p.to_string())));
            Scene::Prose(c)
        }
        harness::SPRINGS => {
            let c = Springs::new().unwrap();
            let widths = Rc::new(VecModel::from(vec![4.0f32; 1000]));
            c.set_widths(ModelRc::from(widths.clone()));
            Scene::Springs(c, widths, Default::default())
        }
        _ => {
            let c = Form::new().unwrap();
            c.set_names(strings(harness::FORM_NAMES.iter().map(|n| n.to_string())));
            Scene::Form(c)
        }
    }
}

fn main() {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer);
    slint::platform::set_platform(Box::new(Host { window: window.clone(), start: Instant::now() })).unwrap();
    let mut buffer = vec![PremultipliedRgbaColor::default(); 1920 * 1240];
    let mut current: Option<Scene> = None;
    let mut last: Option<harness::Input> = None;
    let draw = |window: &MinimalSoftwareWindow, buffer: &mut [PremultipliedRgbaColor], stride: usize| -> u64 {
        let mut px = 0u64;
        window.draw_if_needed(|r| {
            let region = r.render(buffer, stride);
            px = region.iter().map(|(_, s)| s.width as u64 * s.height as u64).sum::<u64>().max(1);
        });
        px
    };
    harness::main(
        "slint-1.18.1",
        |scene, k| {
            let i = harness::input(scene, k);
            let c = current.get_or_insert_with(|| {
                let c = make(scene);
                match &c {
                    Scene::Form(c) => c.show().unwrap(),
                    Scene::List(c) => c.show().unwrap(),
                    Scene::Prose(c) => c.show().unwrap(),
                    Scene::Springs(c, ..) => c.show().unwrap(),
                }
                c
            });
            slint::platform::update_timers_and_animations();
            window.set_size(PhysicalSize::new(i.w as u32, i.h as u32));
            if last.is_none_or(|l| (l.px, l.py) != (i.px, i.py)) {
                window.dispatch_event(WindowEvent::PointerMoved { position: LogicalPosition::new(i.px, i.py) });
            }
            last = Some(i);
            match c {
                Scene::List(c) => c.set_content_y(-(i.scroll as f32)),
                Scene::Springs(_, widths, springs) => {
                    springs.step(i.tick, i.dt);
                    for (n, x) in springs.x.iter().enumerate() {
                        widths.set_row_data(n, *x);
                    }
                }
                _ => {}
            }
            draw(&window, &mut buffer, i.w as usize)
        },
        || {
            // Slint's own loop: run due timers, redraw if needed, sleep until the next timer or input.
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                harness::block_on_stdin();
                let _ = tx.send(());
            });
            let mut buffer = vec![PremultipliedRgbaColor::default(); 800 * 600];
            loop {
                slint::platform::update_timers_and_animations();
                draw(&window, &mut buffer, 800);
                let done = match slint::platform::duration_until_next_timer_update() {
                    Some(d) => rx.recv_timeout(d).is_ok(),
                    None => rx.recv().is_ok(),
                };
                if done {
                    return;
                }
            }
        },
    );
}
