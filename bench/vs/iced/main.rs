//! The scenes of bench/scenes/ on Iced 0.14 (https://github.com/iced-rs/iced), for the comparison of
//! docs/perf/vs.md. Iced is Elm-style: each frame the view is rebuilt from the state. A frame here is
//! what iced_winit does per redraw, without the window: `view`, `UserInterface::build` (diff against
//! the widget tree cache and layout), `update` with that frame's events, and `draw` into the
//! tiny-skia renderer, which records layers of primitives (quads, text) and rasterises only on
//! `present`. That matches tools/bench's `frame` (build, layout, paint into a draw list); neither
//! rasterises. Text is shaped and laid out by cosmic-text with the font Iced embeds (Fira Sans) at
//! 14 and 20 px; Iced keeps each text's layout in its widget tree between frames. Springs come from
//! bench/vs/harness.rs.
//!
//! The idle scene builds a frame only when iced_winit would: on new input or when the last update
//! asked for a redraw. Idle wake-ups cannot be probed without iced_winit's window loop, so `--idle`
//! blocks on stdin like the C harnesses.
#[path = "../harness.rs"]
mod harness;

use iced_core::widget::operation::scrollable::{AbsoluteOffset, scroll_to};
use iced_core::{Background, Color, Element, Event, Font, Length, Pixels, Point, Size, Theme, mouse, renderer, window};
use iced_runtime::user_interface::{self, UserInterface};
use iced_tiny_skia::Renderer;
use iced_widget::{button, checkbox, column, container, row, rule, scrollable, slider, space, text, text_input};

const PANEL: Color = Color::from_rgb8(30, 31, 36);
const CONTROL: Color = Color::from_rgb8(58, 60, 70);
const ACCENT: Color = Color::from_rgb8(90, 140, 255);

type El<'a> = Element<'a, (), Theme, Renderer>;

struct State {
    fields: Vec<String>,
    checks: [bool; 21],
    values: [f32; 21],
    springs: harness::Springs,
}

fn fill(c: Color) -> impl Fn(&Theme) -> container::Style {
    move |_| container::Style { background: Some(Background::Color(c)), ..Default::default() }
}

fn form(s: &State) -> El<'_> {
    let mut col = column![text("Account settings").size(20), rule::horizontal(1)].spacing(4).padding(12);
    for r in 0..21 {
        col = col.push(
            row![
                text(harness::FORM_NAMES[r]).width(90),
                text_input("", &s.fields[r]).on_input(|_| ()).width(Length::Fill),
                checkbox(s.checks[r]).label("On").on_toggle(|_| ()),
                slider(0.0..=1.0, s.values[r], |_| ()).step(0.01_f32),
            ]
            .spacing(6)
            .align_y(iced_core::alignment::Vertical::Center),
        );
    }
    col = col.push(row![space::horizontal(), button("Cancel"), button("Reset"), button("Save")].spacing(6));
    container(col).width(Length::Fill).height(Length::Fill).style(fill(PANEL)).into()
}

fn list(scroll: u32) -> El<'static> {
    const ROW_H: u32 = 24;
    let first = scroll / ROW_H;
    let end = (first + 800 / ROW_H + 2).min(100_000);
    let mut col = column![space().height((first * ROW_H) as f32)];
    for r in first..end {
        let bg = if r % 2 == 1 { CONTROL } else { PANEL };
        col = col.push(
            container(
                row![text(format!("Row {r}")), text(harness::LIST_NAMES[r as usize % 7]), container(space()).width(12).height(12).style(fill(ACCENT))]
                    .spacing(6)
                    .align_y(iced_core::alignment::Vertical::Center),
            )
            .padding([0, 8])
            .width(Length::Fill)
            .height(ROW_H as f32)
            .align_y(iced_core::alignment::Vertical::Center)
            .style(fill(bg)),
        );
    }
    col = col.push(space().height(((100_000 - end) * ROW_H) as f32));
    scrollable(col).id("list").width(Length::Fill).height(Length::Fill).into()
}

fn prose() -> El<'static> {
    let side = column((0..120).map(|i| text(format!("Chapter {}", i + 1)).into())).spacing(2).width(160);
    let mut main = column![].spacing(8).width(Length::Fill);
    for s in 0..12 {
        main = main.push(text(format!("Section {}", s + 1)).size(20));
        for p in 0..4 {
            main = main.push(text(harness::PROSE[(s + p) % 4]));
        }
    }
    container(row![side, main].spacing(16).padding(12)).clip(true).width(Length::Fill).height(Length::Fill).into()
}

fn springs(s: &State) -> El<'_> {
    let mut col = column![].spacing(2).padding(8);
    for r in 0..40 {
        col = col.push(row((0..25).map(|c| container(space()).width(s.springs.x[r * 25 + c]).height(16).style(fill(ACCENT)).into())).spacing(2));
    }
    col.into()
}

fn main() {
    let mut renderer = Renderer::new(Font::DEFAULT, Pixels(14.0));
    let theme = Theme::Dark;
    let mut s = State {
        fields: harness::FORM_NAMES.iter().map(|n| n.to_string()).collect(),
        checks: [false; 21],
        values: [0.5; 21],
        springs: Default::default(),
    };
    let mut cache = Some(user_interface::Cache::default());
    let mut last: Option<harness::Input> = None;
    let mut redraw = true;
    let mut messages = Vec::new();
    let mut clipboard = iced_core::clipboard::Null;
    harness::main(
        "iced-0.14.0",
        |scene, k| {
            let i = harness::input(scene, k);
            let changed = last != Some(i);
            if scene == harness::IDLE && !changed && !redraw {
                return 0;
            }
            last = Some(i);
            if scene == harness::SPRINGS {
                s.springs.step(i.tick, i.dt);
            }
            let view = match scene {
                harness::LIST => list(i.scroll),
                harness::TEXT | harness::RESIZE => prose(),
                harness::SPRINGS => springs(&s),
                _ => form(&s),
            };
            let size = Size::new(i.w, i.h);
            let mut ui = UserInterface::build(view, size, cache.take().unwrap(), &mut renderer);
            if scene == harness::LIST {
                let mut op = scroll_to("list".into(), AbsoluteOffset { x: None, y: Some(i.scroll as f32) });
                ui.operate(&renderer, &mut op);
            }
            let cursor = mouse::Cursor::Available(Point::new(i.px, i.py));
            let events: Vec<Event> = if changed {
                vec![Event::Mouse(mouse::Event::CursorMoved { position: Point::new(i.px, i.py) })]
            } else {
                vec![]
            };
            let (state, _) = ui.update(&events, cursor, &mut renderer, &mut clipboard, &mut messages);
            redraw = matches!(state, user_interface::State::Outdated)
                || matches!(state, user_interface::State::Updated { redraw_request, .. } if redraw_request != window::RedrawRequest::Wait);
            ui.draw(&mut renderer, &theme, &renderer::Style { text_color: Color::from_rgb8(230, 230, 235) }, cursor);
            cache = Some(ui.into_cache());
            messages.clear();
            renderer.layers().iter().count() as u64 + 1
        },
        harness::block_on_stdin,
    );
}
