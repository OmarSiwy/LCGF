// The scenes of bench/scenes/ (form, list, text, springs, resize, idle) written with
// lcgf/runtime.hpp, line for line as the Zig ones: bindings/check/run.sh compares their frames
// with Zig's byte for byte, and bench/vs/lcgf-cpp times them beside the other harnesses.
#pragma once
#include <charconv>
#include <cstdio>
#include <string_view>

#include <lcgf/runtime.hpp>

namespace scenes {

enum Scene { form,
             list,
             text,
             springs,
             resize,
             idle,
             count };
inline constexpr const char* names[count] = {"form", "list", "text", "springs", "resize", "idle"};
/// Nodes per scene (bench/vs/harness.h's vs_capacity).
inline constexpr std::uint32_t capacity[count] = {256, 256, 256, 2048, 256, 256};

inline lcgf_limits limits(Scene s) {
    lcgf_limits l{};
    l.nodes = capacity[s];
    l.texts = capacity[s];
    l.customs = 64;
    l.strings = 32 * 1024;
    l.anims = capacity[s];
    l.depth = 64;
    return l;
}

inline constexpr std::string_view form_names[21] = {
    "Name",
    "Email",
    "Phone",
    "Street",
    "City",
    "Postcode",
    "Country",
    "Company",
    "Title",
    "Team",
    "Manager",
    "Website",
    "Timezone",
    "Language",
    "Currency",
    "Theme",
    "Font",
    "Density",
    "Backup",
    "Sync",
    "Alerts",
};
inline bool checks[21] = {};
inline float values[21] = {0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f,
                           0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f, 0.5f};

inline constexpr std::uint32_t total = 100000, row_h = 24, visible = 800 / row_h + 2;
inline constexpr std::string_view list_names[7] = {"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"};
inline std::uint32_t scroll = 0;
inline std::uint32_t tick = 0;

inline constexpr std::string_view prose[4] = {
    "Columns of rows replace trees of objects: every pass walks a few dense arrays from start to end, so the cache sees one stream per field and the vector units take eight rows at a time.",
    "A frame is rebuilt from scratch, laid out in a handful of passes and painted into a draw list that a renderer submits as it is. Nothing outlives the frame except what the caller keeps.",
    "Text is measured once per run and wrapped against the width the layout grants; lines break at spaces, and a word wider than the line is broken where it overflows.",
    "Idle costs nothing: when no input arrives and no spring moves, no frame is built, so the process sleeps until the next event and the battery is left alone.",
};

using lcgf::Align, lcgf::Dir, lcgf::Id, lcgf::Size;

inline void input(Scene s, lcgf::Input& in, std::uint32_t k) {
    switch (s) {
    case form:
        in.viewport[0] = 800, in.viewport[1] = 600;
        in.pointer[0] = float(20 + (k * 7) % 760), in.pointer[1] = float(20 + (k * 13) % 560);
        break;
    case list:
        in.viewport[0] = 1280, in.viewport[1] = 800;
        in.pointer[0] = 640, in.pointer[1] = float(10 + (k * 13) % 780);
        scroll = (k * 997) % (total * row_h - 800);
        break;
    case text:
        in.viewport[0] = 1280, in.viewport[1] = 800;
        in.pointer[0] = float(20 + (k * 7) % 1240), in.pointer[1] = float(20 + (k * 13) % 760);
        break;
    case springs:
        in.viewport[0] = 1280, in.viewport[1] = 800;
        in.dt = 1.0f / 60.0f;
        tick = k;
        break;
    case resize:
        in.viewport[0] = float(320 + (k * 37) % 1600), in.viewport[1] = float(240 + (k * 53) % 1000);
        in.pointer[0] = 100, in.pointer[1] = 100;
        break;
    default:
        in.viewport[0] = 800, in.viewport[1] = 600;
        in.pointer[0] = 400, in.pointer[1] = 300;
    }
}

inline void build_form(lcgf::Frame& f, const lcgf::Theme& th) {
    const Id base = Id::From("form");
    f.Open(base, {.size = {Size::Fill(), Size::Fill()}, .pad = {12, 12, 12, 12}, .gap = 4, .fill = th.panel});
    f.Text("Account settings", {.px = 20, .color = th.text});
    f.Leaf(Id::none, {.size = {Size::Fill(), Size::Px(1)}, .fill = th.control_hot});
    for (std::uint32_t r = 0; r < 21; ++r) {
        const Id id = base.With(r);
        f.Open(id, {.dir = Dir::x, .size = {Size::Fill(), Size::Fit()}, .gap = th.gap, .cross = Align::center});
        f.TextStyled(form_names[r], {.px = th.text_px, .color = th.text}, {.size = {Size::Px(90), Size::Fit()}});
        f.Open(id.With(1), {.size = {Size::Grow(1), Size::Fit()}, .pad = {4, 4, 4, 4}, .fill = th.control, .border_color = th.control_hot, .border = 1, .radius = th.radius});
        lcgf::Label(f, form_names[r]);
        f.Close();
        lcgf::Checkbox(f, id.With(2), checks[r], "On");
        lcgf::Slider(f, id.With(3), values[r], 0, 1);
        f.Close();
    }
    f.Open(base.With(1000), {.dir = Dir::x, .size = {Size::Fill(), Size::Fit()}, .gap = th.gap, .main = Align::end});
    lcgf::Button(f, base.With(1001), "Cancel");
    lcgf::Button(f, base.With(1002), "Reset");
    lcgf::Button(f, base.With(1003), "Save");
    f.Close();
    f.Close();
}

// `prefix` and `n` in decimal into `buf`, as Zig's scenes format with bufPrint("{d}"): a parity
// scene measures the bindings, not printf against Zig's formatter.
inline std::string_view Decimal(char (&buf)[16], std::string_view prefix, std::uint32_t n) {
    prefix.copy(buf, prefix.size());
    return {buf, std::size_t(std::to_chars(buf + prefix.size(), buf + sizeof buf, n).ptr - buf)};
}

inline void build_list(lcgf::Frame& f, const lcgf::Theme& th) {
    const std::uint32_t first = scroll / row_h;
    const std::uint32_t end = first + visible < total ? first + visible : total;
    f.Open(Id::From("list"), {.size = {Size::Fill(), Size::Fill()}, .clip = 1, .scroll = {0, float(scroll)}});
    f.Leaf(Id::none, {.size = {Size::Fill(), Size::Px(float(first * row_h))}});
    const std::uint32_t fills[2] = {th.panel, th.control};
    char buf[16];
    for (std::uint32_t r = first; r < end; ++r) {
        f.Open(Id::none, {.dir = Dir::x, .size = {Size::Fill(), Size::Px(row_h)}, .pad = {8, 0, 8, 0}, .gap = th.gap, .cross = Align::center, .fill = fills[r % 2]});
        lcgf::Label(f, Decimal(buf, "Row ", r));
        lcgf::Label(f, list_names[r % 7]);
        f.Leaf(Id::none, {.size = {Size::Px(12), Size::Px(12)}, .fill = th.accent});
        f.Close();
    }
    f.Leaf(Id::none, {.size = {Size::Fill(), Size::Px(float((total - end) * row_h))}});
    f.Close();
}

inline void build_text(lcgf::Frame& f, const lcgf::Theme& th) {
    f.Open(Id::From("text"), {.dir = Dir::x, .size = {Size::Fill(), Size::Fill()}, .pad = {12, 12, 12, 12}, .gap = 16, .clip = 1});
    f.Open(Id::none, {.size = {Size::Px(160), Size::Fill()}, .gap = 2});
    char buf[16];
    for (int i = 0; i < 120; ++i) {
        lcgf::Label(f, Decimal(buf, "Chapter ", std::uint32_t(i + 1)));
    }
    f.Close();
    f.Open(Id::none, {.size = {Size::Grow(1), Size::Fit()}, .gap = 8, .shrink = 1});
    for (int s = 0; s < 12; ++s) {
        f.Text(Decimal(buf, "Section ", std::uint32_t(s + 1)), {.px = 20, .color = th.text});
        for (int p = 0; p < 4; ++p) f.Text(prose[(s + p) % 4], {.px = th.text_px, .color = th.text, .wrap = 1});
    }
    f.Close();
    f.Close();
}

inline void build_springs(lcgf::Frame& f, const lcgf::Theme& th) {
    const Id base = Id::From("springs");
    const float targets[2] = {4, 40};
    f.Open(base, {.size = {Size::Fill(), Size::Fill()}, .pad = {8, 8, 8, 8}, .gap = 2});
    for (std::uint32_t r = 0; r < 40; ++r) {
        f.Open(Id::none, {.dir = Dir::x, .gap = 2});
        for (std::uint32_t c = 0; c < 25; ++c) {
            const std::uint32_t i = r * 25 + c;
            const float w = f.Animate(base.With(i), targets[(tick / 30 + i) % 2]);
            f.Leaf(Id::none, {.size = {Size::Px(w), Size::Px(16)}, .fill = th.accent});
        }
        f.Close();
    }
    f.Close();
}

inline void build(Scene s, lcgf::Frame& f, const lcgf::Theme& th) {
    switch (s) {
    case form:
    case idle: build_form(f, th); break;
    case list: build_list(f, th); break;
    case text:
    case resize: build_text(f, th); break;
    default: build_springs(f, th);
    }
}

/// Built every poll: their state changes outside the input (bench/scenes `every`).
inline bool every(Scene s) { return s == list || s == springs; }

} // namespace scenes
