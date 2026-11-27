// lcgf/runtime.hpp: LCGF's runtime front end for C++20: build the UI each frame in code, as a
// Zig program does with `ctx.begin(&in)` and `f.open(...)`. A style becomes its row here
// (`Row`, folded at compile time when the style is constant), and `Open` and `Leaf` store it
// into the frame's columns inline (lcgf_frame_view); the rest is one direct call each into the
// prebuilt liblcgf (lcgf.h, generated from src/abi/api.zig). Your buffer holds everything.
//
//   lcgf::Context ctx(buffer, limits);
//   lcgf::Frame f = ctx.Begin(input);
//   f.Open(lcgf::Id::From("toolbar"), {.dir = lcgf::Dir::x, .gap = 8, .fill = ctx.theme().panel});
//   if (lcgf::Button(f, lcgf::Id::From("reset"), "Reset").clicked()) ++resets;
//   lcgf::Checkbox(f, lcgf::Id::From("wire"), wire, "Wireframe");
//   lcgf::Slider(f, lcgf::Id::From("exposure"), exposure, 0, 1);
//   f.Close();
//   const lcgf::DrawList& draw = ctx.End();
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <format>
#include <limits>
#include <span>
#include <string_view>
#include <type_traits>

#include <lcgf/lcgf.hpp>
#include <lcgf/types.hpp>

// Row's constructor is the whole of Template.from: inlined, a style known at the call site
// folds to stores of the row, as in Zig. Left to -O2's heuristics it is an out-of-line call.
#if defined(_MSC_VER) && !defined(__clang__)
#define LCGF_INLINE __forceinline
#else
#define LCGF_INLINE [[gnu::always_inline]] inline
#endif

#include <lcgf/rows.hpp>

