// lcgf/ct.hpp: static UIs compiled in C++. The comptime pipeline (Zig's ct_layout and
// ct_paint, src/abi/ct.zig's frame) as templates over a UI's tables, which lcgf-gen --static
// writes as `constexpr` members of a `Tables` struct. Every row count, style value and paint
// template is a compile-time constant here, as it is to Zig's compiler, so the compiler folds
// them into the passes. Nothing crosses the C seam: the UI is a value of its own, with no
// buffer and no library call.
//
// The passes are src/layout/layout.zig's (prepare, applyText, fit, resolve, place, finalize)
// without their flex terms, src/text/protocol.zig's Mono measure and src/draw/paint.zig's
// encode, ported operation for operation: the same IEEE operations in the same order, min and
// max as the selects of `simd.maxF`/`simd.minF`, `@round` as std::round. Contracting a*b+c
// into an FMA would change results, so the lcgf CMake targets compile with -ffp-contract=off.
// bindings/check/run.sh holds the draw lists byte-identical to Zig's.
#pragma once
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <type_traits>
#include <utility>

#include <lcgf/lcgf.hpp>

// No a*b+c contracted into an FMA in these passes (clang honours this; the CMake targets add
// -ffp-contract=off for GCC and clang alike).
#pragma STDC FP_CONTRACT OFF

namespace lcgf::ct {

using u32 = std::uint32_t;

/// A stored f32, from its bits (the tables keep floats as bits, so -0, infinities and NaN
/// survive exactly).
constexpr float F(u32 bits) { return std::bit_cast<float>(bits); }
/// `simd.maxF`: a > b ? a : b. A tie or a NaN `a` gives `b`.
constexpr float maxF(float a, float b) { return a > b ? a : b; }
/// `simd.minF`: a < b ? a : b.
constexpr float minF(float a, float b) { return a < b ? a : b; }
/// `simd.b2f`.
constexpr float b01(bool c) { return c ? 1.0f : 0.0f; }
/// `@round`: half away from zero, the sign of zero kept, exact, inline, branch-free and without
/// a conversion (so a loop of them vectorizes, and no libm call without SSE4.1). Below 2^23,
/// `(|x| + 2^23) - 2^23` is |x| rounded half to even; a `.5` that went down to even goes up by
/// one. At or above 2^23, and for NaN and the infinities, `x` is its own rounding.
inline float round_(float x) {
    constexpr float big = 8388608.0f;
    const float a = std::fabs(x);
    const float even = (a + big) - big;
    const float r = even + (even - a == -0.5f ? 1.0f : 0.0f);
    return a < big ? std::copysign(r, x) : x;
}

/// Where a static UI's label text goes (src/core/fmt.zig's `Sink`): the rest of the frame's
/// strings. What does not fit is dropped byte by byte, as every engine drops it. A generated
/// `texts` writes each label, formatted labels as straight-line calls on it.
struct Sink {
    char* buf;
    u32 cap;
    u32 len = 0;

