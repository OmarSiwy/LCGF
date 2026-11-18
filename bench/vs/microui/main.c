// microui 2.02 supplies layout, controls, clipping, word wrapping and the command list.
// Its renderer supplies text metrics. Use the comparison's monospace advance.
#include "microui.h"
#include "../harness.h"

static mu_Context ui;
static int body_px = 14, title_px = 20;
static char fields[21][32];
static int checked[21];
static mu_Real values[21];
static VsSprings motion;

static int text_width(mu_Font font, const char *text, int length) {
    if (length < 0) length = (int)strlen(text);
    return (length * *(const int *)font * 3 + 2) / 5;
}

static int text_height(mu_Font font) { return *(const int *)font; }

static void form(void) {
    const int full = -1, columns[] = {90, 220, 65, -1}, footer[] = {-230, 68, 68, 68};
    ui.style->font = &title_px;
    mu_layout_row(&ui, 1, &full, 22);
    mu_label(&ui, "Account settings");
    ui.style->font = &body_px;
    mu_layout_row(&ui, 1, &full, 1);
    mu_draw_rect(&ui, mu_layout_next(&ui), mu_color(58, 60, 70, 255));
    for (int i = 0; i < 21; ++i) {
        mu_layout_row(&ui, 4, columns, 20);
        mu_label(&ui, vs_form_names[i]);
        mu_textbox(&ui, fields[i], sizeof(fields[i]));
        mu_checkbox(&ui, "On", &checked[i]);
        mu_slider(&ui, &values[i], 0, 1);
    }
    mu_layout_row(&ui, 4, footer, 22);
    (void)mu_layout_next(&ui);
    mu_button(&ui, "Cancel");
    mu_button(&ui, "Reset");
    mu_button(&ui, "Save");
}

static void list(VsInput in) {
    const int full = -1, first = (int)in.scroll / 24;
    const int count = (int)in.h / 24 + 2;
    const int end = first + count < 100000 ? first + count : 100000;
    if (first) {
        mu_layout_row(&ui, 1, &full, first * 24);
        (void)mu_layout_next(&ui);
    }
    mu_layout_row(&ui, 1, &full, 24);
    for (int i = first; i < end; ++i) {
        mu_Rect row = mu_layout_next(&ui);
        mu_draw_rect(&ui, row, i % 2 ? mu_color(58, 60, 70, 255) : mu_color(30, 31, 36, 255));
        char label[16];
        snprintf(label, sizeof(label), "Row %d", i);
        const char *name = vs_list_names[i % 7];
        int x = row.x + 8;
        int w = text_width(ui.style->font, label, -1);
        mu_draw_control_text(&ui, label, mu_rect(x, row.y, w, row.h), MU_COLOR_TEXT, 0);
        x += w + 6;
        w = text_width(ui.style->font, name, -1);
        mu_draw_control_text(&ui, name, mu_rect(x, row.y, w, row.h), MU_COLOR_TEXT, 0);
        mu_draw_rect(&ui, mu_rect(x + w + 6, row.y + 6, 12, 12), mu_color(90, 140, 255, 255));
    }
    if (end < 100000) {
        mu_layout_row(&ui, 1, &full, (100000 - end) * 24);
        (void)mu_layout_next(&ui);
    }
}

static void prose(void) {
    const int columns[] = {160, -1}, full = -1;
    mu_layout_row(&ui, 2, columns, -1);
    mu_begin_panel_ex(&ui, "chapters", MU_OPT_NOFRAME | MU_OPT_NOSCROLL);
    mu_layout_row(&ui, 1, &full, body_px);
    char label[24];
    for (int i = 1; i <= 120; ++i) {
        snprintf(label, sizeof(label), "Chapter %d", i);
        mu_label(&ui, label);
    }
    mu_end_panel(&ui);
    mu_begin_panel_ex(&ui, "body", MU_OPT_NOFRAME | MU_OPT_NOSCROLL);
    for (int s = 0; s < 12; ++s) {
        ui.style->font = &title_px;
        mu_layout_row(&ui, 1, &full, title_px);
        snprintf(label, sizeof(label), "Section %d", s + 1);
        mu_label(&ui, label);
        ui.style->font = &body_px;
        mu_layout_row(&ui, 1, &full, body_px);
        for (int p = 0; p < 4; ++p) mu_text(&ui, vs_prose[(s + p) % 4]);
    }
    mu_end_panel(&ui);
}

static void springs(VsInput in) {
    vs_springs_step(&motion, in.tick, in.dt);
    for (int r = 0; r < 40; ++r) {
        // Zero columns selects explicit per-item width without the fixed width-array limit.
        mu_layout_row(&ui, 0, NULL, 16);
        for (int c = 0; c < 25; ++c) {
            mu_layout_width(&ui, (int)(motion.x[r * 25 + c] + 0.5f));
            mu_draw_rect(&ui, mu_layout_next(&ui), mu_color(90, 140, 255, 255));
        }
    }
}

static uint64_t vs_frame(int scene, uint32_t k) {
    VsInput in = vs_input(scene, k);
    mu_input_mousemove(&ui, (int)in.px, (int)in.py);
    mu_begin(&ui);
    mu_Container *window = mu_get_container(&ui, "scene");
    window->rect = mu_rect(0, 0, (int)in.w, (int)in.h);
    window->scroll = mu_vec2(0, scene == VS_LIST ? (int)in.scroll : 0);
    ui.style->padding = scene == VS_LIST ? 0 : (scene == VS_SPRINGS ? 8 : 12);
    ui.style->spacing = scene == VS_LIST ? 0 : (scene == VS_SPRINGS ? 2 : 4);
    if (mu_begin_window_ex(&ui, "scene", window->rect, MU_OPT_NOTITLE | MU_OPT_NORESIZE | MU_OPT_NOSCROLL)) {
        switch (scene) {
        case VS_FORM: case VS_IDLE: form(); break;
        case VS_LIST: list(in); break;
        case VS_TEXT: case VS_RESIZE: prose(); break;
        case VS_SPRINGS: springs(in); break;
        }
        mu_end_window(&ui);
    }
    mu_end(&ui);
    mu_Command *command = NULL;
    uint64_t count = 0;
    while (mu_next_command(&ui, &command)) ++count;
    return count;
}

static void vs_idle(void) { vs_block_on_stdin(); }

int main(int argc, char **argv) {
    mu_init(&ui);
    ui.text_width = text_width;
    ui.text_height = text_height;
    ui.style->font = &body_px;
    for (int i = 0; i < 21; ++i) {
        snprintf(fields[i], sizeof(fields[i]), "%s", vs_form_names[i]);
        values[i] = 0.5f;
    }
    return vs_main(argc, argv, "microui-" MU_VERSION);
}