namespace lcgf {

/// A node's identity: FNV-1a of its name, never 0 (`Id.hash` in Zig, inline here).
struct Id {
    std::uint32_t value = 0;
    static constexpr Id From(std::string_view name) {
        std::uint32_t h = 0x811c9dc5u;
        for (char c : name) h = (h ^ static_cast<std::uint8_t>(c)) * 0x01000193u;
        return {h + (h == 0)};
    }
    /// A child id, for nodes made in a loop (`Id.with`).
    constexpr Id With(std::uint32_t n) const {
        std::uint32_t x = value ^ (n + 0x9E3779B9u);
        x = (x ^ (x >> 16)) * 0x85EBCA6Bu;
        x = (x ^ (x >> 13)) * 0xC2B2AE35u;
        x ^= x >> 16;
        return {x + (x == 0)};
    }
    static const Id none;
};
inline constexpr Id Id::none{0};

constexpr std::uint32_t Rgb(std::uint8_t r, std::uint8_t g, std::uint8_t b) { return r | g << 8 | b << 16 | 0xffu << 24; }
constexpr std::uint32_t Rgba(std::uint8_t r, std::uint8_t g, std::uint8_t b, std::uint8_t a) {
    return r | g << 8 | b << 16 | std::uint32_t(a) << 24;
}
inline constexpr std::uint32_t transparent = 0, white = 0xffffffffu;

/// A node's row as the library stores it (lcgf_row, Zig's `Template`): `Row(style)` is
/// `Template.from`, run here, at compile time for a constexpr style, so only the row crosses.
/// Frame's Style calls make the row inline; pass a `Row` to skip even that.
struct Row : lcgf_row {
    // Straight-line on purpose: no loops and no zero fill, so -O2 folds a constant style whole.
    LCGF_INLINE constexpr explicit Row(const Style& s) {
        constexpr float k_min[4] = {0, 1, 0, 0}, k_max[4] = {0, 1, 0, 0}, c_max[4] = {inf, 0, inf, inf};
        constexpr float k_grow[4] = {0, 0, 1, 0}, k_pct[4] = {0, 0, 0, 1}, c_pct[4] = {-1, -1, -1, 0};
        constexpr float factor[3] = {0, 0.5f, 1};
        constexpr std::uint32_t none = 0xffffffffu;
        const std::uint32_t k0 = s.size[0].kind & 3, k1 = s.size[1].kind & 3;
        const float v0 = s.size[0].v, v1 = s.size[1].v;
        min[0] = Max(v0 * k_min[k0], s.min[0]);
        min[1] = Max(v1 * k_min[k1], s.min[1]);
        max[0] = Min(v0 * k_max[k0] + c_max[k0], s.max[0]);
        max[1] = Min(v1 * k_max[k1] + c_max[k1], s.max[1]);
        grow[0] = v0 * k_grow[k0];
        grow[1] = v1 * k_grow[k1];
        pct[0] = v0 * k_pct[k0] + c_pct[k0];
        pct[1] = v1 * k_pct[k1] + c_pct[k1];
        pad_lo[0] = s.pad[0], pad_lo[1] = s.pad[1];
        pad_hi[0] = s.pad[2], pad_hi[1] = s.pad[3];
        offset[0] = s.offset[0], offset[1] = s.offset[1];
        scroll[0] = s.scroll[0], scroll[1] = s.scroll[1];
        const float along_y = static_cast<float>(static_cast<std::uint32_t>(s.dir));
        main[0] = 1 - along_y;
        main[1] = along_y;
        gap = s.gap;
        flow = s.floating ? 0.f : 1.f;
        shrink = s.shrink ? 1.f : 0.f;
        align_main = factor[static_cast<std::uint32_t>(s.main)];
        align_cross = factor[static_cast<std::uint32_t>(s.cross)];
        clips = s.clip ? 1 : 0;
        sense = 0;
        params[0] = s.params[0], params[1] = s.params[1], params[2] = s.params[2], params[3] = s.params[3];
        // The fill tints the texture; a texture with no fill shows its own colours (white tint).
        const std::uint32_t untinted = (s.texture & 0xffffu) != 0 && (s.fill >> 24) == 0;
        fill = s.fill | (0u - untinted);
        border_color = s.border_color;
        radius = s.radius;
        texture = s.texture & 0xffffu;
        material = s.material & 0xffffu;
        role = static_cast<std::uint32_t>(s.role) & 0xffu;
        value = s.value;
        text = none;
        custom = none;
        const float* t = s.transform;
        const float* c = s.radii;
        const bool off = (s.border != 0) | (s.opacity != 1) |                                //
                         (s.uv[0] != 0) | (s.uv[1] != 0) | (s.uv[2] != 1) | (s.uv[3] != 1) | //
                         (c[0] >= 0) | (c[1] >= 0) | (c[2] >= 0) | (c[3] >= 0) |             //
                         (t[0] != 1) | (t[1] != 0) | (t[2] != 0) | (t[3] != 1) | (t[4] != 0) | (t[5] != 0);
        const float* o = s.paint_outset;
        const bool styled = (o[0] != 0) | (o[1] != 0) | (o[2] != 0) | (o[3] != 0) | (s.cursor != none) |
                            (s.paint_reference != none) | ((s.participation & 0xffu) != 15);
        own = (off ? 1u : 0u) | (s.clip ? 1u : 0u) | (styled ? 1u : 0u);
        border = s.border;
        uv[0] = s.uv[0], uv[1] = s.uv[1], uv[2] = s.uv[2], uv[3] = s.uv[3];
        const float r = s.radius;
        radii[0] = c[0] < 0 ? r : c[0], radii[1] = c[1] < 0 ? r : c[1];
        radii[2] = c[2] < 0 ? r : c[2], radii[3] = c[3] < 0 ? r : c[3];
        opacity = s.opacity;
        transform[0] = t[0], transform[1] = t[1], transform[2] = t[2];
        transform[3] = t[3], transform[4] = t[4], transform[5] = t[5];
        transform_origin[0] = s.transform_origin[0], transform_origin[1] = s.transform_origin[1];
        paint_reference = s.paint_reference;
        paint_outset[0] = o[0], paint_outset[1] = o[1], paint_outset[2] = o[2], paint_outset[3] = o[3];
        prepared_texture = 0;
        paint_revision = 0;
        participation = s.participation & 0xffu;
        cursor = s.cursor == none ? 255u : s.cursor & 0xffu;
    }
    static constexpr Row From(const Style& s) { return Row(s); }
    const lcgf_row* raw() const { return this; }

private:
    // Template.from's selects: on a tie or a NaN, the second operand (the style's bound).
    static constexpr float Max(float a, float b) { return a > b ? a : b; }
    static constexpr float Min(float a, float b) { return a < b ? a : b; }
};
static_assert(sizeof(Row) == 66 * 4);

/// A colour by channel, to animate one (`Animate`, `Tween`): `Color::From(lcgf::Rgb(...))`,
/// back with `rgba()`. Channels move as numbers, as Zig's `Color` does.
struct Color {
    std::uint8_t r = 0, g = 0, b = 0, a = 0;
    static constexpr Color From(std::uint32_t v) { return {std::uint8_t(v), std::uint8_t(v >> 8), std::uint8_t(v >> 16), std::uint8_t(v >> 24)}; }
    constexpr std::uint32_t rgba() const { return Rgba(r, g, b, a); }
    friend constexpr bool operator==(Color, Color) = default;
};

/// What `Frame::Animate` and `Frame::Tween` can move (src/anim/values.zig): its numbers, in
/// order. Specialized here for arithmetic types, `Color` and `std::array`; specialize it for a
/// type of yours with `n`, `get` (the value's numbers into `out`) and `make` (a value from
/// them). An integer comes back rounded half away from zero and clamped to its type.
template <class T, class = void>
struct Components;

template <class T>
struct Components<T, std::enable_if_t<std::is_arithmetic_v<T>>> {
    static constexpr std::size_t n = 1;
    static void get(T v, float* out) { out[0] = float(v); }
    static T make(const float* x) {
        if constexpr (std::is_floating_point_v<T>) {
            return T(x[0]);
        } else {
            static_assert(sizeof(T) <= 4, "lcgf::Animate: integers of up to 32 bits");
            return T(lcgf_values_int_of(x[0], std::numeric_limits<T>::lowest(), std::numeric_limits<T>::max()));
        }
    }
};

template <>
struct Components<Color> {
    static constexpr std::size_t n = 4;
    static void get(Color c, float* out) { out[0] = c.r, out[1] = c.g, out[2] = c.b, out[3] = c.a; }
    static Color make(const float* x) {
        using C = Components<std::uint8_t>;
        return {C::make(x), C::make(x + 1), C::make(x + 2), C::make(x + 3)};
    }
};

template <class T, std::size_t N>
struct Components<std::array<T, N>> {
    using E = Components<T>;
    static constexpr std::size_t n = N * E::n;
    static void get(const std::array<T, N>& v, float* out) {
        for (std::size_t i = 0; i < N; ++i) E::get(v[i], out + i * E::n);
    }
    static std::array<T, N> make(const float* x) {
        std::array<T, N> v{};
        for (std::size_t i = 0; i < N; ++i) v[i] = E::make(x + i * E::n);
        return v;
    }
};

template <class T>
concept Animatable = requires { Components<T>::n; };

/// What a widget reports this frame.
struct Response {
    std::uint8_t bits = 0;
    bool hovered() const { return bits & 1; }
    bool held() const { return bits & 2; }
    bool pressed() const { return bits & 4; }
    bool released() const { return bits & 8; }
    bool clicked() const { return bits & 16; }
    bool focused() const { return bits & 32; }
};

/// A node of this frame: its row.
struct Node {
    std::uint32_t row;
};

/// A batch of 2D primitives in your buffer (`lcgf.canvas.Instances`, lcgf.h `lcgf_canvas_*`):
/// fill it once or when it changes, then draw ranges of it in a `Frame::Canvas` node each frame.
/// Points are int32 world units; a `width` of 0 is the layer's, in logical pixels.
namespace canvas {
using Point = std::array<std::int32_t, 2>;
enum class Cap : std::uint8_t { butt,
                                square,
                                round };
struct Line {
    std::uint8_t layer = 0, weight = 1;
    Cap cap = Cap::butt;
    std::uint8_t dash = 0;
    std::uint32_t width = 0;
};
struct Box {
    std::uint8_t layer = 0, weight = 1;
    bool fill = true, stroke = true;
    std::uint32_t radius = 0, width = 0;
};
struct Arc {
    std::uint8_t layer = 0, weight = 1;
    Cap cap = Cap::butt;
    std::uint8_t dash = 0;
    float start = 0, sweep = 6.28318530717958647692f;
    std::uint32_t width = 0;
};
struct Area {
    std::uint8_t layer = 0, weight = 1;
    bool fill = true, stroke = false;
    std::uint32_t width = 0;
};
struct Text {
    std::uint32_t px;
    std::uint8_t layer = 0, turns = 0, pad[2]{};
};
static_assert(sizeof(Line) == sizeof(lcgf_canvas_line_style) && sizeof(Box) == sizeof(lcgf_canvas_box_style) && sizeof(Arc) == sizeof(lcgf_canvas_arc_style));
static_assert(sizeof(Area) == sizeof(lcgf_canvas_area_style) && sizeof(Text) == sizeof(lcgf_canvas_text_style));
using Range = lcgf_canvas_range;
using Override = lcgf_canvas_override;
using Layer = lcgf_canvas_layer;
struct Camera {
    std::array<std::int64_t, 2> origin{};
    float scale = 1;
    std::array<float, 2> offset{};
    float zoom = 1;
};
/// What a canvas node draws; everything it points at is yours until the frame is drawn.
struct Options {
    Camera camera{};
    std::span<const Layer> layers;
    bool zoom_scale = false;
    std::span<const Range> ranges;
    std::span<const Override> overrides{};