    void put(const char* p, std::size_t n) {
        const u32 k = u32(std::min<std::size_t>(n, cap - len));
        if (k > 0) std::memcpy(buf + len, p, k);
        len += k;
    }
    void put(Str s) { put(s.ptr, s.len); }
    void put_bool(bool v) { v ? put("true", 4) : put("false", 5); }
    /// In decimal, at least `min_digits` long.
    void put_uint(std::uint64_t v, unsigned min_digits = 1) {
        char d[20];
        unsigned at = 20;
        while (v != 0 || 20 - at < min_digits) {
            d[--at] = char('0' + v % 10);
            v /= 10;
        }
        put(d + at, 20 - at);
    }
    /// `v` with `prec` decimals: widened to f64, times 10^prec, rounded half away from zero
    /// (`std::round`); the sign only on a non-zero result; `nan`, and `inf` or `-inf` for an
    /// infinity or a result of 10^18 or more.
    void put_f32(float v, unsigned prec) {
        if (v != v) return put("nan", 3);
        static constexpr double pow10[] = {1, 10, 100, 1000, 10000, 100000, 1000000};
        const double scaled = std::round(double(v) * pow10[prec]);
        if (std::fabs(scaled) >= 1e18) return v < 0 ? put("-inf", 4) : put("inf", 3);
        if (scaled < 0) put("-", 1);
        char d[20];
        unsigned at = 20;
        auto n = std::uint64_t(std::fabs(scaled));
        while (n != 0 || 20 - at < prec + 1) {
            d[--at] = char('0' + n % 10);
            n /= 10;
        }
        put(d + at, 20 - at - prec);
        if (prec == 0) return;
        put(".", 1);
        put(d + 20 - prec, prec);
    }
};

/// One dynamic region of a tree (src/abi/ct.zig's `Region`): kind 1 list, 2 when, 3 choice;
/// `alts` indexes the tree's choice windows; `scroll` is 1 for a windowed list.
struct Region {
    u32 kind, row, end, stride, max, alts, scroll, height;
};

/// One region's selection this frame.
struct Select {
    u32 n = 0, first = 0;
    float offset = 0;
};

/// ct_dynamic's `selectWindow`: the live copies of a windowed list scrolled `scroll` px.
inline Select select_window(u32 count, u32 visible, float height, float scroll) {
    const double h = height;
    const double max_scroll = double(count > visible ? count - visible : 0) * h;
    const double px = std::min(std::max(double(scroll), 0.0), max_scroll);
    const u32 first = u32(std::floor(px / h));
    const float offset = float(px - double(first) * h);
    return {std::min(count - first, visible + (offset > 0 ? 1u : 0u)), first, offset};
}

/// Per-frame columns of one tree (`B`, a block of the tables): the layout scratch, outputs and
/// the masked columns.
template <class B>
struct Scratch {
    static constexpr u32 n = B::n;
    float fit[2][n], nat[2][n], grow_sum[2][n], grow_inv[2][n], used[2][n], size[2][n], pos[2][n];
    float cursor[n];
    float max[2][n], flow[n], nkids[n], gap_total[n], scroll[2][n];
    u32 mask[n];
};

/// The passes over one tree of UI `T`.
template <class T, class B>
struct Tree {
    using S = Scratch<B>;
    static constexpr u32 n = B::n;

    static float max_(const S& s, int a, u32 i) {
        if constexpr (T::live) return s.max[a][i];
        else return F(B::max[a][i]);
    }
    static float flow(const S& s, u32 i) {
        if constexpr (T::live) return s.flow[i];
        else return F(B::flow[i]);
    }
    static float gap_total(const S& s, u32 i) {
        if constexpr (T::live) return s.gap_total[i];
        else return F(B::gap_total[i]);
    }
    static float scroll(const S& s, int a, u32 i) {
        if constexpr (T::windows) return s.scroll[a][i];
        else return F(B::scroll[a][i]);
    }

    /// ct_dynamic.Regions.mask: rows outside every region live, a row inside regions live when
    /// each of them keeps it.
    static void live_mask(S& s, const Select* sel) {
        for (u32 i = 0; i < n; ++i) s.mask[i] = ~u32(0);
        for (u32 g = 0; g < T::regions; ++g) {
            const Region& r = B::regions[g];
            const u32 first = r.kind == 2 ? r.row : r.row + 1;
            u32 lo = first, len = 0;
            if (r.kind == 1) len = std::min(sel[g].n, r.max) * r.stride;
            else if (r.kind == 2) len = std::min(sel[g].n, 1u) * (r.end - r.row);
            else {
                const auto& w = B::alts[r.alts + std::min(sel[g].n, r.max)];
                lo = w[0];
                len = w[1];
            }
            for (u32 j = first; j < r.end; ++j) s.mask[j] &= 0u - u32(j - lo < len);
        }
    }

    template <int a, u32 first = 0, u32 last = n>
    static void fit(S& s) {
        float* fit_ = s.fit[a];
        for (u32 i = last - 1; i > first; --i) {
            const float content = fit_[i] + F(B::main[a][i]) * gap_total(s, i);
            float nat = content + F(B::pad_lo[a][i]) + F(B::pad_hi[a][i]);
            nat = minF(maxF(nat, F(B::min[a][i])), max_(s, a, i));
            s.nat[a][i] = nat;
            const u32 p = B::parent[i];
            const float contrib = nat * flow(s, i);
            const float fp = fit_[p];
            const float sum = fp + contrib;
            const float mx = fp < contrib ? contrib : fp;
            fit_[p] = F(B::main[a][p]) != 0 ? sum : mx;
            s.grow_sum[a][p] += F(B::grow[a][i]) * flow(s, i);
        }
        // The root of the span has no parent to fold into.
        const float content = fit_[first] + F(B::main[a][first]) * gap_total(s, first);
        const float nat = content + F(B::pad_lo[a][first]) + F(B::pad_hi[a][first]);
        s.nat[a][first] = minF(maxF(nat, F(B::min[a][first])), max_(s, a, first));
        for (u32 j = first; j < last; ++j) s.grow_inv[a][j] = 1.0f / maxF(s.grow_sum[a][j], 1e-6f);
    }

