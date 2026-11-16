// The scenes of bench/scenes/ on Clay (https://github.com/nicbarker/clay), for the comparison of
// docs/perf/vs.md. Clay is a layout library: a frame here is Clay_BeginLayout, the element
// declarations, and Clay_EndLayout, which lays out and emits the render commands. That matches
// what tools/bench times as `frame` (build, layout, paint into a draw list); neither rasterises.
// Clay has no widgets, text measuring or animation, so the harness supplies them as a Clay user
// would: widgets built from elements as prototype/ui.zig builds them, the monospace measure of
// src/text/protocol.zig (0.6 em per byte, 1.25 em lines), and the springs of bench/vs/harness.h.
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "../harness.h"

static const Clay_Color text_c = {230, 230, 235, 255}, panel = {30, 31, 36, 255}, control = {58, 60, 70, 255},
                        control_hot = {74, 77, 90, 255}, accent = {90, 140, 255, 255};
enum { text_px = 14, pad = 8, gap = 6, radius = 4 };

static Clay_Dimensions measure(Clay_StringSlice s, Clay_TextElementConfig *c, void *user) {
    (void)user;
    return (Clay_Dimensions){(float)s.length * c->fontSize * 0.6f, c->fontSize * 1.25f};
}

static void on_error(Clay_ErrorData e) {
    fprintf(stderr, "clay: %.*s\n", (int)e.errorText.length, e.errorText.chars);
    exit(1);
}

// Strings made during a frame live until Clay_EndLayout has emitted them.
static char strings[64 * 1024];
static uint32_t strings_len;
static Clay_String fmt_int(const char *prefix, uint32_t n) {
    char *at = strings + strings_len;
    int len = snprintf(at, sizeof strings - strings_len, "%s%u", prefix, n);
    strings_len += (uint32_t)len;
    return (Clay_String){.length = len, .chars = at};
}
static Clay_String str(const char *s) { return (Clay_String){.length = (int32_t)strlen(s), .chars = s}; }

static void text(Clay_String s, uint16_t px, Clay_TextElementConfigWrapMode wrap) {
    CLAY_TEXT(s, CLAY_TEXT_CONFIG({.textColor = text_c, .fontSize = px, .wrapMode = wrap}));
}
static void label(Clay_String s) { text(s, text_px, CLAY_TEXT_WRAP_NONE); }

static void button(Clay_ElementId id, const char *s) {
    CLAY({.id = id,
          .layout = {.padding = CLAY_PADDING_ALL(pad), .childAlignment = {CLAY_ALIGN_X_CENTER, CLAY_ALIGN_Y_CENTER}},
          .cornerRadius = CLAY_CORNER_RADIUS(radius),
          .backgroundColor = Clay_Hovered() ? control_hot : control}) {
        label(str(s));
    }
}

static void checkbox(Clay_ElementId id, int value, const char *s) {
    CLAY({.id = id, .layout = {.childGap = gap, .childAlignment = {.y = CLAY_ALIGN_Y_CENTER}}}) {
        CLAY({.layout = {.sizing = {CLAY_SIZING_FIXED(16), CLAY_SIZING_FIXED(16)}},
              .cornerRadius = CLAY_CORNER_RADIUS(3),
              .backgroundColor = value ? accent : control,
              .border = {.color = control_hot, .width = CLAY_BORDER_ALL(1)}}) {}
        label(str(s));
    }
}

static void slider(Clay_ElementId id, float frac) {
    CLAY({.id = id,
          .layout = {.sizing = {CLAY_SIZING_GROW(40), CLAY_SIZING_FIXED(8)}},
          .cornerRadius = CLAY_CORNER_RADIUS(4),
          .backgroundColor = control}) {
        CLAY({.layout = {.sizing = {CLAY_SIZING_PERCENT(frac), CLAY_SIZING_GROW(0)}},
              .cornerRadius = CLAY_CORNER_RADIUS(4),
              .backgroundColor = accent}) {}
    }
}

static void form(void) {
    static const Clay_String form_id = CLAY_STRING_CONST("form");
    CLAY({.id = CLAY_SIDI(form_id, 0),
          .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}, .padding = CLAY_PADDING_ALL(12), .childGap = 4, .layoutDirection = CLAY_TOP_TO_BOTTOM},
          .backgroundColor = panel}) {
        text(CLAY_STRING("Account settings"), 20, CLAY_TEXT_WRAP_NONE);
        CLAY({.layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(1)}}, .backgroundColor = control_hot}) {}
        for (uint32_t r = 0; r < 21; r++) {
            uint32_t id = 1 + r * 4;
            CLAY({.id = CLAY_SIDI(form_id, id), .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIT(0)}, .childGap = gap, .childAlignment = {.y = CLAY_ALIGN_Y_CENTER}}}) {
                CLAY({.layout = {.sizing = {CLAY_SIZING_FIXED(90), CLAY_SIZING_FIT(0)}}}) { label(str(vs_form_names[r])); }
                CLAY({.id = CLAY_SIDI(form_id, id + 1),
                      .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIT(0)}, .padding = CLAY_PADDING_ALL(4)},
                      .cornerRadius = CLAY_CORNER_RADIUS(radius),
                      .backgroundColor = control,
                      .border = {.color = control_hot, .width = CLAY_BORDER_ALL(1)}}) {
                    label(str(vs_form_names[r]));
                }
                checkbox(CLAY_SIDI(form_id, id + 2), 0, "On");
                slider(CLAY_SIDI(form_id, id + 3), 0.5f);
            }
        }
        CLAY({.id = CLAY_SIDI(form_id, 1000), .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIT(0)}, .childGap = gap, .childAlignment = {.x = CLAY_ALIGN_X_RIGHT}}}) {
            button(CLAY_SIDI(form_id, 1001), "Cancel");
            button(CLAY_SIDI(form_id, 1002), "Reset");
            button(CLAY_SIDI(form_id, 1003), "Save");
        }
    }
}

