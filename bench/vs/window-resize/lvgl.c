// LVGL lays out and rasterizes flex-aligned objects into the XRGB8888 XImage.
#include "lvgl/lvgl.h"
#include "window.h"

static uint32_t tick(void) { return 0; } // No animations or timers in this scene.
static void flush(lv_display_t *d, const lv_area_t *area, uint8_t *bytes) {
    (void)area;
    (void)bytes;
    lv_display_flush_ready(d);
}

int main(void) {
    lv_init();
    lv_tick_set_cb(tick);
    lv_display_t *d = lv_display_create(800, 600);
    lv_display_set_color_format(d, LV_COLOR_FORMAT_XRGB8888);
    lv_display_set_flush_cb(d, flush);
    lv_obj_t *root = lv_display_get_screen_active(d);
    lv_obj_remove_style_all(root);
    lv_obj_set_style_bg_opa(root, LV_OPA_COVER, 0);
    lv_obj_t *block = lv_obj_create(root);
    lv_obj_remove_style_all(block);
    lv_obj_set_size(block, 64, 64);
    lv_obj_center(block);
    lv_obj_set_style_bg_opa(block, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(block, lv_color_hex(0xe67e28), 0);

    resize_open("resize-lvgl");
    int w, h;
    uint32_t *pixels;
    while ((pixels = resize_next(&w, &h))) {
        lv_display_set_resolution(d, w, h);
        lv_display_set_buffers(d, pixels, NULL, (size_t)w * h * 4, LV_DISPLAY_RENDER_MODE_FULL);
        lv_obj_set_style_bg_color(root, lv_color_hex(w % 4 == 0 ? 0x223344 : 0x516273), 0);
        lv_obj_invalidate(root);
        lv_refr_now(d);
        resize_present();
    }
}
