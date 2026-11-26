/* lcgf.h: the C seam of LCGF, the only binary contract between liblcgf and the code lcgf-gen
 * writes (C++ and Rust). Generated headers call these few functions; everything else they do
 * inline. src/abi/seam.zig implements them.
 *
 * Tables are what lcgf-gen (or Zig at compile time) made from a UI spec: u32 words with a
 * header (magic, format version, layout hash) that lcgf_ui_init checks once. The caller owns
 * every byte: the tables (rodata), the UI's buffer (lcgf_ui_bytes, aligned to
 * LCGF_COLUMN_ALIGN) and the state struct (generated, laid out as the tables say). */
#ifndef LCGF_H
#define LCGF_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LCGF_FORMAT_VERSION 1u
#define LCGF_COLUMN_ALIGN 64
#define LCGF_NO_WIDGET 0xffffffffu

/* Results of lcgf_tables_check and lcgf_ui_init. */
enum lcgf_status {
    LCGF_OK = 0,
    LCGF_NOT_TABLES = 1,
    LCGF_VERSION = 2,
    LCGF_LAYOUT_HASH = 3,
    LCGF_TRUNCATED = 4,
    LCGF_BUFFER_TOO_SMALL = 5,
    LCGF_UNALIGNED = 6,
};

/* A key event: kind 0 press, 1 release, 2 repeat, 3 text; mods as lcgf_input.mods; code a
 * scancode (Tab, 0x2b, moves focus). */
typedef struct {
    uint8_t kind, mods, code, pad;
    uint32_t at, len;
} lcgf_key_event;

typedef struct {
    float viewport[2];
    float pointer[2]; /* -1, -1 outside the window */
    float dt;
    float scale;
    uint32_t buttons; /* bit 0 left, 1 right, 2 middle */
    uint32_t mods;    /* bit 0 shift, 1 ctrl, 2 alt, 3 cmd */
    const lcgf_key_event *events; /* this frame's keys, in order */
    uint32_t events_len;
} lcgf_input;

typedef struct {
    float rect[4], clip[4], params[4], uv[4], radii[4];
    uint32_t fill, border_color;
    float border, opacity;
    float xform[6];
    float clip_radii[4];
} lcgf_quad;

typedef struct {
    float rect[4], clip[4];
    uint32_t start, bytes;
    float px;
    uint32_t color, font;
    float opacity, xform[6], clip_radii[4];
} lcgf_text_run;

typedef struct {
    float rect[4], clip[4];
    uint64_t data;
    uint32_t id, node;
    float xform[6], clip_radii[4], opacity;
} lcgf_custom_draw;

/* A frame's draw list, read in place: valid until the next lcgf_frame_* on the same UI. */
typedef struct {
    const lcgf_quad *quads;
    uint32_t quad_len;
    uint32_t run_len;
    const lcgf_text_run *runs;
    const char *strings;
    size_t strings_len;
    const uint8_t *cmd_kind; /* 0 quads, 1 text, 2 custom */
    const uint32_t *cmd_first;
    const uint32_t *cmd_count;
    const uint32_t *cmd_key;
    uint32_t cmd_len;
    uint32_t custom_len;
    const lcgf_custom_draw *customs;
} lcgf_draw;

typedef struct {
    lcgf_draw draw;
    uint32_t widget; /* widget slot of this frame's event, or LCGF_NO_WIDGET */
    float value;     /* a slider's new value */
    uint32_t focus;  /* the focused widget's slot, or LCGF_NO_WIDGET */
    float wake;      /* 0 while a spring moves (draw again), infinity at rest */
} lcgf_frame;

/* Checks the header of `tables` (`len` words). */
int lcgf_tables_check(const uint32_t *tables, size_t len);
/* Bytes one UI of these tables needs, or 0 if the tables are refused. */
size_t lcgf_ui_bytes(const uint32_t *tables, size_t len);
/* Places a UI at the start of `buf`; checks the tables once. */
int lcgf_ui_init(const uint32_t *tables, size_t len, void *buf, size_t buf_len);
/* The layout hash this library reads; the tables carry the one they were written with. */
uint32_t lcgf_layout_hash(void);

/* One frame. The name says what the library was specialised for: 32-bit rows, f32
 * coordinates and the SIMD lane count. Generated code names the one its target flags pick
 * (LCGF_FRAME below), so there is no dispatch. */
