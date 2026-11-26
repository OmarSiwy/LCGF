// lcgf.hpp: LCGF for C++20. The code lcgf-gen writes for a spec (<name>.lcgf.hpp) builds on
// this header. A frame is one call through the C seam (lcgf.h) into the prebuilt liblcgf; the
// draw list it returns is read in place, as spans over its columns. There are no virtual calls,
// no allocation and no copies of rows: the caller owns the buffer, the tables are rodata, and
// the state is a plain struct.
#pragma once
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

#include <lcgf.h>

namespace lcgf {

inline constexpr std::size_t column_align = LCGF_COLUMN_ALIGN;

enum class Status : int {
    ok = LCGF_OK,
    not_tables = LCGF_NOT_TABLES,
    version = LCGF_VERSION,
    layout_hash = LCGF_LAYOUT_HASH,
    truncated = LCGF_TRUNCATED,
    buffer_too_small = LCGF_BUFFER_TOO_SMALL,
    unaligned = LCGF_UNALIGNED,
};

/// A string field: a pointer and a length, as the tables lay it out. It does not own the bytes;
/// they must outlive the frames that show them.
struct Str {
    const char* ptr = nullptr;
    std::size_t len = 0;

    constexpr Str() = default;
    template <std::size_t N>
    constexpr Str(const char (&s)[N]) : ptr(s), len(N - 1) {}
    constexpr Str(std::string_view s) : ptr(s.data()), len(s.size()) {}
    constexpr std::string_view view() const { return {ptr, len}; }
};
static_assert(sizeof(Str) == 2 * sizeof(void*));

/// What the host tells a frame: viewport and pointer in logical pixels, buttons and modifiers
/// as bits (Input::left, Input::shift, ...).
struct Input : lcgf_input {
    static constexpr std::uint32_t left = 1, right = 2, middle = 4;
    static constexpr std::uint32_t shift = 1, ctrl = 2, alt = 4, cmd = 8;
    static constexpr std::uint8_t tab = 0x2b;
    constexpr Input() : lcgf_input{{800, 600}, {-1, -1}, 1.0f / 60.0f, 1, 0, 0, nullptr, 0} {}
    void keys(std::span<const lcgf_key_event> e) {
        events = e.data();
        events_len = static_cast<std::uint32_t>(e.size());
    }
};

using Quad = lcgf_quad;
using TextRun = lcgf_text_run;
using CustomDraw = lcgf_custom_draw;

enum class CmdKind : std::uint8_t { quads = 0, text = 1, custom = 2 };

/// One draw command: a batch of quads sharing a texture and material (`key`), one text run, or
/// one custom draw.
struct Command {
    CmdKind kind;
    std::uint32_t first, count, key;
};

/// A frame's draw list, read in place. Valid until the next frame of the same UI.
class DrawList {
public:
    explicit DrawList(const lcgf_draw& d) : d_(&d) {}
    std::span<const Quad> quads() const { return {d_->quads, d_->quad_len}; }
    std::span<const TextRun> runs() const { return {d_->runs, d_->run_len}; }
    std::span<const CustomDraw> customs() const { return {d_->customs, d_->custom_len}; }
    std::string_view strings() const { return {d_->strings, d_->strings_len}; }
    std::string_view text(const TextRun& r) const { return strings().substr(r.start, r.bytes); }
    std::uint32_t command_count() const { return d_->cmd_len; }
    Command command(std::uint32_t i) const {
        return {CmdKind(d_->cmd_kind[i]), d_->cmd_first[i], d_->cmd_count[i], d_->cmd_key[i]};
    }
    const lcgf_draw& raw() const { return *d_; }

private:
    const lcgf_draw* d_;
};

/// What the pointer did this frame, by widget (the generated `Widget` enum).
template <class Widget>
class Events {
public:
    Events() = default;
    explicit Events(const lcgf_frame& f) : widget_(f.widget), value_(f.value), focus_(f.focus), wake_(f.wake) {}
    /// The widget was clicked: a button, or a checkbox (already toggled in the state).
    bool clicked(Widget w) const { return widget_ == static_cast<std::uint32_t>(w); }
    /// A slider's new value (already written to the state), while it is dragged.
    std::optional<float> slid(Widget w) const {
        if (widget_ != static_cast<std::uint32_t>(w)) return std::nullopt;
        return value_;
    }
    std::optional<Widget> widget() const {
        if (widget_ == LCGF_NO_WIDGET) return std::nullopt;
        return static_cast<Widget>(widget_);
    }
    /// The widget keyboard focus is on (Tab moves it), if any.
    std::optional<Widget> focus() const {
        if (focus_ == LCGF_NO_WIDGET) return std::nullopt;
        return static_cast<Widget>(focus_);
    }
    /// Seconds until the UI needs a frame though nothing happened: 0 while a spring moves.
    float wake() const { return wake_; }

private:
    std::uint32_t widget_ = LCGF_NO_WIDGET;
    float value_ = 0;
    std::uint32_t focus_ = LCGF_NO_WIDGET;
    float wake_ = 0;
};

/// A UI over its tables. The generated `<name>::Ui` derives from it and adds a setter per
/// field. Not copyable: the buffer holds the UI's working columns.
template <class State, class Widget>
class Ui {
public:
    State state;