    template <int a, u32 first = 0, u32 last = n>
    static void resolve(S& s) {
        float* size = s.size[a];
        constexpr float m = 0;
        for (u32 i = first + 1; i < last; ++i) {
            const u32 p = B::parent[i];
            const float nat = s.nat[a][i];
            const float main = F(B::main[a][p]);
            const float taken = s.fit[a][p] + gap_total(s, p);
            const float fl = flow(s, i);
            const float pct = F(B::pct[a][i]);
            const float grow = F(B::grow[a][i]);
            const float has_pct = b01(pct >= 0);
            const float keep = 1 - has_pct;
            const float across = (1 - main) * b01(grow > 0);
            const float k0 = nat * keep * (1 - fl * across);
            const float k1 = has_pct * pct + keep * fl * across;
            const float k2 = keep * fl * main * grow * s.grow_inv[a][p];
            const float inner = maxF(size[p] - F(B::pad_lo[a][p]) - F(B::pad_hi[a][p]), 0);
            float sz = k0 + k1 * inner + k2 * maxF(inner - taken, 0);
            const float room = maxF(inner - main * (taken - nat) - (1 - main) * m, 0);
            const float cut = F(B::shrink[i]) * fl * maxF(sz - room, 0);
            sz -= cut;
            sz = minF(maxF(sz, F(B::min[a][i])), max_(s, a, i));
            size[i] = sz;
            s.used[a][p] += (sz + m) * fl;
        }
    }

    template <u32 first = 0, u32 last = n>
    static void place(S& s) {
        constexpr float m = 0, m_lo = 0;
        for (u32 i = first + 1; i < last; ++i) {
            const u32 p = B::parent[i];
            const float fl = flow(s, i);
            for (int a = 0; a < 2; ++a) {
                const float inner = s.size[a][p] - F(B::pad_lo[a][p]) - F(B::pad_hi[a][p]);
                const float lead = maxF(inner - s.used[a][p] - gap_total(s, p), 0) * F(B::align_main[p]);
                const float cross = F(B::align_cross[p]);
                const float across = maxF(inner - s.size[a][i] - m, 0) * cross + m_lo;
                const float along = lead + s.cursor[p] + m_lo;
                const float in_flow = across + F(B::main[a][p]) * (along - across);
                s.pos[a][i] = s.pos[a][p] + F(B::pad_lo[a][p]) - scroll(s, a, p) + fl * in_flow + F(B::offset[a][i]);
            }
            const float step = s.size[0][i] * F(B::main[0][p]) + s.size[1][i] * F(B::main[1][p]);
            const float advance = step + F(B::gap[p]);
            s.cursor[p] += advance * fl;
        }
    }

    /// `Plain.relayout` over the subtree [First, Last): the accumulators of its rows cleared,
    /// every label's extent applied, and fit, resolve and place over the span only (the span
    /// forms of the passes). The span's root keeps its size and position.
    template <u32 First, u32 Last>
    static void relayout_span(S& s, const float* w, const float* h) {
        for (int a = 0; a < 2; ++a)
            for (u32 i = First; i < Last; ++i) s.fit[a][i] = s.grow_sum[a][i] = s.used[a][i] = 0;
        for (u32 i = First; i < Last; ++i) s.cursor[i] = 0;
        for (u32 k = 0; k < T::labels; ++k) s.fit[0][B::label_rows[k]] = w[k];
        fit<0, First, Last>(s);
        resolve<0, First, Last>(s);
        for (u32 k = 0; k < T::labels; ++k) s.fit[1][B::label_rows[k]] = h[k];
        fit<1, First, Last>(s);
        resolve<1, First, Last>(s);
        place<First, Last>(s);
    }