    lcgf_canvas_options raw() const {
        return {{{camera.origin[0], camera.origin[1]}, camera.scale, {camera.offset[0], camera.offset[1]}, camera.zoom},
                layers.data(),
                layers.size(),
                zoom_scale ? 1u : 0u,
                ranges.data(),
                ranges.size(),
                overrides.data(),
                overrides.size()};
    }
};
} // namespace canvas

class Canvas {
public:
    static std::size_t Bytes(std::uint32_t rows, std::uint32_t verts = 0, std::uint32_t dirty = 16, bool marks = false) {
        return lcgf_canvas_bytes(rows, verts, dirty, marks);
    }
    /// In `buffer` (`Bytes` long, aligned to column_align); `valid()` is false otherwise. With
    /// `marks`, each row can be given a colour of its own (`Mark`).
    Canvas(std::span<std::byte> buffer, std::uint32_t rows, std::uint32_t verts = 0, std::uint32_t dirty = 16, bool marks = false)
        : c_(lcgf_canvas_init(buffer.data(), buffer.size(), rows, verts, dirty, marks)) {}
    bool valid() const { return c_ != nullptr; }
    std::uint32_t size() const { return lcgf_canvas_len(c_); }
    std::uint32_t Segment(canvas::Point a, canvas::Point b, const canvas::Line& o = {}) { return lcgf_canvas_segment(c_, a[0], a[1], b[0], b[1], line(o)); }
    canvas::Range Polyline(std::span<const canvas::Point> pts, const canvas::Line& o = {}) {
        return lcgf_canvas_polyline(c_, reinterpret_cast<const std::int32_t (*)[2]>(pts.data()), pts.size(), line(o));
    }
    std::uint32_t Rect(canvas::Point lo, canvas::Point hi, const canvas::Box& o = {}) { return lcgf_canvas_rect(c_, lo[0], lo[1], hi[0], hi[1], box(o)); }
    std::uint32_t Circle(canvas::Point c, std::uint32_t r, const canvas::Box& o = {}) { return lcgf_canvas_circle(c_, c[0], c[1], r, box(o)); }
    std::uint32_t Arc(canvas::Point c, std::uint32_t r, const canvas::Arc& o = {}) {
        return lcgf_canvas_arc(c_, c[0], c[1], r, reinterpret_cast<const lcgf_canvas_arc_style*>(&o));
    }
    std::uint32_t Polygon(std::span<const canvas::Point> pts, const canvas::Area& o = {}) {
        return lcgf_canvas_polygon(c_, reinterpret_cast<const std::int32_t (*)[2]>(pts.data()), pts.size(), reinterpret_cast<const lcgf_canvas_area_style*>(&o));
    }
    canvas::Range Glyphs(std::string_view str, canvas::Point at, const canvas::Text& o) {
        return lcgf_canvas_glyphs(c_, str.data(), str.size(), at[0], at[1], reinterpret_cast<const lcgf_canvas_text_style*>(&o));
    }
    void Kill(std::uint32_t row) { lcgf_canvas_kill(c_, row); }
    /// Row `row` in `color` (rgba8) over its layer and any override; 0 for none.
    void Mark(std::uint32_t row, std::uint32_t color) { lcgf_canvas_mark(c_, row, color); }
    void Reset() { lcgf_canvas_reset(c_); }
    /// Once every renderer that draws it has prepared the frame.
    void ClearDirty() { lcgf_canvas_clear_dirty(c_); }
    /// The topmost row within `slop` logical px of `p` (from the node's corner), or LCGF_NO_WIDGET.
    std::uint32_t Hit(const canvas::Options& o, float x, float y, float slop = 0) const {
        const lcgf_canvas_options r = o.raw();
        return lcgf_canvas_hit(c_, &r, x, y, slop);
    }
    const lcgf_canvas* raw() const { return c_; }

private:
    static const lcgf_canvas_line_style* line(const canvas::Line& o) { return reinterpret_cast<const lcgf_canvas_line_style*>(&o); }
    static const lcgf_canvas_box_style* box(const canvas::Box& o) { return reinterpret_cast<const lcgf_canvas_box_style*>(&o); }
    lcgf_canvas* c_;
};

/// A frame being built. Valid between `Context::Begin` and `Context::End`.
class Frame {
public:
    Frame(lcgf_frame* f, const lcgf_view* view, const Theme* theme, const lcgf_text_style* label)
        : f_(f), v_(view), theme_(theme), label_(label) {}
    LCGF_INLINE Node Open(Id id) { return Open(id, kDefault); }
    LCGF_INLINE Node Open(Id id, const Style& s) { return Open(id, Row(s)); }
    LCGF_INLINE Node Open(Id id, const Row& r) { return {Enter(Push(id.value, r))}; }
    void Close() { lcgf_frame_close(f_); }
    Node Leaf(Id id) { return Leaf(id, kDefault); }
    LCGF_INLINE Node Leaf(Id id, const Style& s) { return Leaf(id, Row(s)); }
    LCGF_INLINE Node Leaf(Id id, const Row& r) {
        const std::uint32_t i = Enter(Push(id.value, r));
        // push set the leaf's end; only pop the slot `Enter` took (`Frame.finishLeaf`).
        *v_->depth = (*v_->depth > 2 ? *v_->depth : 2) - 1;
        return {i};
    }
    Node Text(std::string_view str, const TextStyle& ts = {}) { return {lcgf_frame_text(f_, str.data(), str.size(), ts.raw())}; }
    Node TextStyled(std::string_view str, const TextStyle& ts, const Style& s) {
        return {lcgf_frame_text_styled(f_, str.data(), str.size(), ts.raw(), s.raw())};
    }
    /// A node the host draws itself: its rect comes back in the draw list's customs.
    LCGF_INLINE Node Custom(Id id, const Style& s, std::uint64_t data) { return Custom(id, Row(s), data); }
    LCGF_INLINE Node Custom(Id id, const Row& r, std::uint64_t data) { return {lcgf_frame_custom_row(f_, id.value, r.raw(), data)}; }
    /// A node that draws `o.ranges` of `c` under `o.camera` (`Frame.canvas`); needs
    /// `Context::EnableCanvas`. LCGF_NO_WIDGET past the limits' customs. Lifetimes: the draw
    /// list `Context::End` returns reads `c` and the layers, ranges and overrides `o` points
    /// at (not `o` itself): keep them alive and unchanged until it has been drawn, and through
    /// the next frame if that frame reuses this node.
    Node Canvas(Id id, const Style& s, const lcgf::Canvas& c, const canvas::Options& o) {
        const lcgf_canvas_options r = o.raw();
        return {lcgf_frame_canvas(f_, id.value, s.raw(), c.raw(), &r)};
    }
    /// A value that eases toward `target` on a spring keyed by `id` (`Frame.animate`): a float,
    /// or anything `Components` takes apart (a `Color`, a `std::array<float, 4>`, a type of
    /// yours), each number on its own spring keyed `id.With(k)`, as in Zig.
    float Animate(Id id, float target, Spring sp = {}) { return lcgf_frame_animate(f_, id.value, target, sp.raw()); }
    template <Animatable T>
        requires(!std::is_same_v<T, float>)
    T Animate(Id id, const T& target, Spring sp = {}) {
        return Each(target, [&](std::uint32_t k, float x) { return lcgf_frame_animate(f_, id.With(k).value, x, sp.raw()); });
    }
    /// A value that moves to `target` over `seconds` along `ease` (`Frame.tween`), keyed as
    /// `Animate` keys.
    float Tween(Id id, float target, float seconds, Ease ease = Ease::in_out) {
        return lcgf_frame_tween(f_, id.value, target, seconds, std::uint32_t(ease));
    }
    template <Animatable T>
        requires(!std::is_same_v<T, float>)
    T Tween(Id id, const T& target, float seconds, Ease ease = Ease::in_out) {
        return Each(target, [&](std::uint32_t k, float x) { return lcgf_frame_tween(f_, id.With(k).value, x, seconds, std::uint32_t(ease)); });
    }
    /// Text of `args` formatted by `fmt` (`std::format`), written straight into the frame's
    /// strings (`lcgf_frame_room`): no buffer of yours, cut where the strings end.
    template <class... A>
    Node TextF(const TextStyle& ts, std::format_string<A...> fmt, A&&... args) {
        std::size_t room = 0;
        char* p = lcgf_frame_room(f_, &room);
        const auto r = std::format_to_n(p, std::ptrdiff_t(room), fmt, std::forward<A>(args)...);
        return {lcgf_frame_text_written(f_, std::size_t(r.size), ts.raw())};
    }
    /// `node` answers the pointer as `sense` says (`Frame.interact`): bits of `Sense`
    /// (1 hover, 2 click, 4 drag, 8 focus).
    Response Interact(Node node, std::uint8_t sense) { return {lcgf_frame_interact(f_, node.row, sense)}; }
    /// Pointer movement this frame while `id` is dragged (`Frame.drag`).
    std::array<float, 2> Drag(Id id) {
        std::array<float, 2> d{};
        lcgf_frame_drag(f_, id.value, d.data());
        return d;
    }
    /// Where `id` was laid out last frame (`Frame.lastRect`); the held widget's (`heldRect`).
    lcgf_rect LastRect(Id id) { return lcgf_frame_last_rect(f_, id.value); }
    lcgf_rect HeldRect() { return lcgf_frame_held_rect(f_); }
    void SetFill(Node node, std::uint32_t color) { lcgf_frame_set_fill(f_, node.row, color); }
    /// `cursor` (a `types.Cursor` tag) while `when` (`Frame.setCursor`).
    void SetCursor(std::uint32_t cursor, bool when) { lcgf_frame_set_cursor(f_, cursor, when); }
    void FocusScope(Node node, std::uint8_t kind) { lcgf_frame_focus_scope(f_, node.row, kind); }
    Node Outline(Node node, const lcgf_outline& o) { return {lcgf_frame_outline(f_, node.row, &o)}; }
    void AnimateLayout(Node node, Spring sp = {}) { lcgf_frame_animate_layout(f_, node.row, *sp.raw()); }
    /// `keys` played once from the first frame that asks for `id` (`Frame.sequence`).
    float Sequence(Id id, std::span<const lcgf_key> keys) { return lcgf_frame_sequence(f_, id.value, keys.data(), keys.size()); }
    std::uint32_t Transition(Id id, std::uint32_t target, const lcgf_transition& tr) {
        return lcgf_frame_transition(f_, id.value, target, &tr);
    }
    void SetFillAnimated(Node node, Id id, std::uint32_t color, const lcgf_transition& tr) {
        lcgf_frame_set_fill_animated(f_, node.row, id.value, color, &tr);
    }
    lcgf_frame* raw() const { return f_; }
    /// The context's theme, which the widgets draw with.
    const Theme* theme() const { return theme_; }
    /// The theme's label text style (`Label`'s).
    const lcgf_text_style* label_style() const { return label_; }

private:
    template <class T, class F>
    static T Each(const T& target, F one) {
        using C = Components<T>;
        float want[C::n], got[C::n];
        C::get(target, want);
        for (std::size_t k = 0; k < C::n; ++k) got[k] = one(std::uint32_t(k), want[k]);
        return C::make(got);
    }

public:
private:
    static constexpr Row kDefault{Style{}};

