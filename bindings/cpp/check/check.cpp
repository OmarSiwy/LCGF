// Runs a generated UI frame by frame and writes its draw lists in the dump format of
// bindings/check/dump.zig, so bindings/check/run.sh can compare C++ with Zig byte for byte.
//
//   lcgf-cpp-check <toolbar|mixer|panel> <inputs.txt> <out.bin>
//   lcgf-cpp-check <toolbar|mixer|panel> <inputs.txt> --bench   (ns per frame, 200 passes)
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "mixer.lcgf.hpp"
#include "panel.lcgf.hpp"
#include "toolbar.lcgf.hpp"

namespace {

void put(std::vector<char>& out, std::uint32_t v) {
    const char* p = reinterpret_cast<const char*>(&v);
    out.insert(out.end(), p, p + 4);
}

template <class T>
void put_bytes(std::vector<char>& out, std::span<const T> s) {
    const char* p = reinterpret_cast<const char*>(s.data());
    out.insert(out.end(), p, p + s.size_bytes());
}

template <class Widget>
void dump(std::vector<char>& out, const lcgf::DrawList& d, const lcgf::Events<Widget>& ev) {
    put(out, static_cast<std::uint32_t>(d.quads().size()));
    put_bytes(out, d.quads());
    put(out, static_cast<std::uint32_t>(d.runs().size()));
    put_bytes(out, d.runs());
    put(out, static_cast<std::uint32_t>(d.strings().size()));
    out.insert(out.end(), d.strings().begin(), d.strings().end());
    put(out, d.command_count());
    for (std::uint32_t i = 0; i < d.command_count(); ++i) {
        const lcgf::Command c = d.command(i);
        put(out, static_cast<std::uint32_t>(c.kind));
        put(out, c.first);
        put(out, c.count);
        put(out, c.key);
    }
    put(out, static_cast<std::uint32_t>(d.customs().size()));
    put_bytes(out, d.customs());
    const auto w = ev.widget();
    const auto f = ev.focus();
    put(out, w ? static_cast<std::uint32_t>(*w) : LCGF_NO_WIDGET);
    put(out, f ? static_cast<std::uint32_t>(*f) : LCGF_NO_WIDGET);
    const float wake = ev.wake();
    std::uint32_t bits;
    std::memcpy(&bits, &wake, 4);
    put(out, bits);
}

/// One line of the input script: a frame, or `set <field> <value>`.
struct Line {
    lcgf::Input in;
    bool set = false;
    std::string field;
    std::uint32_t value = 0;
};
const lcgf_key_event tab_press{0, 0, lcgf::Input::tab, 0, 0, 0};

/// The panel's fields `set` writes; other UIs have none.
template <class UiT>
void set(UiT&, const std::string&, std::uint32_t) {}
void set(panel::Ui& ui, const std::string& field, std::uint32_t v) {
    if (field == "len") ui.set_len(v);
    if (field == "mode") ui.set_mode(static_cast<std::uint8_t>(v));
}

bool bench = false;
const char* ui_name = "";

template <class UiT>
int run(UiT& ui, std::istream& inputs, std::vector<char>& out) {
    if (ui.status() != lcgf::Status::ok) {
        std::fprintf(stderr, "lcgf_ui_init: %d\n", static_cast<int>(ui.status()));
        return 1;
    }
    std::vector<Line> lines;
    std::string text;
    while (std::getline(inputs, text)) {
        std::istringstream f(text);
        Line l;
        if (text.rfind("set ", 0) == 0) {
            std::string word;
            f >> word >> l.field >> l.value;
            l.set = true;
            lines.push_back(l);
            continue;
        }
        unsigned buttons = 0, tabs = 0;
        if (!(f >> l.in.pointer[0] >> l.in.pointer[1] >> buttons)) continue;
        f >> tabs;
        l.in.buttons = buttons;
        if (tabs) l.in.keys({&tab_press, 1});
        lines.push_back(l);
    }
    if (bench) {
        std::uint32_t sink = 0;
        std::size_t n = 0;
        const int passes = 200;
        const auto t0 = std::chrono::steady_clock::now();
        for (int p = 0; p < passes; ++p)
            for (const Line& l : lines)
                if (!l.set) sink += static_cast<std::uint32_t>(ui.frame(l.in).quads().size()), ++n;
        const double ns = std::chrono::duration<double, std::nano>(std::chrono::steady_clock::now() - t0).count();
        std::printf("%s c++: %.0f ns/frame (sink %u)\n", ui_name, ns / static_cast<double>(n), sink);
        return 0;
    }
    for (const Line& l : lines) {
        if (l.set) {
            set(ui, l.field, l.value);
            continue;
        }
        const lcgf::DrawList& d = ui.frame(l.in);
        dump(out, d, ui.events());
    }
    return 0;
}

lcgf::Buffer<toolbar::bytes> toolbar_buffer;
lcgf::Buffer<mixer::bytes> mixer_buffer;
lcgf::Buffer<panel::bytes> panel_buffer;

} // namespace

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: lcgf-cpp-check <toolbar|mixer|panel> <inputs.txt> <out.bin>\n");
        return 2;
    }
    std::ifstream inputs(argv[2]);
    bench = std::strcmp(argv[3], "--bench") == 0;
    ui_name = argv[1];
    std::vector<char> out;
    int status;
    if (std::strcmp(argv[1], "mixer") == 0) {
        mixer::Ui ui(mixer_buffer.span());
        status = run(ui, inputs, out);
    } else if (std::strcmp(argv[1], "panel") == 0) {
        panel::Ui ui(panel_buffer.span());
        status = run(ui, inputs, out);
    } else {
        toolbar::Ui ui(toolbar_buffer.span());
        ui.set_layer("Layer 0"); // a setter: one store
        status = run(ui, inputs, out);
    }
    if (status != 0 || bench) return status;
    std::ofstream(argv[3], std::ios::binary).write(out.data(), static_cast<std::streamsize>(out.size()));
    return 0;
}