static void list(uint32_t scroll) {
    enum { total = 100000, row_h = 24, visible = 800 / row_h + 2 };
    uint32_t first = scroll / row_h, end = first + visible < total ? first + visible : total;
    CLAY({.id = CLAY_ID("list"),
          .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}, .layoutDirection = CLAY_TOP_TO_BOTTOM},
          .clip = {.vertical = true, .childOffset = {0, -(float)scroll}}}) {
        CLAY({.layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED((float)first * row_h)}}}) {}
        for (uint32_t r = first; r < end; r++) {
            CLAY({.layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(row_h)}, .padding = {8, 8, 0, 0}, .childGap = gap, .childAlignment = {.y = CLAY_ALIGN_Y_CENTER}},
                  .backgroundColor = r % 2 ? control : panel}) {
                label(fmt_int("Row ", r));
                label(str(vs_list_names[r % 7]));
                CLAY({.layout = {.sizing = {CLAY_SIZING_FIXED(12), CLAY_SIZING_FIXED(12)}}, .backgroundColor = accent}) {}
            }
        }
        CLAY({.layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED((float)(total - end) * row_h)}}}) {}
    }
}

static void prose(void) {
    CLAY({.id = CLAY_ID("text"),
          .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}, .padding = CLAY_PADDING_ALL(12), .childGap = 16},
          .clip = {.horizontal = true, .vertical = true}}) {
        CLAY({.layout = {.sizing = {CLAY_SIZING_FIXED(160), CLAY_SIZING_GROW(0)}, .childGap = 2, .layoutDirection = CLAY_TOP_TO_BOTTOM}}) {
            for (uint32_t i = 0; i < 120; i++) label(fmt_int("Chapter ", i + 1));
        }
        CLAY({.layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIT(0)}, .childGap = 8, .layoutDirection = CLAY_TOP_TO_BOTTOM}}) {
            for (uint32_t s = 0; s < 12; s++) {
                text(fmt_int("Section ", s + 1), 20, CLAY_TEXT_WRAP_NONE);
                for (uint32_t p = 0; p < 4; p++) text(str(vs_prose[(s + p) % 4]), text_px, CLAY_TEXT_WRAP_WORDS);
            }
        }
    }
}

static VsSprings springs_state;
static void springs(uint32_t tick, float dt) {
    vs_springs_step(&springs_state, tick, dt);
    CLAY({.id = CLAY_ID("springs"), .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}, .padding = CLAY_PADDING_ALL(8), .childGap = 2, .layoutDirection = CLAY_TOP_TO_BOTTOM}}) {
        for (uint32_t r = 0; r < 40; r++) {
            CLAY({.layout = {.childGap = 2}}) {
                for (uint32_t c = 0; c < 25; c++) {
                    CLAY({.layout = {.sizing = {CLAY_SIZING_FIXED(springs_state.x[r * 25 + c]), CLAY_SIZING_FIXED(16)}}, .backgroundColor = accent}) {}
                }
            }
        }
    }
}

static uint64_t vs_frame(int scene, uint32_t k) {
    VsInput in = vs_input(scene, k);
    Clay_SetLayoutDimensions((Clay_Dimensions){in.w, in.h});
    Clay_SetPointerState((Clay_Vector2){in.px, in.py}, false);
    strings_len = 0;
    Clay_BeginLayout();
    switch (scene) {
    case VS_FORM:
    case VS_IDLE: form(); break;
    case VS_LIST: list(in.scroll); break;
    case VS_TEXT:
    case VS_RESIZE: prose(); break;
    case VS_SPRINGS: springs(in.tick, in.dt); break;
    }
    Clay_RenderCommandArray cmds = Clay_EndLayout();
    return (uint64_t)cmds.length;
}

// Clay has no event loop: the host sleeps until input arrives, as tools/bench does.
static void vs_idle(void) { vs_block_on_stdin(); }

int main(int argc, char **argv) {
    uint32_t bytes = Clay_MinMemorySize();
    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(bytes, malloc(bytes));
    Clay_Initialize(arena, (Clay_Dimensions){800, 600}, (Clay_ErrorHandler){on_error, 0});
    Clay_SetMeasureTextFunction(measure, 0);
    return vs_main(argc, argv, "clay-0.14");
}