    // `Tree.pushRow` into the columns lcgf_frame_view gave, what Zig's inlined `open` does, with no
    // call: the stores are generated from Zig's types (lcgf/rows.hpp, tools/abi-gen); what is
    // here is the rest of pushRow. bindings/check/run.sh holds the frames byte-identical to Zig's.
    LCGF_INLINE std::uint32_t Push(std::uint32_t id, const Row& r) const {
        const lcgf_view& v = *v_;
        const std::uint32_t parent_in = v.stack[*v.depth - 1];
        const std::uint32_t n = *v.len;
        const std::uint32_t i = n < v.cap - 1 ? n : v.cap - 1;
        *v.overflow = *v.overflow | (n >= v.cap);
        *v.len = i + 1;
        // Full, the last row is rewritten: the parent is clamped below it (parent < row).
        const std::uint32_t below = i ? i - 1 : 0;
        const std::uint32_t parent = parent_in < below ? parent_in : below;
        v.id[i] = id;
        v.parent[i] = parent;
        v.end[i] = i + 1;
        gen::StoreNode(v, i, r);
        // Participation narrows down the tree; without layout the node collapses.
        const std::uint8_t up = i == 0 ? 15 : v.x_row[v.scope[parent]].active_participation;
        std::uint8_t active = std::uint8_t(r.participation) & up;
        if (!(active & 1)) {
            active = 0;
            gen::CollapseNode(v, i);
        }
        v.role[i] &= std::uint8_t(0u - ((active >> 3) & 1));
        v.sense[i] &= std::uint8_t(0u - ((active >> 2) & 1));
        // Counted in its parent, its own count cleared (the root is its own parent).
        v.nkids[parent] += v.flow[i];
        v.nkids[i] = 0;
        // The extras row, appended when the row has one.
        const bool own = r.own != 0;
        const std::uint32_t x = *v.xlen < v.cap ? *v.xlen : v.cap;
        *v.xlen = x + r.own;
        v.extra[i] = own ? x : 0;
        v.scope[i] = 0;
        v.scope[i] = own ? x : v.scope[parent];
        if (!own) return i;
        v.x_node[x] = i;
        lcgf_extra& e = v.x_row[x];
        gen::StoreExtra(e, r);
        // A reference to this row or a later one paints from the node itself (Tree.pushRow).
        e.paint_reference = r.paint_reference < i ? r.paint_reference : 0xffffffffu;
        e.active_participation = active;
        e.active_cursor = r.cursor != 255 ? std::uint8_t(r.cursor) : i == 0 ? 255
                                                                            : v.x_row[v.scope[parent]].active_cursor;
        return i;
    }