void lcgf_frame_u32_f32_l4(void *ui, void *state, const lcgf_input *in, lcgf_frame *out);
void lcgf_frame_u32_f32_l8(void *ui, void *state, const lcgf_input *in, lcgf_frame *out);
void lcgf_frame_u32_f32_l16(void *ui, void *state, const lcgf_input *in, lcgf_frame *out);
/* liblcgf_auto.a (LCGF_LANES 0): the lane width chosen from the CPU at the first call of any
 * function, 8 with AVX2 (AVX-512 too) and 4 without; LCGF_FORCE_LANES=4, 8 or 16 forces one
 * the CPU can run. lcgf_auto_lanes() says which, or 0 before the first call. */
void lcgf_frame_u32_f32_auto(void *ui, void *state, const lcgf_input *in, lcgf_frame *out);
uint32_t lcgf_auto_lanes(void);

/* ---- the runtime front end (src/abi/runtime.zig): build the UI each frame in code ---------- */

/* Sizes, as Zig's context.Limits. */
typedef struct {
    uint32_t nodes, texts, customs, strings, anims, depth;
} lcgf_limits;

/* A length: kind 0 fit, 1 px, 2 grow, 3 pct. */
typedef struct {
    uint32_t kind;
    float v;
} lcgf_size;

/* Zig's types.Style as the words it crosses the seam as (plan.zig's encoding): every field in
 * declaration order, one 32-bit word each. Colours are 0xAABBGGRR. lcgf_default_style writes
 * the defaults. */
typedef struct {
    uint32_t participation; /* bits: 1 layout, 2 paint, 4 hit, 8 semantics; 15 is all */
    uint32_t cursor;        /* types.Cursor, 0xffffffff none (inherit) */
    uint32_t dir;
    lcgf_size size[2];
    float min[2];
    float max[2];
    float pad[4];
    float gap;
    uint32_t main, cross;
    uint32_t shrink, floating;
    float offset[2];
    uint32_t clip;
    float scroll[2];
    uint32_t fill, border_color;
    float border, radius;
    uint32_t texture, material;
    float params[4];
    float radii[4];
    float opacity;
    float transform[6];
    float transform_origin[2];
    float uv[4];
    uint32_t paint_reference; /* a row index, 0xffffffff none */
    float paint_outset[4];
    uint32_t role;
    float value;
} lcgf_style;

typedef struct {
    float px;
    uint32_t color, font, wrap;
} lcgf_text_style;

/* The reference widgets' theme (base.Theme), as words. */
typedef struct {
    uint32_t text;
    float text_px;
    uint32_t panel, control, control_hot, control_held, accent;
    float radius, pad, gap;
} lcgf_theme;

/* A style turned into the row the tree stores (tree.zig Template.from): sizing modes as
 * coefficients, enums as factors, paint fields as their GPU row, and the extras row it may need
 * (from `own` on). One word per field. Made by lcgf::Row::From (C++), lcgf::runtime::Row::from
 * (Rust) or lcgf_row_from_style; pushed as it is by the _row calls, so a constant style costs
 * nothing per call. */
typedef struct {
    float min[2], max[2], grow[2], pct[2], pad_lo[2], pad_hi[2], offset[2], scroll[2], main[2];
    float gap, flow, shrink, align_main, align_cross;
    uint32_t clips, sense;
    float params[4];
    uint32_t fill, border_color;
    float radius;
    uint32_t texture, material;
    uint32_t role;
    float value;
    uint32_t text, custom;
    uint32_t own;
    float border, uv[4], radii[4], opacity, transform[6], transform_origin[2];
    uint32_t paint_reference;
    float paint_outset[4];
    uint32_t prepared_texture, paint_revision, participation, cursor;
} lcgf_row;

/* The frame's tree, where a row is pushed (src/abi/runtime.zig's CView): lcgf_rt_view fills
 * it after lcgf_rt_begin, valid until lcgf_rt_end. lcgf/runtime.hpp and lcgf::runtime push
 * rows through it inline, with the stores Zig's own `leaf` makes; a C caller can use the _row
 * calls instead. The counters are pointers: the library's calls move them too. */
typedef struct {
    float params[4];
    uint32_t fill, border_color;
    float radius;
    uint16_t texture, material;
} lcgf_look;

typedef struct {
    float border, uv[4], radii[4], opacity, transform[6], transform_origin[2];
    uint32_t paint_reference;
    float paint_outset[4];
    uint32_t prepared_texture, paint_revision;
    uint8_t participation, active_participation, cursor, active_cursor;
    float alpha, world[6], clip_radii[4]; /* written by paint, not by a push */
} lcgf_extra;

