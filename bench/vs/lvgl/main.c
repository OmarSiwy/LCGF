// The scenes of bench/scenes/ on LVGL (https://github.com/lvgl/lvgl), for the comparison of
// docs/perf/vs.md. LVGL is retained: each scene's objects are created once (in frame 0) and a
// frame applies that frame's changes the LVGL way (pointer through an input device, new label
// texts, widths or resolution), then lv_refr_now lays out and redraws the invalidated areas.
//
// So a frame here includes software rasterisation into a 32-bit partial buffer (LVGL renders as
// it draws; it has no draw list to stop at), where tools/bench stops at the draw list. In
// exchange LVGL only redraws what changed, so a scene where little changes costs little. The
// `layout` line times the changes plus lv_obj_update_layout alone, without the redraw.
// Text is LVGL's Montserrat at 14 and 20 px; springs come from bench/vs/harness.h.
#include <poll.h>
#include "lvgl/lvgl.h"
#include "../harness.h"

#define MAX_W 1920
#define MAX_H 1240
static uint32_t buf[MAX_W * MAX_H / 10];
static lv_display_t *disp;
static lv_indev_t *indev;
static VsInput cur;
static uint64_t flushed; // pixels flushed, the frame's output

static uint32_t tick(void) { return (uint32_t)(vs_now() / 1000000u); }
static void flush(lv_display_t *d, const lv_area_t *a, uint8_t *px) {
    (void)px;
    flushed += (uint64_t)lv_area_get_width(a) * (uint64_t)lv_area_get_height(a);
    lv_display_flush_ready(d);
}
static void read_pointer(lv_indev_t *i, lv_indev_data_t *data) {
    (void)i;
    data->point.x = (int32_t)cur.px, data->point.y = (int32_t)cur.py;
    data->state = LV_INDEV_STATE_RELEASED;
}