    // `Frame.enter`: too deep, the deepest slot is reused and the overflow flagged.
    LCGF_INLINE std::uint32_t Enter(std::uint32_t i) const {
        const lcgf_view& v = *v_;
        const std::uint32_t depth = *v.depth;
        const std::uint32_t d = depth < v.depth_cap - 1 ? depth : v.depth_cap - 1;
        *v.status = std::uint8_t(*v.status | (depth >= v.depth_cap) << LCGF_DEPTH_BIT);
        v.stack[d] = i;
        *v.depth = d + 1;
        return i;
    }

    lcgf_frame* f_;
    const lcgf_view* v_;
    const Theme* theme_;
    const lcgf_text_style* label_;
};

inline Node Label(Frame& f, std::string_view str) { return {lcgf_label(f.raw(), f.theme()->raw(), str.data(), str.size())}; }
inline Response Button(Frame& f, Id id, std::string_view str) { return {lcgf_button(f.raw(), f.theme()->raw(), id.value, str.data(), str.size())}; }
inline Response Checkbox(Frame& f, Id id, bool& value, std::string_view str) {
    return {lcgf_checkbox(f.raw(), f.theme()->raw(), id.value, &value, str.data(), str.size())};
}
inline Response Slider(Frame& f, Id id, float& value, float lo, float hi) { return {lcgf_slider(f.raw(), f.theme()->raw(), id.value, &value, lo, hi)}; }

/// `Label` of `args` formatted by `fmt` (`std::format`), written straight into the frame's
/// strings: `lcgf::LabelF(f, "Gain {:.1f} dB", gain)`.
template <class... A>
Node LabelF(Frame& f, std::format_string<A...> fmt, A&&... args) {
    std::size_t room = 0;
    char* p = lcgf_frame_room(f.raw(), &room);
    const auto r = std::format_to_n(p, std::ptrdiff_t(room), fmt, std::forward<A>(args)...);
    return {lcgf_frame_text_written(f.raw(), std::size_t(r.size), f.label_style())};
}

// Options by name: `lcgf::Slider(f, id, gain, {.max = 4})`. The positional forms above stay.
struct ButtonOptions {
    std::string_view label;
};
struct CheckboxOptions {
    std::string_view label;
};
struct SliderOptions {
    float min = 0, max = 1;
};
inline Response Button(Frame& f, Id id, const ButtonOptions& o) { return Button(f, id, o.label); }
inline Response Checkbox(Frame& f, Id id, bool& value, const CheckboxOptions& o) { return Checkbox(f, id, value, o.label); }
inline Response Slider(Frame& f, Id id, float& value, const SliderOptions& o = {}) { return Slider(f, id, value, o.min, o.max); }

/// The runtime front end in your buffer (`lcgf_context_required_bytes` bytes, aligned to
/// column_align).
class Context {
public:
    static std::size_t Bytes(const lcgf_limits& l) { return lcgf_context_required_bytes(&l); }