    Ui(std::span<const std::uint32_t> tables, std::span<std::byte> buffer, State s)
        : state(s), buf_(buffer.data()) {
        status_ = static_cast<Status>(lcgf_ui_init(tables.data(), tables.size(), buffer.data(), buffer.size()));
    }
    Ui(const Ui&) = delete;
    Ui& operator=(const Ui&) = delete;

    /// `Status::ok`, or why the tables or the buffer were refused (then `frame` must not run).
    Status status() const { return status_; }

    /// One frame: the pointer's event applied to the state, then built, laid out and painted.
    const DrawList& frame(const Input& in) {
        LCGF_FRAME(buf_, &state, &in, &last_);
        draw_ = DrawList(last_.draw);
        events_ = Events<Widget>(last_);
        return draw_;
    }
    const DrawList& draw() const { return draw_; }
    const Events<Widget>& events() const { return events_; }

private:
    std::byte* buf_;
    Status status_;
    lcgf_frame last_{};
    DrawList draw_{last_.draw};
    Events<Widget> events_{};
};

/// A static UI (lcgf-gen --static): the comptime pipeline over its tables. The generated
/// `<name>::Ui` derives from it and adds a setter per field. A frame reads only the labels'
/// text from the state; it lays the UI out in the viewport and paints it.
template <class State>
class StaticUi {
public:
    State state;

    StaticUi(std::span<const std::uint32_t> tables, std::span<std::byte> buffer, State s)
        : state(s), buf_(buffer.data()) {
        status_ = static_cast<Status>(lcgf_ct_init(tables.data(), tables.size(), buffer.data(), buffer.size()));
    }
    StaticUi(const StaticUi&) = delete;
    StaticUi& operator=(const StaticUi&) = delete;

    /// `Status::ok`, or why the tables or the buffer were refused (then `frame` must not run).
    Status status() const { return status_; }

    /// One frame in a `width` x `height` viewport.
    const DrawList& frame(float width, float height) {
        LCGF_CT_FRAME(buf_, &state, width, height, &last_);
        draw_ = DrawList(last_);
        return draw_;
    }
    const DrawList& frame(const Input& in) { return frame(in.viewport[0], in.viewport[1]); }
    const DrawList& draw() const { return draw_; }

private:
    std::byte* buf_;
    Status status_;
    lcgf_draw last_{};
    DrawList draw_{last_};
};

/// An aligned buffer of exactly `N` bytes, for `<name>::bytes`.
template <std::size_t N>
struct alignas(column_align) Buffer {
    std::byte bytes[N];
    std::span<std::byte> span() { return {bytes, N}; }
};

} // namespace lcgf