    /// `Plain.passesLiveText`: every pass but finalize. `w`/`h`: the labels' measured extents.
    static void passes(S& s, const float* w, const float* h, const Select* sel, float vw, float vh) {
        if constexpr (T::live) {
            // `applyMask`, then `prepare`.
            live_mask(s, sel);
            for (u32 i = 0; i < n; ++i) {
                for (int a = 0; a < 2; ++a) s.max[a][i] = std::bit_cast<float>(B::max[a][i] & s.mask[i]);
                s.flow[i] = std::bit_cast<float>(B::flow[i] & s.mask[i]);
                s.nkids[i] = 0;
            }
            for (u32 j = 1; j < n; ++j) s.nkids[B::parent[j]] += s.flow[j];
            if constexpr (T::windows) {
                for (int a = 0; a < 2; ++a)
                    for (u32 i = 0; i < n; ++i) s.scroll[a][i] = F(B::scroll[a][i]);
                for (u32 g = 0; g < T::regions; ++g)
                    if (B::regions[g].scroll) s.scroll[1][B::regions[g].row] = sel[g].offset;
            }
            for (u32 i = 0; i < n; ++i) s.gap_total[i] = F(B::gap[i]) * maxF(s.nkids[i] - 1.0f, 0.0f);
        }
        for (int a = 0; a < 2; ++a)
            for (u32 i = 0; i < n; ++i) s.fit[a][i] = s.grow_sum[a][i] = s.used[a][i] = 0;
        for (u32 i = 0; i < n; ++i) s.cursor[i] = 0;
        // resolve gives the root the viewport, bypassing its masked maximum.
        bool shown = true;
        if constexpr (T::root_when) shown = sel[0].n != 0;
        for (u32 k = 0; k < T::labels; ++k) s.fit[0][B::label_rows[k]] = w[k];
        fit<0>(s);
        s.size[0][0] = shown ? vw : 0.0f;
        resolve<0>(s);
        for (u32 k = 0; k < T::labels; ++k) s.fit[1][B::label_rows[k]] = h[k];
        fit<1>(s);
        s.size[1][0] = shown ? vh : 0.0f;
        resolve<1>(s);
        s.pos[0][0] = 0;
        s.pos[1][0] = 0;
        place(s);
    }
};

/// An input event on one widget (ct_events.Event): a click on a checkbox, or a slider's new
/// value, 0 at its left edge to 1 at its right, while it is dragged.
template <class Widget>
struct Event {
    Widget widget;
    float value = 0;
    bool slider = false;
    /// The widget was clicked (a checkbox).
    bool clicked(Widget w) const { return !slider && widget == w; }
    /// A slider's new value, while it is dragged.
    std::optional<float> slid(Widget w) const {
        if (!slider || widget != w) return std::nullopt;
        return value;
    }
};

/// One keyboard shortcut (ct_events.Shortcut): a scancode, the modifiers that must be held
/// exactly (Input::shift, ctrl, alt, cmd) and the widget it activates.
template <class Widget>
struct Shortcut {
    std::uint8_t code;
    std::uint8_t mods;
    Widget widget;
};

/// A static UI over tables `T` and state `State`: a value, no buffer. `T` is what lcgf-gen
/// --static writes; the generated `<name>::Ui` derives from this and adds a setter per field.
template <class T, class State>
class Ui {
public:
    using V4 = std::array<float, 4>;
    State state;

    explicit Ui(State s = {}) : state(s) {}
    Ui(const Ui&) = delete;
    Ui& operator=(const Ui&) = delete;

    /// One frame in a `width` x `height` viewport: the labels' text and the regions' selectors
    /// from `state`, laid out and painted, every bound colour patched in (ct_paint's
    /// `rebuildLiveText`). The draw list is read in place until the next frame.
    const DrawList& frame(float width, float height) {
        gather();
        select();
        layout(width, height);
        paint(strings_len_);
        patch_all();
        return draw_;
    }

    using Field = typename T::Field;

    /// Lays out again only what field `F` moves (ct_layout's `relayout`), after a frame: the
    /// subtree of the common relayout boundary of its labels, decided at compile time. A field
    /// no label shows moves nothing. Then a full repaint, as `frame`'s. Last frame's viewport
    /// and selection stay.
    template <Field F>
    const DrawList& relayout() {
        constexpr auto span = T::spans[u32(F)];
        if constexpr (span[0] == none) {
            return draw_;
        } else {
            gather();
            const float vw = full_.size[0][0], vh = full_.size[1][0];
            if constexpr (T::folded || (span[0] == 0 && !T::live)) {
                // The whole tree: the folded passes, or a field shown above every boundary.
                layout(vw, vh);
            } else {
                using Full = Tree<T, typename T::full>;
                Full::template relayout_span<span[0], span[1]>(full_, w_, h_);
                finalize(span[0], span[1]);
            }
            paint(strings_len_);
            patch_all();
            return draw_;
        }
    }

