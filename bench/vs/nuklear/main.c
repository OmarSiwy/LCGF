// Nuklear emits its native command stream with a host-supplied monospace font.
// Each measured frame finishes by walking those commands, before rasterization.
#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_IMPLEMENTATION
#include "nuklear.h"
#include "../harness.h"

static struct nk_context ui;
static struct nk_user_font body, title;
static char fields[21][32];
static nk_bool checked[21];
static float values[21];
static VsSprings motion;

static float text_width(nk_handle handle, float height, const char *text, int bytes) {
    (void)handle;
    (void)text;
    return bytes * height * 0.6f;
}

static void box(struct nk_color color) {
    struct nk_rect r;
    if (nk_widget(&r, &ui) != NK_WIDGET_INVALID)
        nk_fill_rect(nk_window_get_canvas(&ui), r, 0, color);
}

static void form(void) {
    nk_style_set_font(&ui, &title);
    nk_layout_row_dynamic(&ui, 22, 1);
    nk_label(&ui, "Account settings", NK_TEXT_LEFT);
    nk_style_set_font(&ui, &body);
    nk_layout_row_dynamic(&ui, 1, 1);
    box(nk_rgb(58, 60, 70));
    for (int i = 0; i < 21; ++i) {
        nk_layout_row_template_begin(&ui, 20);
        nk_layout_row_template_push_static(&ui, 90);
        nk_layout_row_template_push_static(&ui, 220);
        nk_layout_row_template_push_static(&ui, 65);
        nk_layout_row_template_push_dynamic(&ui);
        nk_layout_row_template_end(&ui);
        nk_label(&ui, vs_form_names[i], NK_TEXT_LEFT);
        nk_edit_string_zero_terminated(&ui, NK_EDIT_FIELD, fields[i], sizeof(fields[i]), nk_filter_default);
        nk_checkbox_label(&ui, "On", &checked[i]);
        nk_slider_float(&ui, 0, &values[i], 1, 0.01f);
    }
    nk_layout_row_template_begin(&ui, 22);
    nk_layout_row_template_push_dynamic(&ui);
    for (int i = 0; i < 3; ++i) nk_layout_row_template_push_static(&ui, 68);
    nk_layout_row_template_end(&ui);
    nk_spacer(&ui);
    nk_button_label(&ui, "Cancel");
    nk_button_label(&ui, "Reset");
    nk_button_label(&ui, "Save");
}

static void list(VsInput in) {
    const int first = (int)in.scroll / 24, maximum = 100000;
    const int count = (int)in.h / 24 + 2;
    const int end = first + count < maximum ? first + count : maximum;
    // Windowed layout for the 100,000 fixed-height rows. Keep the fractional
    // leading row so a 997-pixel scroll moves the layout by exactly 997 pixels.
    nk_layout_space_begin(&ui, NK_STATIC, in.h, 4 * (end - first));
    for (int i = first; i < end; ++i) {
        const float y = (float)(i * 24) - in.scroll;
        nk_layout_space_push(&ui, nk_rect(0, y, in.w, 24));
        box(i % 2 ? nk_rgb(58, 60, 70) : nk_rgb(30, 31, 36));
        char label[16];
        int n = snprintf(label, sizeof(label), "Row %d", i);
        const char *name = vs_list_names[i % 7];
        float x = 8, w = body.width(body.userdata, body.height, label, n);
        nk_layout_space_push(&ui, nk_rect(x, y, w, 24));
        nk_label(&ui, label, NK_TEXT_LEFT);
        x += w + 6;
        w = body.width(body.userdata, body.height, name, (int)strlen(name));
        nk_layout_space_push(&ui, nk_rect(x, y, w, 24));
        nk_label(&ui, name, NK_TEXT_LEFT);
        nk_layout_space_push(&ui, nk_rect(x + w + 6, y + 6, 12, 12));
        box(nk_rgb(90, 140, 255));
    }
    nk_layout_space_end(&ui);
}

// Wrapped labels need an explicit widget height. Measure words with the same
// supplied font; Nuklear breaks the actual text into its draw commands.
static float paragraph_height(const char *text, float width) {
    int lines = 1;
    float used = 0;
    const float space = body.width(body.userdata, body.height, " ", 1);
    while (*text) {
        const char *word = text;
        while (*text && *text != ' ') ++text;
        const float w = body.width(body.userdata, body.height, word, (int)(text - word));
        if (used > 0 && used + space + w > width) {
            ++lines;
            used = w;
        } else {
            used += (used > 0 ? space : 0) + w;
        }
        if (*text) ++text;
    }
    return body.height * lines + 1;
}

