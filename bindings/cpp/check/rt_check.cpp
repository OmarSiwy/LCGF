// The runtime front end from C++ (lcgf/runtime.hpp): bench/scenes/' scenes built each frame,
// their draw lists written in bindings/check/dump.zig's format for run.sh to compare with Zig.
//
//   lcgf-cpp-rt-check <form|list|text|springs|resize|idle|kit> <frames> <out.bin> [nodes depth]
//
// `kit` is the gate's own scene (bindings/check/rt_dump.zig's `Kit`): formatted text, the
// widgets by options, and springs and tweens on a colour and an array.
//   lcgf-cpp-rt-check rows <in.bin>   (lcgf-rt-dump rows' styles: lcgf::Row must equal Zig's rows)
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <vector>

#include "../scenes/scenes.hpp"

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

// A row made at compile time: the style is folded away, only the row is left in the binary.
constexpr lcgf::Row kPanel{lcgf::Style{.dir = lcgf::Dir::x, .size = {lcgf::Size::Px(120), lcgf::Size::Fill()}, .gap = 4}};
static_assert(kPanel.min[0] == 120 && kPanel.max[0] == 120 && kPanel.grow[1] == 1 && kPanel.main[0] == 1);
static_assert(kPanel.text == 0xffffffffu && kPanel.own == 0 && kPanel.radii[0] == 0);

int rows(const char* path) {
    std::ifstream file(path, std::ios::binary);
    const std::vector<char> data{std::istreambuf_iterator<char>(file), {}};
    constexpr std::size_t pair = sizeof(lcgf::Style) + sizeof(lcgf::Row);
    if (data.empty() || data.size() % pair != 0) return 2;
    std::size_t bad = 0;
    for (std::size_t off = 0; off < data.size(); off += pair) {
        lcgf::Style st;
        std::memcpy(&st, data.data() + off, sizeof st);
        const char* zig = data.data() + off + sizeof st;
        const lcgf::Row mine(st);
        lcgf_row lib;
        lcgf_template_from(st.raw(), &lib);
        if (std::memcmp(&mine, zig, sizeof mine) != 0 || std::memcmp(&lib, zig, sizeof lib) != 0) {
            if (bad++ < 5) {
                const auto* a = reinterpret_cast<const std::uint32_t*>(&mine);
                const auto* z = reinterpret_cast<const std::uint32_t*>(zig);
                for (int i = 0; i < 55; ++i)
                    if (a[i] != z[i]) std::fprintf(stderr, "style %zu word %d: C++ %08x, Zig %08x\n", off / pair, i, a[i], z[i]);
            }
        }
    }
    if (bad) std::fprintf(stderr, "%zu of %zu rows differ\n", bad, data.size() / pair);
    return bad ? 1 : 0;
}
// `lcgf-rt-dump ids`: each name's Id::From and its With(n) must be Zig's Id.hash and with.
int ids(const char* path) {
    std::ifstream file(path, std::ios::binary);
    const std::vector<char> data{std::istreambuf_iterator<char>(file), {}};
    auto word = [&](std::size_t at) { std::uint32_t w; std::memcpy(&w, data.data() + at, 4); return w; };
    std::size_t at = 0, bad = 0, n = 0;
    while (at + 4 <= data.size()) {
        const std::uint32_t len = word(at);
        const std::string_view name(data.data() + at + 4, len);
        at += 4 + len;
        const std::uint32_t k = word(at), zig = word(at + 4), zig_with = word(at + 8);
        at += 12;
        const lcgf::Id id = lcgf::Id::From(name);
        if (id.value != zig || id.With(k).value != zig_with) ++bad;
        ++n;
    }
    if (bad) std::fprintf(stderr, "%zu of %zu ids differ\n", bad, n);
    return bad || n == 0 ? 1 : 0;
}
// bindings/check/rt_dump.zig's `Act`: A7's first batch of Frame calls.
struct Act {
    static void input(lcgf::Input& in, std::uint32_t k) {
        in.viewport[0] = 400, in.viewport[1] = 300;
        in.pointer[0] = float((k * 11) % 300) + 0.5f, in.pointer[1] = float((k * 5) % 120) + 0.5f;
        in.dt = 1.0f / 60.0f;
    }