    /// Writes field `F`'s colour into the quads bound to it (ct_paint's `Patches.apply`): the
    /// rgb of their fill or border, their alpha kept, and marks them dirty. No layout, no paint.
    template <Field F>
    void patch() {
        const u32 bits = T::color(state, u32(F));
        u32 cursor = 0, seen = 0;
        for (u32 e = 0; e < T::patch_count; ++e) {
            const auto& p = T::patches[e];
            if (p[0] != u32(F)) continue;
            const u32 k = p[1];
            u32 row = k;
            if (raw_.quad_len != quads) {
                for (u32 j = cursor; j < k; ++j) seen += shown(j);
                cursor = k;
                row = shown(k) ? seen : none;
            }
            if (row == none) continue;
            Quad& q = quads_[row];
            if (p[2] == 0) q.fill = (q.fill & 0xff000000u) | (bits & 0xffffffu);
            else q.border_color = (q.border_color & 0xff000000u) | (bits & 0xffffffu);
            dirty_[row] = true;
        }
    }

    /// The draw list's quads a patch changed since `clear_dirty`; all of them after a frame.
    std::span<const bool> dirty() const { return {dirty_, quads}; }
    void clear_dirty() {
        for (u32 k = 0; k < quads; ++k) dirty_[k] = false;
    }

    const DrawList& frame(const Input& in) { return frame(in.viewport[0], in.viewport[1]); }
    const DrawList& draw() const { return draw_; }

    using Widget = typename T::Widget;

    /// The topmost widget under (x, y) in the last frame's layout (ct_events.at): half-open
    /// edges, and the latest widget wins where widgets overlap.
    std::optional<Widget> at(float x, float y) const {
        const u32 k = at_slot(x, y);
        if (k == none) return std::nullopt;
        return Widget(T::widget_rows[k]);
    }

    /// This frame's pointer event (ct_events.pointer): a press picks the widget under the
    /// pointer; a checkbox is clicked when the release is over it too; a slider reports its
    /// value every frame it is held.
    std::optional<Event<Widget>> pointer(const Input& in) {
        const bool down = (in.buttons & Input::left) != 0;
        const float x = in.pointer[0], y = in.pointer[1];
        if (down && !down_) pressed_ = at_slot(x, y);
        down_ = down;
        const u32 k = pressed_;
        if (k == none) return std::nullopt;
        if (!down) pressed_ = none;
        const Widget w = Widget(T::widget_rows[k]);
        if (T::widget_slider[k]) {
            if (!down) return std::nullopt;
            const V4 r = vis_of(T::widget_rows[k]);
            const float x0 = r[0];
            const float span = r[2] - x0;
            const float v = std::max(0.0f, std::min((x - x0) / std::max(span, std::numeric_limits<float>::min()), 1.0f));
            return Event<Widget>{w, v, true};
        }
        if (down || at_slot(x, y) != k) return std::nullopt;
        return Event<Widget>{w};
    }

    /// The widget Tab (`back` false) or Shift+Tab moves focus to from `from`, wrapping
    /// (ct_events.nextFocus).
    static std::optional<Widget> next_focus(std::optional<Widget> from, bool back) {
        constexpr u32 len = T::focusables;
        if constexpr (len == 0) return std::nullopt;
        else {
            u32 at = none;
            if (from)
                for (u32 k = 0; k < len; ++k)
                    if (T::widget_rows[T::focus_order[k]] == u32(*from)) at = k;
            const u32 k = at == none ? (back ? len - 1 : 0) : back ? (at + len - 1) % len
                                                                   : (at + 1) % len;
            return Widget(T::widget_rows[T::focus_order[k]]);
        }
    }
    /// Moves focus for every Tab press and repeat in this frame's keys; Shift goes back.
    void focus_keys(const Input& in, std::uint8_t tab = Input::tab) {
        for (u32 i = 0; i < in.events_len; ++i) {
            const lcgf_key_event& e = in.events[i];
            if (e.code != tab || (e.kind != 0 && e.kind != 2)) continue;
            focus_ = next_focus(focus_, (e.mods & Input::shift) != 0);
        }
    }
    std::optional<Widget> focus() const { return focus_; }
    void set_focus(std::optional<Widget> w) { focus_ = w; }

