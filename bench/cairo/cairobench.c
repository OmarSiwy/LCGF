/* The frames of tools/bench/swbench.zig drawn with Cairo's image surface, timed the same way:
 * clear, then every command, median and p90 over the frames. Read the dumps it writes:
 *
 *     zig build swbench -- --dump zig-out/swdump
 *     cc -O2 bench/cairo/cairobench.c $(pkg-config --cflags --libs cairo) -o zig-out/cairobench
 *     zig-out/cairobench zig-out/swdump/<scene> [frames]
 *
 * Quads become Cairo paths as a toolkit would draw them: a rectangle, or four arcs for rounded
 * corners; a border is the even-odd ring between the outer and the inset shape; the quad's clip
 * is set when it changes. Glyph runs go through cairo_show_glyphs with a 14 px FreeType face at
 * the glyph quads' positions: Cairo's own text path, glyph cache and A8 mask compositing.
 * Default antialiasing everywhere (the window-resize hosts turn it off; this bench must not). */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#include <cairo.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* src/draw/draw_list.zig Quad, 136 bytes. */
typedef struct {
    float rect[4], clip[4], params[4], uv[4], radii[4];
    uint32_t fill, border_color;
    float border, opacity, xform[6], clip_radii[4];
} Quad;

typedef struct { int kind; uint32_t first, count; } Cmd;

static void *slurp(const char *dir, const char *name, size_t *len) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) { *len = 0; return NULL; }
    fseek(f, 0, SEEK_END);
    *len = (size_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    void *p = malloc(*len + 1);
    if (fread(p, 1, *len, f) != *len) { fclose(f); free(p); *len = 0; return NULL; }
    fclose(f);
    ((char *)p)[*len] = 0;
    return p;
}

