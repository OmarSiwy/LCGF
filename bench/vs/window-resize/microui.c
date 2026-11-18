// Paint the actual microui rectangle commands from a full-window container.
#include "microui.h"
#include "window.h"
#include <stdlib.h>

static mu_Context ui;
static int text_width(mu_Font font, const char *s, int len) { (void)font; (void)s; (void)len; return 0; }
static int text_height(mu_Font font) { (void)font; return 14; }

int main(void) {
    mu_init(&ui);
    ui.text_width = text_width;
    ui.text_height = text_height;
    ui.style->padding = ui.style->spacing = 0;
    ui.style->colors[MU_COLOR_BORDER].a = 0;
    resize_open("resize-microui");
    int w, h;
    while (resize_next(&w, &h)) {
        mu_begin(&ui);
        mu_Container *window = mu_get_container(&ui, "scene");
        window->rect = mu_rect(0, 0, w, h);
        ui.style->colors[MU_COLOR_WINDOWBG] = w % 4 == 0 ? mu_color(34, 51, 68, 255) : mu_color(81, 98, 115, 255);
        if (mu_begin_window_ex(&ui, "scene", window->rect, MU_OPT_NOTITLE | MU_OPT_NOSCROLL | MU_OPT_NORESIZE)) {
            mu_Rect body = mu_get_current_container(&ui)->body;
            mu_layout_set_next(&ui, mu_rect((body.w - 64) / 2, (body.h - 64) / 2, 64, 64), 1);
            mu_draw_rect(&ui, mu_layout_next(&ui), mu_color(230, 126, 40, 255));
            mu_end_window(&ui);
        }
        mu_end(&ui);
        mu_Command *command = NULL;
        while (mu_next_command(&ui, &command)) {
            if (command->type != MU_COMMAND_RECT) abort();
            mu_Rect r = command->rect.rect;
            mu_Color c = command->rect.color;
            resize_rect(r.x, r.y, r.w, r.h, (uint32_t)c.r << 16 | (uint32_t)c.g << 8 | c.b);
        }
        resize_present();
    }
}