    /// The widget a shortcut of `list` activates for key `code` with exactly `mods` held.
    template <std::size_t N>
    static std::optional<Widget> shortcut(const std::array<Shortcut<Widget>, N>& list, std::uint8_t code, std::uint8_t mods) {
        for (const auto& sc : list)
            if (sc.code == code && (sc.mods & 0xf) == (mods & 0xf)) return sc.widget;
        return std::nullopt;
    }

private:
    static constexpr u32 none = 0xffffffffu;
    u32 pressed_ = none;
    bool down_ = false;
    std::optional<Widget> focus_;

    u32 at_slot(float x, float y) const {
        u32 found = none;
        for (u32 k = 0; k < T::widgets; ++k) {
            const V4 r = vis_of(T::widget_rows[k]);
            if (x >= r[0] && x < r[2] && y >= r[1] && y < r[3]) found = k;
        }
        return found;
    }

    /// The visible rect of row i as the comptime UI keeps it, in its coordinate type.
    V4 vis_of(u32 i) const {
        const u32 g = geometry(*this, i);
        V4 r{vis_[0][g], vis_[1][g], vis_[2][g], vis_[3][g]};
        if constexpr (T::coord != 0) {
            constexpr float hi = float((std::int64_t(1) << (T::coord - 1)) - 1);
            constexpr float lo = -hi - 1;
            for (float& x : r) x = float(std::int32_t(std::min(std::max(x, lo), hi)));
        }
        return r;
    }

    using B = typename T::full;
    static constexpr u32 n = T::n;
    static constexpr u32 quads = T::quads;
    static constexpr u32 runs = T::labels;
    static constexpr u32 ops = quads + runs + 4;

    struct Empty {};
    Scratch<B> full_{};
    std::conditional_t<T::folded, Scratch<typename T::skel>, Empty> skel_{};
    float rect_[4][n]{}, vis_[4][n]{};
    V4 child_clip_[n]{};
    std::uint8_t visible_[n]{};
    u32 slot_source_[T::slot_count]{};
    Select sel_[T::regions > 0 ? T::regions : 1]{};
    float w_[runs > 0 ? runs : 1]{}, h_[runs > 0 ? runs : 1]{};
    std::array<u32, 2> spans_[runs > 0 ? runs : 1]{};
    char strings_[T::string_cap]{};
    Quad quads_[quads + 1]{};
    TextRun runs_[runs + 1]{};
    std::uint8_t op_kind_[ops]{}, cmd_kind_[ops]{};
    u32 op_key_[ops]{}, op_ref_[ops]{}, cmd_first_[ops]{}, cmd_count_[ops]{}, cmd_key_[ops]{};
    lcgf_draw raw_{};
    DrawList draw_{raw_};

    u32 strings_len_ = 0;
    bool dirty_[quads + 1]{};

    /// The labels' text, written into the frame's strings in label order (string fields, and
    /// formats as the generator wrote them out), and measured.
    void gather() {
        Sink o{strings_, T::string_cap};
        u32 end[T::labels > 0 ? T::labels : 1];
        T::texts(state, o, end);
        u32 at = 0;
        for (u32 k = 0; k < T::labels; ++k) {
            const u32 len = end[k] - at;
            spans_[k] = {at, len};
            at = end[k];
            // Mono's measure: one advance per byte, one line tall.
            w_[k] = float(len) * F(T::text_px) * F(T::advance);
            h_[k] = F(T::text_px) * F(T::line);
        }
        strings_len_ = at;
    }

    /// The regions' selections from the state.
    void select() {
        if constexpr (T::regions > 0) {
            u32 sn[T::regions];
            float scroll[T::regions];
            T::select(state, sn, scroll);
            for (u32 g = 0; g < T::regions; ++g) {
                const Region& r = T::full::regions[g];
                sel_[g] = r.scroll ? select_window(sn[g], r.max - 1, F(r.height), scroll[g]) : Select{sn[g]};
            }
        }
    }

    /// Every pass over the whole tree (through the skeleton when folded), then finalize.
    void layout(float width, float height) {
        using Full = Tree<T, typename T::full>;
        if constexpr (!T::folded) {
            Full::passes(full_, w_, h_, sel_, width, height);
        } else {
            Tree<T, typename T::skel>::passes(skel_, w_, h_, sel_, width, height);
            for (u32 j = 0; j < n; ++j) {
                const u32 b = T::expand_base[j];
                for (int a = 0; a < 2; ++a) {
                    full_.pos[a][j] = skel_.pos[a][b] + F(T::expand_rel[a][j]);
                    full_.size[a][j] = skel_.size[a][b] * F(T::expand_keep[j]) + F(T::expand_size[a][j]);
                }
            }
            if constexpr (T::regions > 0) Full::live_mask(full_, sel_);
        }
        // `setSlotSources`: each shared slot shows its live row, else its default.
        if constexpr (T::slots_shared) {
            for (u32 k = 0; k < T::slot_count; ++k) slot_source_[k] = T::slot_defaults[k];
            for (u32 i = 0; i < n; ++i)
                if (full_.mask[i] != 0) slot_source_[T::slot_of[i]] = i;
        }
        finalize(0, n);
    }