    static void build(lcgf::Frame& f, std::uint32_t k) {
        using namespace lcgf;
        f.Open(Id::From("act"), {.pad = {8, 8, 8, 8}, .gap = 6});
        f.FocusScope(f.Open(Id::From("row"), {.dir = Dir::x, .gap = 6}), 1);
        const lcgf_key keys[3] = {{0, 20, 0}, {0.5f, 90, std::uint8_t(Ease::out_cubic)}, {1, 40, 0}};
        const float w = f.Sequence(Id::From("seq"), keys);
        const Node hot = f.Leaf(Id::From("hot"), {.size = {Size::Px(w), Size::Px(30)}, .fill = Rgb(50, 50, 60)});
        const Response r = f.Interact(hot, 1 | 2 | 4);
        if (r.hovered()) f.SetFill(hot, Rgb(200, 120, 40));
        f.SetCursor(1, r.hovered());
        const auto d = f.Drag(Id::From("hot"));
        const Node card = f.Leaf(Id::From("card"), {.size = {Size::Px(60 + d[0]), Size::Px(24)}, .fill = Rgb(30, 30, 30)});
        const std::uint32_t tint = f.Transition(Id::From("tint"), r.held() ? Rgb(40, 160, 40) : Rgb(160, 40, 40), {0.25f, std::uint32_t(Ease::in_out)});
        f.SetFillAnimated(card, Id::From("cardfill"), tint, {0.5f, std::uint32_t(Ease::linear)});
        lcgf_outline o{2, Rgb(240, 240, 0), 1, {3, 3, 3, 3}, k % 2 == 0};
        if (k % 2 != 0) o.radii[0] = o.radii[1] = o.radii[2] = o.radii[3] = 0;
        f.Outline(card, o);
        f.AnimateLayout(card);
        f.Close();
        const lcgf_rect last = f.LastRect(Id::From("card"));
        const lcgf_rect held = f.HeldRect();
        f.Leaf(Id::From("echo"), {.size = {Size::Px(last.x1 - last.x0 + held.x1 - held.x0), Size::Px(8)}, .fill = Rgb(90, 90, 200)});
        f.Close();
    }
};

// bindings/check/rt_dump.zig's `Kit`, in this header's words.
struct Kit {
    bool on = false;
    float gain = 1;

    static void input(lcgf::Input& in, std::uint32_t k) {
        in.viewport[0] = 400, in.viewport[1] = 300;
        in.pointer[0] = float((k * 13) % 400) + 0.5f, in.pointer[1] = float((k * 7) % 120) + 0.5f;
        in.dt = 1.0f / 60.0f;
    }

    void build(lcgf::Frame& f, std::uint32_t k) {
        using namespace lcgf;
        f.Open(Id::From("kit"), {.pad = {8, 8, 8, 8}, .gap = 4});
        LabelF(f, "Frame {}: {:.2f}", k, float(k) * 0.25f);
        f.TextF({.px = 16, .color = Rgb(255, 200, 0)}, "items {}", k % 7);
        Button(f, Id::From("save"), {.label = "Save"});
        Checkbox(f, Id::From("loud"), on, {.label = "Loud"});
        Slider(f, Id::From("gain"), gain, {.min = 0, .max = 4});
        const bool phase = (k / 30) % 2 == 0;
        const Color ink = f.Animate(Id::From("ink"), Color::From(phase ? Rgb(200, 40, 40) : Rgb(40, 40, 200)));
        const auto box = f.Animate(Id::From("box"), std::array<float, 2>{phase ? 40.0f : 90.0f, 12});
        const float bar = f.Tween(Id::From("slide"), (k / 45) % 2 == 0 ? 20.0f : 120.0f, 0.5f, Ease::out_cubic);
        f.Leaf(Id::From("swatch"), Style{.size = {Size::Px(box[0]), Size::Px(box[1])}, .fill = ink.rgba()});
        f.Leaf(Id::From("bar"), Style{.size = {Size::Px(bar), Size::Px(6)}, .fill = Rgb(90, 90, 90)});
        // rt_dump.zig's styled subtree: participation all, hidden (1) and collapsed (0) in turn.
        const std::uint32_t part[3] = {15, 1, 0};
        f.Open(Id::From("styled"), {.participation = part[(k / 20) % 3], .cursor = 1, .dir = Dir::x, .gap = 4});
        const Node card = f.Leaf(Id::From("card"), Style{.size = {Size::Px(40), Size::Px(20)}, .fill = Rgb(60, 120, 60), .radii = {2, 6, 2, 6}});
        f.Leaf(Id::From("ring"), Style{.floating = 1, .border_color = Rgb(240, 240, 240), .border = 1, .paint_reference = card.row, .paint_outset = {2, 2, 2, 2}});
        f.Leaf(Id::From("tilt"), Style{.size = {Size::Px(20), Size::Px(20)}, .fill = Rgb(120, 60, 60), .transform = {1, 0.25f, 0, 1, 0, 0}, .transform_origin = {0, 0}});
        f.Leaf(Id::From("plain"), Style{.size = {Size::Px(10), Size::Px(10)}, .fill = Rgb(60, 60, 120)});
        f.Close();
        f.Close();
    }
};
// bindings/check/rt_dump.zig's `Plot`: a canvas batch through lcgf::Canvas, two canvas nodes.
struct Plot {
    static constexpr std::array<lcgf::canvas::Layer, 3> layers{{
        {0xffe6e6e6u, 0, 1, 3},
        {0xffffc85au, 0xb4a05a28u, 1.5f, 3},
        {0xff3c78ffu, 0xff3cc8ffu, 2, 2},
    }};
    static constexpr std::array<lcgf::canvas::Override, 1> marks{{{{2, 3}, 0xff00ff80u}}};
    static constexpr std::array<lcgf::canvas::Range, 1> sub{{{1, 4}}};
    std::unique_ptr<std::byte[]> mem;
    lcgf::Canvas s;
    std::array<lcgf::canvas::Range, 1> all{};