static lv_obj_t *box(lv_obj_t *parent, lv_flex_flow_t flow) {
    lv_obj_t *o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_set_flex_flow(o, flow);
    lv_obj_set_size(o, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    return o;
}
static lv_obj_t *label(lv_obj_t *parent, const char *s, const lv_font_t *font) {
    lv_obj_t *l = lv_label_create(parent);
    lv_label_set_text_static(l, s);
    if (font) lv_obj_set_style_text_font(l, font, 0);
    return l;
}

static void form(lv_obj_t *scr) {
    lv_obj_t *root = box(scr, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_size(root, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_pad_all(root, 12, 0);
    lv_obj_set_style_pad_row(root, 4, 0);
    lv_obj_set_style_bg_opa(root, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(root, lv_color_make(30, 31, 36), 0);
    label(root, "Account settings", &lv_font_montserrat_20);
    lv_obj_t *sep = box(root, LV_FLEX_FLOW_ROW);
    lv_obj_set_size(sep, LV_PCT(100), 1);
    for (int r = 0; r < 21; r++) {
        lv_obj_t *row = box(root, LV_FLEX_FLOW_ROW);
        lv_obj_set_width(row, LV_PCT(100));
        lv_obj_set_style_pad_column(row, 6, 0);
        lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        lv_obj_set_width(label(row, vs_form_names[r], NULL), 90);
        lv_obj_t *field = lv_textarea_create(row);
        lv_textarea_set_one_line(field, true);
        lv_textarea_set_text(field, vs_form_names[r]);
        lv_obj_set_flex_grow(field, 1);
        lv_checkbox_set_text_static(lv_checkbox_create(row), "On");
        lv_obj_t *slider = lv_slider_create(row);
        lv_slider_set_range(slider, 0, 100);
        lv_slider_set_value(slider, 50, LV_ANIM_OFF);
        lv_obj_set_flex_grow(slider, 1);
    }
    lv_obj_t *footer = box(root, LV_FLEX_FLOW_ROW);
    lv_obj_set_width(footer, LV_PCT(100));
    lv_obj_set_style_pad_column(footer, 6, 0);
    lv_obj_set_flex_align(footer, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    static const char *const buttons[3] = {"Cancel", "Reset", "Save"};
    for (int i = 0; i < 3; i++) label(lv_button_create(footer), buttons[i], NULL);
}

// The list recycles one row object per visible row, as an LVGL list of 100,000 rows would: each
// frame moves the rows to where they fall and gives them their row's text and colour.
enum { row_h = 24, visible = 800 / row_h + 2 };
static lv_obj_t *rows[visible], *row_text[visible], *row_name[visible];
static void list_create(lv_obj_t *scr) {
    for (int i = 0; i < visible; i++) {
        lv_obj_t *row = rows[i] = box(scr, LV_FLEX_FLOW_ROW);
        lv_obj_set_size(row, LV_PCT(100), row_h);
        lv_obj_set_style_pad_hor(row, 8, 0);
        lv_obj_set_style_pad_column(row, 6, 0);
        lv_obj_set_style_bg_opa(row, LV_OPA_COVER, 0);
        lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        row_text[i] = lv_label_create(row);
        row_name[i] = lv_label_create(row);
        lv_obj_t *dot = box(row, LV_FLEX_FLOW_ROW);
        lv_obj_set_size(dot, 12, 12);
        lv_obj_set_style_bg_opa(dot, LV_OPA_COVER, 0);
        lv_obj_set_style_bg_color(dot, lv_color_make(90, 140, 255), 0);
    }
}
static void list_update(uint32_t scroll) {
    uint32_t first = scroll / row_h;
    for (uint32_t i = 0; i < visible; i++) {
        uint32_t r = first + i;
        lv_obj_set_y(rows[i], (int32_t)(r * row_h) - (int32_t)scroll);
        lv_obj_set_style_bg_color(rows[i], r % 2 ? lv_color_make(58, 60, 70) : lv_color_make(30, 31, 36), 0);
        lv_label_set_text_fmt(row_text[i], "Row %u", r);
        lv_label_set_text_static(row_name[i], vs_list_names[r % 7]);
    }
}

static void prose(lv_obj_t *scr) {
    lv_obj_t *root = box(scr, LV_FLEX_FLOW_ROW);
    lv_obj_set_size(root, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_pad_all(root, 12, 0);
    lv_obj_set_style_pad_column(root, 16, 0);
    lv_obj_t *side = box(root, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_width(side, 160);
    lv_obj_set_style_pad_row(side, 2, 0);
    for (int i = 0; i < 120; i++) lv_label_set_text_fmt(lv_label_create(side), "Chapter %d", i + 1);
    lv_obj_t *main = box(root, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_grow(main, 1);
    lv_obj_set_style_pad_row(main, 8, 0);
    for (int s = 0; s < 12; s++) {
        lv_obj_t *h = lv_label_create(main);
        lv_label_set_text_fmt(h, "Section %d", s + 1);
        lv_obj_set_style_text_font(h, &lv_font_montserrat_20, 0);
        for (int p = 0; p < 4; p++) {
            lv_obj_t *l = label(main, vs_prose[(s + p) % 4], NULL);
            lv_obj_set_width(l, LV_PCT(100));
            lv_label_set_long_mode(l, LV_LABEL_LONG_MODE_WRAP);
        }
    }
}

static VsSprings springs_state;
static lv_obj_t *bars[1000];
static void springs_create(lv_obj_t *scr) {
    lv_obj_t *root = box(scr, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_all(root, 8, 0);
    lv_obj_set_style_pad_row(root, 2, 0);
    for (int r = 0; r < 40; r++) {
        lv_obj_t *row = box(root, LV_FLEX_FLOW_ROW);
        lv_obj_set_style_pad_column(row, 2, 0);
        for (int c = 0; c < 25; c++) {
            lv_obj_t *bar = bars[r * 25 + c] = box(row, LV_FLEX_FLOW_ROW);
            lv_obj_set_size(bar, 4, 16);
            lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
            lv_obj_set_style_bg_color(bar, lv_color_make(90, 140, 255), 0);
        }
    }
}
static void springs_update(uint32_t tick_k, float dt) {
    vs_springs_step(&springs_state, tick_k, dt);
    for (int i = 0; i < 1000; i++) lv_obj_set_width(bars[i], (int32_t)(springs_state.x[i] + 0.5f));
}

static uint64_t layout_ns[VS_FRAMES];
static uint64_t vs_frame(int scene, uint32_t k) {
    cur = vs_input(scene, k);
    if (k == 0) {
        lv_obj_t *scr = lv_screen_active();
        lv_obj_clean(scr);
        lv_obj_set_style_bg_color(scr, lv_color_make(30, 31, 36), 0);
        if (scene == VS_FORM || scene == VS_IDLE) form(scr);
        if (scene == VS_LIST) list_create(scr);
        if (scene == VS_TEXT || scene == VS_RESIZE) prose(scr);
        if (scene == VS_SPRINGS) springs_create(scr);
    }
    uint64_t t0 = vs_now();
    lv_display_set_resolution(disp, (int32_t)cur.w, (int32_t)cur.h);
    lv_indev_read(indev);
    if (scene == VS_LIST) list_update(cur.scroll);
    if (scene == VS_SPRINGS) springs_update(cur.tick, cur.dt);
    lv_obj_update_layout(lv_screen_active());
    layout_ns[k] = vs_now() - t0;
    flushed = 0;
    lv_refr_now(disp);
    return flushed;
}

// LVGL's own host loop: lv_timer_handler runs the due timers (display refresh, input read) and
// says how long until the next one; the host sleeps that long or until input (stdin) arrives.
static void vs_idle(void) {
    struct pollfd in = {.fd = 0, .events = POLLIN};
    char byte;
    for (;;) {
        uint32_t ms = lv_timer_handler();
        if (poll(&in, 1, ms == LV_NO_TIMER_READY ? -1 : (int)ms) > 0 && read(0, &byte, 1) <= 0) return;
    }
}

int main(int argc, char **argv) {
    lv_init();
    lv_tick_set_cb(tick);
    disp = lv_display_create(800, 600);
    lv_display_set_color_format(disp, LV_COLOR_FORMAT_XRGB8888);
    lv_display_set_buffers(disp, buf, NULL, sizeof buf, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(disp, flush);
    indev = lv_indev_create();
    lv_indev_set_type(indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(indev, read_pointer);
    int rc = vs_main(argc, argv, "lvgl-9.6.0");
    // Built frames (some area flushed) and the layout-only time, beside the harness's lines.
    if (argc > 1 && strcmp(argv[1], "--idle")) {
        qsort(layout_ns, VS_FRAMES, sizeof layout_ns[0], vs_cmp);
        printf("%-10s %9.1f %9.1f\n", "layout", layout_ns[VS_FRAMES / 2] / 1000.0, layout_ns[VS_FRAMES * 99 / 100] / 1000.0);
    }
    return rc;
}
