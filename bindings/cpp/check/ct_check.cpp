#include <cstdlib>
// The C++ side of the static UIs' gate (bindings/check/run.sh): the comptime examples' `.zon`
// (src/abi/testdata/static/) through lcgf-gen --static and lcgf::StaticUi, over the frames of
// bindings/check/ct_dump.zig, dumped in its format. The dump must equal Zig's comptime pipeline's.
//
//   lcgf-cpp-ct-check <mixer|card|settings|badge|dash|todo|feed|controls> <frames> <out.bin|--bench> [seam]
//
// `seam` runs the UI through liblcgf (`SeamUi`); without it, through the passes compiled here
// (lcgf/ct.hpp, `Ui`).
//
// Field k of frame f's state is what src/abi/ct.zig's `stateFor` makes: a string
// `texts[(f + 3k) mod 7]`, a bool `(f + k) mod 3 != 0`, a count small or large on alternate
// frames, an enum `(f + k) mod 2`, an f32 `((131f + 17k) mod 5000) * 0.75`.
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <bit>
#include <string>
#include <string_view>
#include <vector>

#include "badge.lcgf.hpp"
#include "card.lcgf.hpp"
#include "palette.lcgf.hpp"
#include "controls.lcgf.hpp"
#include "dash.lcgf.hpp"
#include "feed.lcgf.hpp"
#include "meter.lcgf.hpp"
#include "mixer.lcgf.hpp"
#include "settings.lcgf.hpp"
#include "todo.lcgf.hpp"

namespace {

constexpr std::string_view texts[] = {"", "Mixer", "Battery 82%", "x", "a much longer label than its box", "Settings", "0123456789"};

lcgf::Str text(std::uint32_t f, std::uint32_t k) { return texts[(f + 3 * k) % std::size(texts)]; }
bool flag(std::uint32_t f, std::uint32_t k) { return (f + k) % 3 != 0; }
std::uint32_t count(std::uint32_t f, std::uint32_t k) { return f % 2 == 0 ? (f + k) % 11 : (7919 * f + k) % 200000; }
std::uint8_t pick(std::uint32_t f, std::uint32_t k) { return std::uint8_t((f + k) % 2); }
std::uint32_t color(std::uint32_t f, std::uint32_t k) {
    return ((13 * f + 40 * k) % 256) | (((7 * f) % 256) << 8) | (((90 * k) % 256) << 16) | (255u << 24);
}
float value(std::uint32_t f, std::uint32_t k) { return float((131 * f + 17 * k) % 5000) * 0.75f; }

std::array<float, 2> viewport(std::uint32_t f) {
    return {float(40 + (f * 37) % 761) + float(f % 4) / 4, float(30 + (f * 23) % 571)};
}

void put(std::vector<char>& o, std::uint32_t v) { o.insert(o.end(), reinterpret_cast<const char*>(&v), reinterpret_cast<const char*>(&v + 1)); }
template <class T>
void bytes(std::vector<char>& o, const T* p, std::size_t n) {
    o.insert(o.end(), reinterpret_cast<const char*>(p), reinterpret_cast<const char*>(p + n));
}

void dump(std::vector<char>& o, const lcgf::DrawList& list) {
    const lcgf_draw& d = list.raw();
    put(o, d.quad_len);
    bytes(o, d.quads, d.quad_len);
    put(o, d.run_len);
    bytes(o, d.runs, d.run_len);
    put(o, std::uint32_t(d.strings_len));
    bytes(o, d.strings, d.strings_len);
    put(o, d.cmd_len);
    bytes(o, d.cmd_kind, d.cmd_len);
    bytes(o, d.cmd_first, d.cmd_len);
    bytes(o, d.cmd_count, d.cmd_len);
    bytes(o, d.cmd_key, d.cmd_len);
}

// One UI's frames: `texts_of` sets the state's fields for frame f. `U` is the generated `Ui`
// (compiled against the tables) or `SeamUi` (liblcgf's frame).
// Frame f's input, as bindings/check/ct_dump.zig makes it.
lcgf::Input input_of(std::uint32_t f, lcgf_key_event* tab) {
    lcgf::Input in;
    in.pointer[0] = float(((f / 6) * 11) % 150 + f % 6) + 0.25f;
    in.pointer[1] = float(((f / 6) * 5) % 56) + 0.25f;
    in.buttons = f % 6 < 3 ? lcgf::Input::left : 0;
    *tab = {0, std::uint8_t(f % 15 == 5 ? lcgf::Input::shift : 0), lcgf::Input::tab, 0, 0, 0};
    if (f % 5 == 0) in.keys({tab, 1});
    return in;
}

template <class U>
concept HasEvents = requires(U& u, const lcgf::Input& in) { u.pointer(in); };

template <class U, class Set>
int run(const char* name, const char* how, U& ui, std::uint32_t frames, const char* out_path, Set texts_of) {
    const bool bench = std::strcmp(out_path, "--bench") == 0;
    std::vector<char> o, ev;
    long long best = -1;
    const int reps_ = std::getenv("LCGF_REPS") ? std::atoi(std::getenv("LCGF_REPS")) : 50;
    for (int rep = 0; rep < (bench ? reps_ : 1); ++rep) {
        const auto t0 = std::chrono::steady_clock::now();
        for (std::uint32_t f = 0; f < frames; ++f) {
            texts_of(ui.state, f);
            const auto vp = viewport(f);
            const lcgf::DrawList& d = ui.frame(vp[0], vp[1]);
            if (!bench) dump(o, d);
            if constexpr (HasEvents<U>) {
                if (!bench) {
                    lcgf_key_event tab;
                    const lcgf::Input in = input_of(f, &tab);
                    std::uint32_t row = 0xffffffffu, value = 0, focus = 0xffffffffu;
                    if (const auto e = ui.pointer(in)) {
                        row = std::uint32_t(e->widget);
                        value = std::bit_cast<std::uint32_t>(e->value);
                    }
                    ui.focus_keys(in);
                    if (const auto w = ui.focus()) focus = std::uint32_t(*w);
                    put(ev, row);
                    put(ev, value);
                    put(ev, focus);
                }
            }
        }
        const long long ns = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
        best = best < 0 ? ns : std::min(best, ns);
    }
    if (bench) {
        std::printf("ct %-9s %-7s %7lld ns/frame\n", name, how, best / frames);
        return 0;
    }
    std::ofstream(out_path, std::ios::binary).write(o.data(), std::streamsize(o.size()));
    if constexpr (HasEvents<U>)
        std::ofstream(std::string(out_path) + ".events", std::ios::binary).write(ev.data(), std::streamsize(ev.size()));
    return 0;
}

template <class Ns, class Set>
int run_ui(const char* name, bool seam, std::uint32_t frames, const char* out, Set set) {
    if (seam) {
        static lcgf::Buffer<Ns::bytes> buffer;
        static typename Ns::SeamUi ui(buffer.span());
        if (ui.status() != lcgf::Status::ok) {
            std::fprintf(stderr, "%s: refused (%d)\n", name, int(ui.status()));
            return 1;
        }
        return run(name, "c++/sm", ui, frames, out, set);
    }
    static typename Ns::Ui ui;
    return run(name, "c++", ui, frames, out, set);
}

// The generated namespaces, as types for run_ui.
#define LCGF_NS(n) \
    struct n##_ns { \
        using Ui = n::Ui; \
        using SeamUi = n::SeamUi; \
        static constexpr std::size_t bytes = n::bytes; \
    };