typedef struct {
    uint32_t *len, *xlen;
    bool *overflow;
    uint32_t *depth;
    uint8_t *status; /* bit LCGF_RT_DEPTH_BIT: the stack overflowed */
    uint32_t cap, depth_cap;
    uint32_t *stack, *id, *parent, *end;
    float *min[2], *max[2], *grow[2], *pct[2], *pad_lo[2], *pad_hi[2], *offset[2], *scroll[2], *main[2];
    float *gap, *nkids, *flow, *shrink, *align_main, *align_cross;
    uint8_t *clips, *sense;
    lcgf_look *look;
    uint8_t *role;
    float *value;
    uint32_t *text, *custom, *extra, *scope, *x_node;
    lcgf_extra *x_row;
} lcgf_view;
#define LCGF_RT_DEPTH_BIT 4

/* The layout of lcgf_style, lcgf_text_style, lcgf_row and lcgf_view the library reads:
 * compare with lcgf_rt_layout() before making a context. */
#define LCGF_RT_LAYOUT 0x6645151eu

/* What a widget reports: bit 0 hovered, 1 held, 2 pressed, 3 released, 4 clicked, 5 focused. */
typedef uint8_t lcgf_response;

size_t lcgf_rt_bytes(const lcgf_limits *limits);
int lcgf_rt_init(void *buf, size_t len, const lcgf_limits *limits);
int lcgf_rt_needs_frame(void *rt, const lcgf_input *in);
void lcgf_rt_begin(void *rt, const lcgf_input *in);
void lcgf_rt_end(void *rt, lcgf_frame *out);
uint32_t lcgf_rt_open(void *rt, uint32_t id, const lcgf_style *style);
void lcgf_rt_close(void *rt);
uint32_t lcgf_rt_leaf(void *rt, uint32_t id, const lcgf_style *style);
uint32_t lcgf_rt_text(void *rt, const char *str, size_t len, const lcgf_text_style *ts);
uint32_t lcgf_rt_text_styled(void *rt, const char *str, size_t len, const lcgf_text_style *ts, const lcgf_style *style);
uint32_t lcgf_rt_custom(void *rt, uint32_t id, const lcgf_style *style, uint64_t data);
float lcgf_rt_animate(void *rt, uint32_t id, float target, float stiffness, float damping);
/* A value moving to `target` over `seconds` along `ease` (0 linear, 1 in_quad, 2 out_quad,
 * 3 in_out, 4 in_cubic, 5 out_cubic), keyed by `id` (Frame.tween). */
float lcgf_rt_tween(void *rt, uint32_t id, float target, float seconds, uint32_t ease);
/* Text formatted straight into the frame: write up to *len bytes at lcgf_rt_room, then push
 * them with lcgf_rt_text_written (a text leaf) or lcgf_rt_label_written (lcgf_rt_label's
 * look). Bytes past the room are cut and reported. */
char *lcgf_rt_room(void *rt, size_t *len);
uint32_t lcgf_rt_text_written(void *rt, size_t len, const lcgf_text_style *ts);
uint32_t lcgf_rt_label_written(void *rt, size_t len);
uint32_t lcgf_rt_label(void *rt, const char *str, size_t len);
lcgf_response lcgf_rt_button(void *rt, uint32_t id, const char *str, size_t len);
lcgf_response lcgf_rt_checkbox(void *rt, uint32_t id, bool *value, const char *str, size_t len);
lcgf_response lcgf_rt_slider(void *rt, uint32_t id, float *value, float lo, float hi);
void lcgf_default_theme(lcgf_theme *out);
void lcgf_default_style(lcgf_style *out);
uint32_t lcgf_rt_open_row(void *rt, uint32_t id, const lcgf_row *row);
uint32_t lcgf_rt_leaf_row(void *rt, uint32_t id, const lcgf_row *row);
uint32_t lcgf_rt_custom_row(void *rt, uint32_t id, const lcgf_row *row, uint64_t data);
void lcgf_row_from_style(const lcgf_style *style, lcgf_row *out);
uint32_t lcgf_rt_layout(void);
void lcgf_rt_view(void *rt, lcgf_view *out);

/* ---- static UIs (src/abi/ct.zig): the comptime pipeline, from lcgf-gen --static ------------- */