    /// Every field's patches (`applyAll`); every quad dirty.
    void patch_all() {
        if constexpr (T::patch_count > 0) patch_fields(std::make_integer_sequence<u32, T::fields>{});
        for (u32 k = 0; k < quads; ++k) dirty_[k] = true;
    }
    template <u32... K>
    void patch_fields(std::integer_sequence<u32, K...>) {
        (patch<Field(K)>(), ...);
    }

    /// Pixel-snapped rects, then clip rects and visibility (layout.finalize, finalizeSpan over
    /// rows [first, last)).
    void finalize(u32 first, u32 last) {
        for (u32 j = first; j < last; ++j) {
            const float x = full_.pos[0][j], y = full_.pos[1][j];
            // Four lanes of one row at once, so the rounding vectorizes.
            const V4 in{x, y, x + full_.size[0][j], y + full_.size[1][j]};
            V4 out;
            for (int k = 0; k < 4; ++k) out[k] = round_(in[k]);
            for (int k = 0; k < 4; ++k) rect_[k][j] = out[k];
        }
        constexpr float inf = std::numeric_limits<float>::infinity();
        constexpr V4 sign{1, 1, -1, -1};
        if (first == 0) child_clip_[0] = {-inf, -inf, -inf, -inf};
        for (u32 i = first; i < last; ++i) {
            V4 r, v, out;
            const V4 inherited = child_clip_[B::parent[i]];
            V4 clip;
            for (int k = 0; k < 4; ++k) {
                r[k] = rect_[k][i] * sign[k];
                v[k] = maxF(r[k], inherited[k]);
                const float inner = B::clips[i] != 0 ? r[k] + F(B::border[i]) : -inf;
                clip[k] = maxF(inherited[k], inner);
                out[k] = v[k] * sign[k];
                vis_[k][i] = out[k];
            }
            child_clip_[i] = clip;
            visible_[i] = std::uint8_t(u32(out[0] < out[2]) & u32(out[1] < out[3]));
        }
    }

    /// The row whose geometry descriptor `i` reads: its slot's live row when slots are shared.
    static u32 geometry(const Ui& ui, u32 i) {
        if constexpr (T::slots_shared) return ui.slot_source_[T::slot_of[i]];
        else return i;
    }

    /// Rect of row i as the comptime UI keeps it: in its coordinate type.
    V4 rect_of(u32 i) const {
        const u32 g = geometry(*this, i);
        V4 r{rect_[0][g], rect_[1][g], rect_[2][g], rect_[3][g]};
        if constexpr (T::coord != 0) {
            constexpr float hi = float((std::int64_t(1) << (T::coord - 1)) - 1);
            constexpr float lo = -hi - 1;
            for (float& x : r) x = float(std::int32_t(std::min(std::max(x, lo), hi)));
        }
        return r;
    }

    V4 clip_of(u32 i) const {
        constexpr float inf = std::numeric_limits<float>::infinity();
        if constexpr (!T::has_child_clip) return {-inf, -inf, inf, inf};
        else {
            const V4 c = child_clip_[geometry(*this, i)];
            return {c[0], c[1], -c[2], -c[3]};
        }
    }

    /// Whether template k paints this frame (ct.zig's `shown`): present, and its paint bounds
    /// (a shadow grows by three sigma) inside its parent's clip have area.
    u32 shown(u32 k) const {
        const u32 i = T::paint_node[k];
        const Quad q = std::bit_cast<Quad>(T::templates[k]);
        const V4 r = rect_of(i), c = clip_of(T::clip_node[k]);
        const float sigma = q.params[1];
        const float g = std::bit_cast<u32>(q.params[0]) == 3 && std::isfinite(sigma) ? std::fmax(0.f, sigma) * 3 : 0.f;
        const float b0 = std::fmax(r[0] - g, c[0]), b1 = std::fmax(r[1] - g, c[1]);
        const float b2 = std::fmin(r[2] + g, c[2]), b3 = std::fmin(r[3] + g, c[3]);
        u32 present = 1;
        if constexpr (T::regions > 0) present = visible_[i];
        return present & u32(b0 < b2) & u32(b1 < b3);
    }