    Context(std::span<std::byte> buffer, const lcgf_limits& limits) : ctx_(reinterpret_cast<lcgf_context*>(buffer.data())) {
        // Rows are made here, so the library must lay them out as this header does.
        status_ = lcgf_layout() != LCGF_LAYOUT ? Status::layout_hash
                                               : static_cast<Status>(lcgf_context_init(buffer.data(), buffer.size(), &limits));
        lcgf_label_text(theme_.raw(), &label_);
    }
    Context(const Context&) = delete;
    Context& operator=(const Context&) = delete;

    Status status() const { return status_; }
    const Theme& theme() const { return theme_; }
    /// Memory for `EnableCanvas` (aligned to a pointer), alive as long as the context.
    static std::size_t CanvasBytes(const lcgf_limits& l) { return lcgf_context_canvas_bytes(&l); }
    Status EnableCanvas(std::span<std::byte> buffer) { return static_cast<Status>(lcgf_context_enable_canvas(ctx_, buffer.data(), buffer.size())); }
    /// Whether this input needs a frame (a host that sleeps between events asks first).
    bool NeedsFrame(const Input& in) { return lcgf_context_needs_frame(ctx_, &in) != 0; }
    Frame Begin(const Input& in) {
        lcgf_context_begin(ctx_, &in, &frame_);
        lcgf_frame_view(&frame_, &view_);
        return Frame(&frame_, &view_, &theme_, &label_);
    }
    /// Lays out and paints the frame; its draw list stays valid until the next `End`.
    const DrawList& End() {
        lcgf_frame_end(&frame_, &last_);
        draw_ = DrawList(last_.draw);
        return draw_;
    }
    /// Seconds until a frame is needed though nothing happened: 0 while a spring moves.
    float wake() const { return last_.wake; }

private:
    lcgf_context* ctx_;
    Status status_;
    Theme theme_{};
    lcgf_text_style label_{};
    lcgf_frame frame_{};
    lcgf_ui_output last_{};
    lcgf_view view_{};
    DrawList draw_{last_.draw};
};

} // namespace lcgf
