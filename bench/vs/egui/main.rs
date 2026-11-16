//! The scenes of bench/scenes/ on egui (https://github.com/emilk/egui), for the comparison of
//! docs/perf/vs.md. A frame is `Context::run_ui` (input, widgets, layout, shapes) plus
//! `Context::tessellate` (shapes to triangle meshes, text included as glyph quads), which is what
//! egui hands a renderer. That matches tools/bench's `frame` (build, layout, paint into a draw
//! list); neither rasterises. No window and no eframe: egui alone, with its default fonts at 14 and
//! 20 px. Springs come from bench/vs/harness.rs (egui's own animation helpers are tweens).
//!
//! The idle scene builds a frame only when an eframe host would: on new input or when the last
//! frame asked for a repaint (`repaint_delay` zero). Idle wake-ups cannot be probed without
//! eframe's window loop, so `--idle` blocks on stdin like the C harnesses.
#[path = "../harness.rs"]
mod harness;

use egui::{Align, Color32, Event, Frame, Layout, Pos2, RawInput, Rect, RichText, Sense, TextStyle, UiBuilder, vec2};

const PANEL: Color32 = Color32::from_rgb(30, 31, 36);
const CONTROL: Color32 = Color32::from_rgb(58, 60, 70);
const ACCENT: Color32 = Color32::from_rgb(90, 140, 255);

struct State {
    fields: Vec<String>,
    checks: [bool; 21],
    values: [f32; 21],
    springs: harness::Springs,
}

fn form(ui: &mut egui::Ui, s: &mut State) {
    ui.spacing_mut().item_spacing = vec2(6.0, 4.0);
    ui.label(RichText::new("Account settings").size(20.0));
    ui.separator();
    for r in 0..21 {
        ui.horizontal(|ui| {
            ui.add_sized([90.0, 18.0], egui::Label::new(harness::FORM_NAMES[r]));
            ui.add(egui::TextEdit::singleline(&mut s.fields[r]).desired_width(220.0));
            ui.checkbox(&mut s.checks[r], "On");
            ui.add(egui::Slider::new(&mut s.values[r], 0.0..=1.0));
        });
    }
    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
        let _ = ui.button("Save");
        let _ = ui.button("Reset");
        let _ = ui.button("Cancel");
    });
}

fn list(ui: &mut egui::Ui, scroll: u32) {
    ui.spacing_mut().item_spacing = vec2(6.0, 0.0);
    egui::ScrollArea::vertical().vertical_scroll_offset(scroll as f32).show_rows(ui, 24.0, 100_000, |ui, rows| {
        for r in rows {
            let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 24.0), Sense::hover());
            ui.painter().rect_filled(rect, 0.0, if r % 2 == 1 { CONTROL } else { PANEL });
            let inner = rect.shrink2(vec2(8.0, 0.0));
            ui.scope_builder(UiBuilder::new().max_rect(inner).layout(Layout::left_to_right(Align::Center)), |ui| {
                ui.label(format!("Row {r}"));
                ui.label(harness::LIST_NAMES[r % 7]);
                let (dot, _) = ui.allocate_exact_size(vec2(12.0, 12.0), Sense::hover());
                ui.painter().rect_filled(dot, 0.0, ACCENT);
            });
        }
    });
}

fn prose(ui: &mut egui::Ui) {
    egui::Panel::left("sidebar").exact_size(160.0).resizable(false).show(ui, |ui| {
        ui.spacing_mut().item_spacing = vec2(6.0, 2.0);
        for i in 0..120 {
            ui.label(format!("Chapter {}", i + 1));
        }
    });
    egui::CentralPanel::default_margins().show(ui, |ui| {
        ui.spacing_mut().item_spacing = vec2(6.0, 8.0);
        for s in 0..12 {
            ui.label(RichText::new(format!("Section {}", s + 1)).size(20.0));
            for p in 0..4 {
                ui.label(harness::PROSE[(s + p) % 4]);
            }
        }
    });
}

fn springs(ui: &mut egui::Ui, s: &mut State, tick: u32, dt: f32) {
    s.springs.step(tick, dt);
    ui.spacing_mut().item_spacing = vec2(2.0, 2.0);
    for r in 0..40 {
        ui.horizontal(|ui| {
            for c in 0..25 {
                let (rect, _) = ui.allocate_exact_size(vec2(s.springs.x[r * 25 + c], 16.0), Sense::hover());
                ui.painter().rect_filled(rect, 0.0, ACCENT);
            }
        });
    }
}

fn main() {
    let ctx = egui::Context::default();
    ctx.global_style_mut(|st| {
        st.text_styles.get_mut(&TextStyle::Body).unwrap().size = 14.0;
        st.text_styles.get_mut(&TextStyle::Button).unwrap().size = 14.0;
    });
    let mut s = State {
        fields: harness::FORM_NAMES.iter().map(|n| n.to_string()).collect(),
        checks: [false; 21],
        values: [0.5; 21],
        springs: Default::default(),
    };
    let mut last: Option<harness::Input> = None;
    let mut repaint = true;
    let mut time = 0.0;
    harness::main(
        "egui-0.37.0",
        |scene, k| {
            let i = harness::input(scene, k);
            let changed = last != Some(i);
            if scene == harness::IDLE && !changed && !repaint {
                return 0;
            }
            last = Some(i);
            time += i.dt as f64;
            let raw = RawInput {
                screen_rect: Some(Rect::from_min_size(Pos2::ZERO, vec2(i.w, i.h))),
                time: Some(time),
                predicted_dt: i.dt,
                events: if changed { vec![Event::PointerMoved(Pos2::new(i.px, i.py))] } else { vec![] },
                ..Default::default()
            };
            let out = ctx.run_ui(raw, |ui| match scene {
                harness::TEXT | harness::RESIZE => prose(ui),
                _ => {
                    let pad = if scene == harness::LIST { 0 } else if scene == harness::SPRINGS { 8 } else { 12 };
                    egui::CentralPanel::no_frame().frame(Frame::NONE.inner_margin(pad).fill(PANEL)).show(ui, |ui| match scene {
                        harness::LIST => list(ui, i.scroll),
                        harness::SPRINGS => springs(ui, &mut s, i.tick, i.dt),
                        _ => form(ui, &mut s),
                    });
                }
            });
            repaint = out.viewport_output.values().any(|v| v.repaint_delay.is_zero());
            let meshes = ctx.tessellate(out.shapes, out.pixels_per_point);
            meshes
                .iter()
                .map(|m| match &m.primitive {
                    egui::epaint::Primitive::Mesh(mesh) => mesh.vertices.len() as u64,
                    _ => 0,
                })
                .sum::<u64>()
                .max(1)
        },
        harness::block_on_stdin,
    );
}