static void prose(void) {
    const struct nk_rect region = nk_window_get_content_region(&ui);
    nk_layout_row_begin(&ui, NK_STATIC, region.h, 2);
    nk_layout_row_push(&ui, 160);
    if (nk_group_begin(&ui, "chapters", NK_WINDOW_NO_SCROLLBAR)) {
        nk_layout_row_dynamic(&ui, body.height, 1);
        char label[24];
        for (int i = 1; i <= 120; ++i) {
            snprintf(label, sizeof(label), "Chapter %d", i);
            nk_label(&ui, label, NK_TEXT_LEFT);
        }
        nk_group_end(&ui);
    }
    nk_layout_row_push(&ui, region.w - 160 - ui.style.window.spacing.x);
    if (nk_group_begin(&ui, "body", NK_WINDOW_NO_SCROLLBAR)) {
        const float width = nk_window_get_content_region(&ui).w;
        for (int s = 0; s < 12; ++s) {
            char heading[24];
            snprintf(heading, sizeof(heading), "Section %d", s + 1);
            nk_style_set_font(&ui, &title);
            nk_layout_row_dynamic(&ui, title.height, 1);
            nk_label(&ui, heading, NK_TEXT_LEFT);
            nk_style_set_font(&ui, &body);
            for (int p = 0; p < 4; ++p) {
                const char *paragraph = vs_prose[(s + p) % 4];
                nk_layout_row_dynamic(&ui, paragraph_height(paragraph, width), 1);
                nk_label_wrap(&ui, paragraph);
            }
        }
        nk_group_end(&ui);
    }
    nk_layout_row_end(&ui);
}

static void springs(VsInput in) {
    vs_springs_step(&motion, in.tick, in.dt);
    for (int r = 0; r < 40; ++r) {
        nk_layout_row_begin(&ui, NK_STATIC, 16, 25);
        for (int c = 0; c < 25; ++c) {
            nk_layout_row_push(&ui, motion.x[r * 25 + c]);
            box(nk_rgb(90, 140, 255));
        }
        nk_layout_row_end(&ui);
    }
}

static uint64_t vs_frame(int scene, uint32_t k) {
    VsInput in = vs_input(scene, k);
    nk_input_begin(&ui);
    nk_input_motion(&ui, (int)in.px, (int)in.py);
    nk_input_end(&ui);
    ui.style.window.padding = scene == VS_LIST ? nk_vec2(0, 0) :
        (scene == VS_SPRINGS ? nk_vec2(8, 8) : nk_vec2(12, 12));
    ui.style.window.spacing = scene == VS_LIST ? nk_vec2(0, 0) :
        (scene == VS_SPRINGS ? nk_vec2(2, 2) : nk_vec2(6, 4));
    if (nk_begin(&ui, "scene", nk_rect(0, 0, in.w, in.h), NK_WINDOW_NO_SCROLLBAR)) {
        switch (scene) {
        case VS_FORM: case VS_IDLE: form(); break;
        case VS_LIST: list(in); break;
        case VS_TEXT: case VS_RESIZE: prose(); break;
        case VS_SPRINGS: springs(in); break;
        }
    }
    nk_end(&ui);
    const struct nk_command *command;
    uint64_t count = 0;
    nk_foreach(command, &ui) ++count;
    nk_clear(&ui);
    return count;
}

static void vs_idle(void) { vs_block_on_stdin(); }

int main(int argc, char **argv) {
    body.height = 14;
    body.width = text_width;
    title = body;
    title.height = 20;
    if (!nk_init_default(&ui, &body)) return 1;
    ui.style.text.padding = nk_vec2(0, 0);
    ui.style.window.group_padding = nk_vec2(0, 0);
    for (int i = 0; i < 21; ++i) {
        snprintf(fields[i], sizeof(fields[i]), "%s", vs_form_names[i]);
        values[i] = 0.5f;
    }
    int status = vs_main(argc, argv, "nuklear-4.13.4");
    nk_free(&ui);
    return status;
}