    static std::unique_ptr<std::byte[]> alloc() {
        return std::unique_ptr<std::byte[]>(new (std::align_val_t(lcgf::column_align)) std::byte[lcgf::Canvas::Bytes(32, 16, 8, true)]);
    }
    Plot() : mem(alloc()), s({mem.get(), lcgf::Canvas::Bytes(32, 16, 8, true)}, 32, 16, 8, true) {
        using namespace lcgf::canvas;
        for (std::uint32_t i = 0; i < 8; ++i) {
            const std::int32_t x = std::int32_t(i * 100);
            s.Segment({x, 0}, {x + 80, std::int32_t(50 * (i % 3))}, {.weight = std::uint8_t(i % 4 + 1), .cap = Cap(i % 3), .dash = std::uint8_t((i % 2) * 2)});
        }
        const std::array<Point, 4> chain{{{0, 200}, {150, 260}, {300, 200}, {450, 300}}};
        s.Polyline(chain, {.cap = Cap::round, .dash = 1});
        s.Rect({500, 0}, {700, 150}, {.layer = 1, .radius = 20});
        s.Circle({800, 100}, 60, {.layer = 2});
        s.Arc({100, 400}, 80, {.layer = 1, .cap = Cap::round, .dash = 2, .start = 0.5f, .sweep = 4});
        const std::array<Point, 4> quad{{{300, 350}, {500, 380}, {420, 500}, {350, 450}}};
        s.Polygon(quad, {.layer = 1, .stroke = true});
        s.Glyphs("Hi", {600, 400}, {.px = 40, .turns = 1});
        all[0] = {0, s.size()};
    }
    static void input(lcgf::Input& in, std::uint32_t k) {
        in.viewport[0] = 400, in.viewport[1] = 300;
        in.pointer[0] = float((k * 17) % 400) + 0.5f, in.pointer[1] = float((k * 11) % 300) + 0.5f;
        in.dt = 1.0f / 60.0f;
    }
    lcgf::canvas::Options options(std::uint32_t k, std::span<const lcgf::canvas::Range> ranges, std::span<const lcgf::canvas::Override> o) const {
        return {.camera = {.origin = {std::int64_t(k * 7), -std::int64_t(k * 3)}, .scale = 0.5f + 0.25f * float(k % 4), .offset = {10, 10}, .zoom = float(1 + k % 3)},
                .layers = layers,
                .zoom_scale = k % 2 == 1,
                .ranges = ranges,
                .overrides = o};
    }
    void build(lcgf::Frame& f, std::uint32_t k) {
        using namespace lcgf;
        if (k % 10 == 9) s.Kill((k / 10) % s.size());
        s.Mark((k * 5) % s.size(), k % 3 == 0 ? 0 : 0xff0000ffu | (k << 8));
        f.Open(Id::From("plot-root"), {.size = {Size::Fill(), Size::Fill()}});
        f.Canvas(Id::From("plot"), {.size = {Size::Fill(), Size::Fill()}}, s, options(k, all, marks));
        f.Canvas(Id::From("overlay"), {.size = {Size::Px(120), Size::Px(80)}, .floating = 1}, s, options(k, sub, {}));
        f.Close();
    }
};
} // namespace

