// examples/markup's counter from C++: ui/counter.html, lowered by lcgf-gen to the seam's tables
// (lcgf_add_ui). The view state is the generated counter::State; the app polls the frame's
// events and applies its own logic, as app.zig's handlers do. Headless: it clicks + and checks
// the count, and exits non-zero when it is wrong.
#include <cstdio>
#include <string_view>

#include "counter.lcgf.hpp"

namespace {

lcgf::Buffer<counter::bytes> buffer;

/// The centre of the text run that shows `text`: where a click lands on its button.
bool find(const lcgf::DrawList& d, std::string_view text, float at[2]) {
    for (const lcgf::TextRun& r : d.runs()) {
        if (d.text(r) != text) continue;
        at[0] = (r.rect[0] + r.rect[2]) / 2;
        at[1] = (r.rect[1] + r.rect[3]) / 2;
        return true;
    }
    return false;
}

/// What app.zig's handlers do, after each frame.
void handle(counter::Ui& ui) {
    const float step = ui.by_ten() ? 10.0f : 1.0f;
    const auto& ev = ui.events();
    if (ev.clicked(counter::Widget::inc)) ui.set_count(ui.count() + step);
    if (ev.clicked(counter::Widget::dec)) ui.set_count(ui.count() - step);
    if (ev.clicked(counter::Widget::inc) || ev.clicked(counter::Widget::dec))
        ui.set_clicks(ui.clicks() < 8 ? ui.clicks() + 1 : 8);
}

} // namespace

int main() {
    counter::Ui ui(buffer.span());
    if (ui.status() != lcgf::Status::ok) return 1;
    lcgf::Input in;
    float plus[2];
    if (!find(ui.frame(in), "+", plus)) return 1;
    in.pointer[0] = plus[0];
    in.pointer[1] = plus[1];
    for (std::uint32_t buttons : {lcgf::Input::left, 0u}) {
        in.buttons = buttons;
        ui.frame(in);
        handle(ui);
    }
    const std::size_t rows = ui.frame(in).quads().size();
    std::printf("Counter: count %g after one click on +, %zu quads drawn\n", static_cast<double>(ui.count()), rows);
    return ui.count() == 1.0f && ui.clicks() == 1 ? 0 : 1;
}
