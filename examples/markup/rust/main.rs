//! examples/markup's counter from Rust: ui/counter.html, lowered by lcgf-gen to the seam's
//! tables (`include_ui!`). The view state is the generated `counter::State`; the app polls the
//! frame's events and applies its own logic, as app.zig's handlers do. Headless: it clicks +
//! and checks the count, and exits non-zero when it is wrong.

// Relative to this crate; editing the HTML or its CSS rebuilds it.
lcgf::include_ui!("../ui/counter.html");

/// The centre of the text run that shows `text`: where a click lands on its button.
fn find(d: &lcgf::DrawList<'_>, text: &str) -> Option<[f32; 2]> {
    let r = d.runs().iter().find(|r| d.text(r) == text.as_bytes())?;
    Some([(r.rect[0] + r.rect[2]) / 2.0, (r.rect[1] + r.rect[3]) / 2.0])
}

/// One frame, then what app.zig's handlers do.
fn frame(ui: &mut counter::Ui<'_>, input: &lcgf::Input) {
    let (inc, dec) = {
        let f = ui.frame(input);
        (
            f.events.clicked(counter::Widget::Inc),
            f.events.clicked(counter::Widget::Dec),
        )
    };
    let s = *ui.state();
    let step = if s.by_ten { 10.0 } else { 1.0 };
    if inc {
        ui.set_count(s.count + step);
    }
    if dec {
        ui.set_count(s.count - step);
    }
    if inc || dec {
        ui.set_clicks((s.clicks + 1).min(8));
    }
}

fn main() {
    let mut buf = Box::new(lcgf::Buffer::<{ counter::BYTES }>::new());
    let mut ui = counter::Ui::new(&mut buf).expect("lcgf_ui_init");
    let mut input = lcgf::Input::default();
    input.pointer = find(&ui.frame(&input).draw, "+").expect("a + button");
    for buttons in [lcgf::Input::LEFT, 0] {
        input.buttons = buttons;
        frame(&mut ui, &input);
    }
    let quads = ui.frame(&input).draw.quads().len();
    let s = ui.state();
    println!(
        "Counter: count {} after one click on +, {quads} quads drawn",
        s.count
    );
    assert!(
        s.count == 1.0 && s.clicks == 1,
        "count {}, clicks {}",
        s.count,
        s.clicks
    );
}
