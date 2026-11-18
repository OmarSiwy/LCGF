// Nuklear positions the block inside a full-window panel and emits the scissor
// and filled-rectangle commands consumed by the same presenter as the other C backends.
#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_IMPLEMENTATION
#include "nuklear.h"
#include "window.h"
#include <stdlib.h>

static float no_text(nk_handle handle, float height, const char *s, int n) {
    (void)handle; (void)height; (void)s; (void)n;
    return 0;
}

int main(void) {
    struct nk_context ui;
    struct nk_user_font font = {.height = 14, .width = no_text};
    if (!nk_init_default(&ui, &font)) return 1;
    ui.style.window.padding = ui.style.window.spacing = nk_vec2(0, 0);
    resize_open("resize-nuklear");
    int w, h;
    while (resize_next(&w, &h)) {
        nk_input_begin(&ui);
        nk_input_end(&ui);
        struct nk_color bg = w % 4 == 0 ? nk_rgb(34, 51, 68) : nk_rgb(81, 98, 115);
        ui.style.window.fixed_background = nk_style_item_color(bg);
        if (nk_begin(&ui, "scene", nk_rect(0, 0, w, h), NK_WINDOW_NO_SCROLLBAR)) {
            struct nk_rect area = nk_window_get_content_region(&ui), r;
            nk_layout_space_begin(&ui, NK_STATIC, area.h, 1);
            nk_layout_space_push(&ui, nk_rect((area.w - 64) / 2, (area.h - 64) / 2, 64, 64));
            if (nk_widget(&r, &ui) != NK_WIDGET_INVALID)
                nk_fill_rect(nk_window_get_canvas(&ui), r, 0, nk_rgb(230, 126, 40));
            nk_layout_space_end(&ui);
        }
        nk_end(&ui);
        resize_clip(0, 0, w, h);
        const struct nk_command *cmd;
        nk_foreach(cmd, &ui) {
            if (cmd->type == NK_COMMAND_SCISSOR) {
                const struct nk_command_scissor *s = (const struct nk_command_scissor *)cmd;
                resize_clip(s->x, s->y, s->w, s->h);
            } else if (cmd->type == NK_COMMAND_RECT_FILLED) {
                const struct nk_command_rect_filled *r = (const struct nk_command_rect_filled *)cmd;
                struct nk_color c = r->color;
                resize_rect(r->x, r->y, r->w, r->h, (uint32_t)c.r << 16 | (uint32_t)c.g << 8 | c.b);
            } else if (cmd->type != NK_COMMAND_NOP) {
                abort();
            }
        }
        nk_clear(&ui);
        resize_present();
    }
    nk_free(&ui);
}