LCGF_NS(mixer)
LCGF_NS(card)
LCGF_NS(settings)
LCGF_NS(badge)
LCGF_NS(dash)
LCGF_NS(todo)
LCGF_NS(feed)
LCGF_NS(controls)
LCGF_NS(palette)
LCGF_NS(meter)

// `partial`: bindings/check/ct_dump.zig's relayout and patch replay. `full` sets frame f's
// state, `text` changes one label's field and lays it out again, `colors` changes and patches
// the colour fields.
template <class U, class Full, class Text, class Colors>
int run_partial(U& ui, std::uint32_t frames, const char* out_path, Full full, Text text, Colors colors) {
    std::vector<char> o;
    for (std::uint32_t f = 0; f < frames; ++f) {
        if (f % 4 == 0) {
            full(ui.state, f);
            const auto vp = viewport(f);
            ui.frame(vp[0], vp[1]);
        } else if (f % 4 < 3) {
            text(ui, f);
        } else {
            ui.clear_dirty();
            colors(ui, f);
        }
        dump(o, ui.draw());
        for (bool b : ui.dirty()) o.push_back(char(b));
    }
    std::ofstream(out_path, std::ios::binary).write(o.data(), std::streamsize(o.size()));
    return 0;
}

int partial(std::string_view ui, std::uint32_t frames, const char* out) {
    const auto none = [](auto&, std::uint32_t) {};
    if (ui == "mixer") {
        static mixer::Ui u;
        return run_partial(u, frames, out, [](mixer::State& s, std::uint32_t f) {
            s.title = text(f, 0); s.volume = value(f, 1); s.muted = flag(f, 2); s.pan = value(f, 3); }, [](mixer::Ui& u, std::uint32_t f) {
            u.state.title = text(f, 0);
            u.relayout<mixer::Field::title>(); }, none);
    }
    if (ui == "dash") {
        static dash::Ui u;
        return run_partial(u, frames, out, [](dash::State& s, std::uint32_t f) {
            s.title = text(f, 0); s.a = text(f, 1); s.b = text(f, 2); s.c = text(f, 3); s.level = value(f, 4); }, [](dash::Ui& u, std::uint32_t f) {
            switch ((f / 4 + f % 4) % 4) {
            case 0: u.state.title = text(f, 0); u.relayout<dash::Field::title>(); break;
            case 1: u.state.a = text(f, 1); u.relayout<dash::Field::a>(); break;
            case 2: u.state.b = text(f, 2); u.relayout<dash::Field::b>(); break;
            default: u.state.c = text(f, 3); u.relayout<dash::Field::c>(); break;
            } }, none);
    }
    if (ui == "todo") {
        static todo::Ui u;
        return run_partial(u, frames, out, [](todo::State& s, std::uint32_t f) {
            s.title = text(f, 0); s.len = count(f, 1); s.footer = flag(f, 2); s.mode = pick(f, 3); }, [](todo::Ui& u, std::uint32_t f) {
            u.state.title = text(f, 0);
            u.relayout<todo::Field::title>(); }, none);
    }
    if (ui == "palette") {
        static palette::Ui u;
        return run_partial(u, frames, out, [](palette::State& s, std::uint32_t f) {
            s.title = text(f, 0); s.accent = color(f, 1); s.edge = color(f, 2); }, [](palette::Ui& u, std::uint32_t f) {
            u.state.title = text(f, 0);
            u.relayout<palette::Field::title>(); }, [](palette::Ui& u, std::uint32_t f) {
            u.state.accent = color(f, 1);
            u.patch<palette::Field::accent>();
            u.state.edge = color(f, 2);
            u.patch<palette::Field::edge>(); });
    }
    if (ui == "meter") {
        static meter::Ui u;
        return run_partial(u, frames, out, [](meter::State& s, std::uint32_t f) {
            s.name = text(f, 0); s.level = value(f, 1); s.count = count(f, 2); s.on = flag(f, 3); s.peak = value(f, 4); }, [](meter::Ui& u, std::uint32_t f) {
            // Every field is shown by a formatted label: ct_dump's `labelFields` cycles them all.
            switch ((f / 4 + f % 4) % 5) {
            case 0: u.state.name = text(f, 0); u.relayout<meter::Field::name>(); break;
            case 1: u.state.level = value(f, 1); u.relayout<meter::Field::level>(); break;
            case 2: u.state.count = count(f, 2); u.relayout<meter::Field::count>(); break;
            case 3: u.state.on = flag(f, 3); u.relayout<meter::Field::on>(); break;
            default: u.state.peak = value(f, 4); u.relayout<meter::Field::peak>(); break;
            } }, none);
    }
    std::fprintf(stderr, "no partial replay for %s\n", std::string(ui).c_str());
    return 2;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: lcgf-cpp-ct-check <ui> <frames> <out.bin|--bench> [seam]\n");
        return 2;
    }
    const std::string_view ui = argv[1];
    const auto frames = std::uint32_t(std::strtoul(argv[2], nullptr, 10));
    const char* out = argv[3];
    const bool seam = argc > 4 && std::strcmp(argv[4], "seam") == 0;
    if (argc > 4 && std::strcmp(argv[4], "partial") == 0) return partial(ui, frames, out);
    if (ui == "mixer")
        return run_ui<mixer_ns>("mixer", seam, frames, out, [](mixer::State& s, std::uint32_t f) {
            s.title = text(f, 0);
            s.volume = value(f, 1);
            s.muted = flag(f, 2);
            s.pan = value(f, 3);
        });
    if (ui == "card")
        return run_ui<card_ns>("card", seam, frames, out, [](card::State& s, std::uint32_t f) {
            s.heading = text(f, 0);
            s.body = text(f, 1);
        });
    if (ui == "settings")
        return run_ui<settings_ns>("settings", seam, frames, out, [](settings::State& s, std::uint32_t f) {
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
        });
    if (ui == "badge")
        return run_ui<badge_ns>("badge", seam, frames, out, [](badge::State& s, std::uint32_t f) {
            s.name = text(f, 0);
            s.level = value(f, 1);
        });
    if (ui == "dash")
        return run_ui<dash_ns>("dash", seam, frames, out, [](dash::State& s, std::uint32_t f) {
            s.title = text(f, 0);
            s.a = text(f, 1);
            s.b = text(f, 2);
            s.c = text(f, 3);
            s.level = value(f, 4);
        });
    if (ui == "todo")
        return run_ui<todo_ns>("todo", seam, frames, out, [](todo::State& s, std::uint32_t f) {
            s.title = text(f, 0);
            s.len = count(f, 1);
            s.footer = flag(f, 2);
            s.mode = pick(f, 3);
        });
    if (ui == "controls")
        return run_ui<controls_ns>("controls", seam, frames, out, [](controls::State& s, std::uint32_t f) {
            s.title = text(f, 0);
            s.muted = flag(f, 1);
            s.volume = value(f, 2);
            s.pan = value(f, 3);
        });
    if (ui == "palette")
        return run_ui<palette_ns>("palette", seam, frames, out, [](palette::State& s, std::uint32_t f) {
            s.title = text(f, 0);
            s.accent = color(f, 1);
            s.edge = color(f, 2);
        });
    if (ui == "meter")
        return run_ui<meter_ns>("meter", seam, frames, out, [](meter::State& s, std::uint32_t f) {
            s.name = text(f, 0);
            s.level = value(f, 1);
            s.count = count(f, 2);
            s.on = flag(f, 3);
            s.peak = value(f, 4);
        });
    if (ui == "feed")
        return run_ui<feed_ns>("feed", seam, frames, out, [](feed::State& s, std::uint32_t f) {
            s.count = count(f, 0);
            s.scroll = value(f, 1);
        });
    std::fprintf(stderr, "unknown ui %s\n", argv[1]);
    return 2;
}