    void emit_quads(u32 first, u32 end, u32& quad, u32& op) {
        for (u32 k = first; k < end; ++k) {
            const u32 i = T::paint_node[k];
            Quad q = std::bit_cast<Quad>(T::templates[k]);
            const V4 r = rect_of(i), c = clip_of(T::clip_node[k]);
            std::memcpy(q.rect, r.data(), sizeof q.rect);
            std::memcpy(q.clip, c.data(), sizeof q.clip);
            quads_[quad] = q;
            op_kind_[op] = 0;
            op_key_[op] = T::keys[k];
            op_ref_[op] = quad;
            const u32 s = shown(k);
            quad += s;
            op += s;
        }
    }

    /// paint.encode: consecutive quad ops with equal keys form one command.
    void encode(u32 op_len) {
        u32 count_ = 0, first = 0, count = 0, prev_key = 0;
        std::uint8_t prev_kind = 0xff;
        for (u32 j = 0; j < op_len; ++j) {
            const std::uint8_t kind = op_kind_[j];
            const u32 key = op_key_[j];
            const u32 brk = u32(kind != 0) | u32(kind != prev_kind) | u32(key != prev_key);
            count_ += brk;
            const u32 k = count_ - 1;
            cmd_kind_[k] = kind;
            cmd_key_[k] = key;
            first = brk ? op_ref_[j] : first;
            count = (brk ? 0 : count) + 1;
            cmd_first_[k] = first;
            cmd_count_[k] = count;
            prev_kind = kind;
            prev_key = key;
        }
        raw_.cmd_len = count_;
    }

    /// ct_paint's `emit` and `emitLiveText`.
    void paint(u32 strings_len) {
        u32 quad = 0, op = 0;
        if constexpr (runs == 0) {
            emit_quads(0, quads, quad, op);
            if (quad == quads) {
                for (u32 b = 0; b < T::batches; ++b) {
                    cmd_kind_[b] = 0;
                    cmd_first_[b] = T::batch_first[b];
                    cmd_count_[b] = T::batch_count[b];
                    cmd_key_[b] = T::batch_key[b];
                }
                raw_.cmd_len = T::batches;
            } else encode(op);
        } else {
            u32 first = 0, r = 0;
            for (u32 l = 0; l < runs; ++l) {
                const auto& plan = T::label_plans[l]; // node, parent, quad_end, padding[4], color
                emit_quads(first, plan[2], quad, op);
                first = plan[2];
                V4 rect = rect_of(plan[0]);
                for (int k = 0; k < 4; ++k) rect[k] = rect[k] + F(plan[3 + k]);
                const V4 clip = clip_of(plan[1]);
                TextRun& run = runs_[r];
                std::memcpy(run.rect, rect.data(), sizeof run.rect);
                std::memcpy(run.clip, clip.data(), sizeof run.clip);
                run.start = spans_[l][0];
                run.bytes = spans_[l][1];
                run.px = F(T::text_px);
                run.color = plan[7];
                run.font = T::text_font;
                run.opacity = 1;
                run.xform[0] = 1, run.xform[1] = 0, run.xform[2] = 0, run.xform[3] = 1, run.xform[4] = 0, run.xform[5] = 0;
                for (int k = 0; k < 4; ++k) run.clip_radii[k] = 0;
                op_kind_[op] = 1;
                op_key_[op] = 0;
                op_ref_[op] = r;
                op += visible_[plan[0]];
                if constexpr (T::regions > 0) r += u32(full_.mask[plan[0]] != 0);
                else r += 1;
            }
            emit_quads(first, quads, quad, op);
            raw_.run_len = r;
            encode(op);
        }
        if constexpr (runs == 0) raw_.run_len = 0;
        raw_.quads = quads_;
        raw_.quad_len = quad;
        raw_.runs = runs_;
        raw_.strings = strings_;
        raw_.strings_len = strings_len;
        raw_.cmd_kind = cmd_kind_;
        raw_.cmd_first = cmd_first_;
        raw_.cmd_count = cmd_count_;
        raw_.cmd_key = cmd_key_;
        raw_.custom_len = 0;
        raw_.customs = nullptr;
    }
};

} // namespace lcgf::ct