/* A static UI's structure and style are fixed by its spec, so lcgf-gen lays out what does not
 * depend on the viewport (the fold), and writes the constant columns and the paint templates as
 * words, padded for 16 lanes. A frame reads the labels' text from the state (an lcgf::Str per
 * label, at the offsets the words carry), runs the passes over the skeleton, expands, finalizes
 * and copies the templates. Status codes are lcgf_status's. */
#define LCGF_CT_FORMAT_VERSION 2u
#define LCGF_CT_LAYOUT 0x09d5a282u
int lcgf_ct_check(const uint32_t *tables, size_t len);
/* Bytes one static UI of these tables needs, for any lane count, or 0 if they are refused. */
size_t lcgf_ct_bytes(const uint32_t *tables, size_t len);
int lcgf_ct_init(const uint32_t *tables, size_t len, void *buf, size_t buf_len);
uint32_t lcgf_ct_layout(void);
void lcgf_ct_frame_u32_f32_l4(void *ui, const void *state, float width, float height, lcgf_draw *out);
void lcgf_ct_frame_u32_f32_l8(void *ui, const void *state, float width, float height, lcgf_draw *out);
void lcgf_ct_frame_u32_f32_l16(void *ui, const void *state, float width, float height, lcgf_draw *out);
void lcgf_ct_frame_u32_f32_auto(void *ui, const void *state, float width, float height, lcgf_draw *out);
/* After a frame, with no new viewport or selection: lays out again only what state field
 * `field` (its index in the state) moves, as the comptime pipeline's `relayout` does, and
 * paints again. Returns 1, or 0 when no label shows the field (nothing changed). */
int lcgf_ct_relayout(void *ui, const void *state, uint32_t field, lcgf_draw *out);
/* The colour field `field`'s rgb into the quads bound to it in the last draw list. */
void lcgf_ct_patch(void *ui, const void *state, uint32_t field);
/* One byte per quad of the last draw list: 1 where a patch changed it since lcgf_ct_clear_dirty;
 * all 1 after a frame or relayout. */
const uint8_t *lcgf_ct_dirty(void *ui);
void lcgf_ct_clear_dirty(void *ui);
/* The last draw list again. */
void lcgf_ct_draw(void *ui, lcgf_draw *out);
/* Input over the last frame's layout. Widgets are named by their rows; LCGF_NO_WIDGET is none. The
 * topmost widget under (x, y); this frame's pointer event (0 none, 1 a click, 2 a slider
 * dragged to *value); Tab moving focus; the focused widget; the one Tab (or Shift+Tab, back)
 * moves to from `from`. */
uint32_t lcgf_ct_at(void *ui, float x, float y);
int lcgf_ct_pointer(void *ui, const lcgf_input *in, uint32_t *widget, float *value);
void lcgf_ct_focus_keys(void *ui, const lcgf_input *in, uint8_t tab);
uint32_t lcgf_ct_focus(void *ui);
void lcgf_ct_set_focus(void *ui, uint32_t widget);
uint32_t lcgf_ct_next_focus(void *ui, uint32_t from, int back);
/* A keyboard shortcut: a scancode, the modifiers held exactly (lcgf_input.mods' bits) and the
 * widget it activates. The widget of the first in `list` that key `code` with `mods` matches. */
typedef struct lcgf_shortcut {
    uint8_t code;
    uint8_t mods;
    uint16_t pad_;
    uint32_t widget;
} lcgf_shortcut;
uint32_t lcgf_ct_shortcut(const lcgf_shortcut *list, size_t len, uint8_t code, uint8_t mods);

#ifndef LCGF_LANES
#if defined(__AVX512F__) && defined(LCGF_WANT_16_LANES)
#define LCGF_LANES 16
#elif defined(__AVX2__) || defined(__AVX__)
#define LCGF_LANES 8
#else
#define LCGF_LANES 4
#endif
#endif
#define LCGF_CAT_(a, b) a##b
#define LCGF_CAT(a, b) LCGF_CAT_(a, b)
#if LCGF_LANES == 0
#define LCGF_FRAME lcgf_frame_u32_f32_auto
#define LCGF_CT_FRAME lcgf_ct_frame_u32_f32_auto
#else
#define LCGF_FRAME LCGF_CAT(lcgf_frame_u32_f32_l, LCGF_LANES)
#define LCGF_CT_FRAME LCGF_CAT(lcgf_ct_frame_u32_f32_l, LCGF_LANES)
#endif

#ifdef __cplusplus
}
#endif
#endif