static uint64_t now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static int cmp(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

/* Colour words are r | g << 8 | b << 16 | a << 24, straight alpha. */
static void source(cairo_t *cr, uint32_t c, float opacity) {
    cairo_set_source_rgba(cr, (c & 255) / 255.0, (c >> 8 & 255) / 255.0, (c >> 16 & 255) / 255.0,
                          (c >> 24 & 255) / 255.0 * opacity);
}

/* Radii: top-left, top-right, bottom-right, bottom-left. */
static void shape(cairo_t *cr, double x0, double y0, double x1, double y1, const float *r) {
    if (r[0] <= 0 && r[1] <= 0 && r[2] <= 0 && r[3] <= 0) {
        cairo_rectangle(cr, x0, y0, x1 - x0, y1 - y0);
        return;
    }
    cairo_new_sub_path(cr);
    cairo_arc(cr, x1 - r[1], y0 + r[1], r[1], -M_PI / 2, 0);
    cairo_arc(cr, x1 - r[2], y1 - r[2], r[2], 0, M_PI / 2);
    cairo_arc(cr, x0 + r[3], y1 - r[3], r[3], M_PI / 2, M_PI);
    cairo_arc(cr, x0 + r[0], y0 + r[0], r[0], M_PI, 3 * M_PI / 2);
    cairo_close_path(cr);
}

typedef struct { float clip[4]; int set; } ClipState;

static void clip_to(cairo_t *cr, ClipState *st, const float *c) {
    if (st->set && memcmp(st->clip, c, sizeof st->clip) == 0) return;
    cairo_reset_clip(cr);
    cairo_rectangle(cr, c[0], c[1], c[2] - c[0], c[3] - c[1]);
    cairo_clip(cr);
    memcpy(st->clip, c, sizeof st->clip);
    st->set = 1;
}

static void quad(cairo_t *cr, ClipState *st, const Quad *q) {
    clip_to(cr, st, q->clip);
    const float *r = q->rect;
    if (q->fill >> 24) {
        source(cr, q->fill, q->opacity);
        shape(cr, r[0], r[1], r[2], r[3], q->radii);
        cairo_fill(cr);
    }
    if (q->border > 0 && q->border_color >> 24) {
        float b = q->border, in[4];
        for (int k = 0; k < 4; k++) in[k] = fmaxf(q->radii[k] - b, 0);
        source(cr, q->border_color, q->opacity);
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
        shape(cr, r[0], r[1], r[2], r[3], q->radii);
        shape(cr, r[0] + b, r[1] + b, r[2] - b, r[3] - b, in);
        cairo_fill(cr);
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: cairobench DIR [frames]\n"); return 2; }
    const char *dir = argv[1];
    int frames = argc > 2 ? atoi(argv[2]) : 60;
    size_t ql, gl, tl;
    Quad *quads = slurp(dir, "quads.bin", &ql);
    Quad *glyphs = slurp(dir, "glyphs.bin", &gl);
    char *text = slurp(dir, "cmds.txt", &tl);
    if (!text) { fprintf(stderr, "no cmds.txt in %s\n", dir); return 1; }
    int w = 800, h = 600;
    Cmd *cmds = calloc(tl / 6 + 1, sizeof *cmds);
    int n = 0;
    for (char *line = strtok(text, "\n"); line; line = strtok(NULL, "\n")) {
        unsigned a = 0, b = 0;
        if (sscanf(line, "size %d %d", &w, &h) == 2) continue;
        if (sscanf(line, "quads %u %u", &a, &b) == 2) cmds[n++] = (Cmd){0, a, b};
        else if (sscanf(line, "text %u %u", &a, &b) == 2) cmds[n++] = (Cmd){1, a, b};
    }

    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t *cr = cairo_create(s);
    cairo_select_font_face(cr, "DejaVu Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 14);
    cairo_scaled_font_t *sf = cairo_get_scaled_font(cr);
    unsigned long index[256] = {0};
    for (int byte = 32; byte < 127; byte++) {
        char str[2] = {(char)byte, 0};
        cairo_glyph_t *g = NULL;
        int ng = 0;
        if (cairo_scaled_font_text_to_glyphs(sf, 0, 0, str, 1, &g, &ng, NULL, NULL, NULL) == CAIRO_STATUS_SUCCESS && ng > 0)
            index[byte] = g[0].index;
        cairo_glyph_free(g);
    }
    /* Each glyph quad becomes a glyph at its cell's baseline; its byte is recovered from its uv. */
    size_t glyph_n = gl / sizeof(Quad);
    cairo_glyph_t *run = malloc((glyph_n + 1) * sizeof *run);
    for (size_t i = 0; i < glyph_n; i++) {
        const Quad *q = &glyphs[i];
        int byte = (int)lroundf(q->uv[1] * 16) * 16 + (int)lroundf(q->uv[0] * 16);
        run[i] = (cairo_glyph_t){index[byte & 255], q->rect[0], q->rect[1] + (q->rect[3] - q->rect[1]) * 0.75};
    }

    uint64_t *t = calloc((size_t)frames, sizeof *t);
    for (int f = 0; f < frames; f++) {
        uint64_t t0 = now();
        ClipState st = {{0}, 0};
        cairo_reset_clip(cr);
        cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
        cairo_set_source_rgb(cr, 0x0d / 255.0, 0x0d / 255.0, 0x0f / 255.0);
        cairo_paint(cr);
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
        for (int k = 0; k < n; k++) {
            if (cmds[k].kind == 0) {
                for (uint32_t i = 0; i < cmds[k].count; i++) quad(cr, &st, &quads[cmds[k].first + i]);
            } else if (cmds[k].count > 0) {
                const Quad *q = &glyphs[cmds[k].first];
                clip_to(cr, &st, q->clip);
                source(cr, q->fill, q->opacity);
                cairo_show_glyphs(cr, &run[cmds[k].first], (int)cmds[k].count);
            }
        }
        cairo_surface_flush(s);
        t[f] = now() - t0;
    }
    qsort(t, (size_t)frames, sizeof *t, cmp);
    const char *name = strrchr(dir, '/');
    printf("%-12s %4dx%-4d %8zu %9zu %9.1f %8.1f\n", name ? name + 1 : dir, w, h, ql / sizeof(Quad), glyph_n,
           t[frames / 2] / 1000.0, t[frames * 9 / 10] / 1000.0);
    if (argc > 3) cairo_surface_write_to_png(s, argv[3]);
    return 0;
}