int main(int argc, char** argv) {
    if (argc == 3 && std::strcmp(argv[1], "rows") == 0) return rows(argv[2]);
    if (argc == 3 && std::strcmp(argv[1], "ids") == 0) return ids(argv[2]);
    if (argc != 4 && argc != 6) return 2;
    const bool plot_scene = std::strcmp(argv[1], "canvas") == 0;
    const bool act_scene = std::strcmp(argv[1], "act") == 0;
    const bool kit_scene = plot_scene || act_scene || std::strcmp(argv[1], "kit") == 0;
    int s = 0;
    while (!kit_scene && s < scenes::count && std::strcmp(scenes::names[s], argv[1]) != 0) ++s;
    if (s == scenes::count) return 2;
    const auto scene = scenes::Scene(s);
    Kit kit;
    const std::uint32_t frames = std::uint32_t(std::atoi(argv[2]));
    // The style the library has for `Style{}` must be this header's: the words are the contract.
    lcgf_style lib_default;
    lcgf_style_default(&lib_default);
    const lcgf::Style mine{};
    if (std::memcmp(&lib_default, &mine, sizeof mine) != 0) {
        std::fprintf(stderr, "lcgf::Style{} is not the library's default style\n");
        return 1;
    }
    lcgf_limits l = scenes::limits(scene);
    if (kit_scene) l.nodes = l.texts = l.anims = 64;
    if (argc == 6) l.nodes = std::uint32_t(std::atoi(argv[4])), l.depth = std::uint32_t(std::atoi(argv[5]));
    const std::size_t bytes = lcgf::Context::Bytes(l);
    auto mem = std::unique_ptr<std::byte[]>(new (std::align_val_t(lcgf::column_align)) std::byte[bytes]);
    lcgf::Context ctx({mem.get(), bytes}, l);
    if (ctx.status() != lcgf::Status::ok) return 1;
    std::unique_ptr<Plot> plot;
    std::vector<std::byte> canvas_rows;
    if (plot_scene) {
        canvas_rows.resize(lcgf::Context::CanvasBytes(l));
        if (ctx.EnableCanvas(canvas_rows) != lcgf::Status::ok) return 1;
        plot = std::make_unique<Plot>();
        if (!plot->s.valid()) return 1;
    }
    std::vector<char> out;
    lcgf::Input in;
    for (std::uint32_t k = 0; k < frames; ++k) {
        if (plot_scene) Plot::input(in, k);
        else if (act_scene) Act::input(in, k);
        else if (kit_scene) Kit::input(in, k);
        else scenes::input(scene, in, k);
        // The bench scenes only hover; the gate also presses, so clicks and drags cross too.
        in.buttons = k % 6 < 2 ? lcgf::Input::left : 0;
        // Whether a frame is needed crosses the seam too (an `int` in lcgf.h).
        put(out, ctx.NeedsFrame(in) ? 1 : 0);
        lcgf::Frame f = ctx.Begin(in);
        if (plot_scene) plot->build(f, k);
        else if (act_scene) Act::build(f, k);
        else if (kit_scene) kit.build(f, k);
        else scenes::build(scene, f, ctx.theme());
        const lcgf::DrawList& d = ctx.End();
        put(out, std::uint32_t(d.quads().size()));
        put_bytes(out, d.quads());
        put(out, std::uint32_t(d.runs().size()));
        put_bytes(out, d.runs());
        put(out, std::uint32_t(d.strings().size()));
        out.insert(out.end(), d.strings().begin(), d.strings().end());
        put(out, d.command_count());
        for (std::uint32_t i = 0; i < d.command_count(); ++i) {
            const lcgf::Command c = d.command(i);
            put(out, std::uint32_t(c.kind));
            put(out, c.first);
            put(out, c.count);
            put(out, c.key);
        }
        put(out, std::uint32_t(d.customs().size()));
        put_bytes(out, d.customs());
        put(out, LCGF_NO_WIDGET);
        put(out, LCGF_NO_WIDGET);
        const float wake = ctx.wake();
        std::uint32_t bits;
        std::memcpy(&bits, &wake, 4);
        put(out, bits);
        if (plot_scene) {
            put(out, plot->s.size());
            put(out, plot->s.Hit(plot->options(k, plot->all, Plot::marks), in.pointer[0], in.pointer[1], 2));
            plot->s.ClearDirty();
        }
    }
    std::ofstream(argv[3], std::ios::binary).write(out.data(), std::streamsize(out.size()));
#if LCGF_LANES == 0
    // liblcgf_auto.a: the gate forces each width in turn, so a width it ran must be the one asked.
    if (const char* forced = std::getenv("LCGF_FORCE_LANES"); forced && lcgf_auto_lanes() != std::uint32_t(std::atoi(forced))) {
        std::fprintf(stderr, "LCGF_FORCE_LANES=%s ran %u lanes\n", forced, lcgf_auto_lanes());
        return 3;
    }
#endif
    return 0;
}
