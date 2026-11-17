// Shared driver for the C and C++ comparison harnesses (bench/vs/clay, imgui, lvgl). It mirrors
// tools/bench/bench.zig so the numbers line up: the same six scenes of bench/scenes/ by name, the
// same input per frame, 3,000 frames timed on the monotonic clock, median and p99 in microseconds,
// and `--idle` prints a "ready" line after one frame for tools/bench/probe.py.
//
//   harness --scene NAME     time NAME's frames
//   harness --idle           build one frame of the idle scene, print "ready", then idle until
//                            stdin closes (how depends on the framework: vs_idle)
//
// A harness defines vs_frame (build, lay out and emit one frame of a scene) and vs_idle.
#ifndef VS_HARNESS_H
#define VS_HARNESS_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { VS_FRAMES = 3000 };
enum VsScene { VS_FORM, VS_LIST, VS_TEXT, VS_SPRINGS, VS_RESIZE, VS_IDLE, VS_SCENES };
static const char *const vs_scene_names[VS_SCENES] = {"form", "list", "text", "springs", "resize", "idle"};

// The input bench/scenes/ gives frame k: viewport, pointer, and the list scroll and spring tick.
typedef struct {
    float w, h, px, py, dt;
    uint32_t scroll, tick;
} VsInput;

static VsInput vs_input(int scene, uint32_t k) {
    VsInput in = {800, 600, 0, 0, 1.0f / 60.0f, 0, k};
    switch (scene) {
    case VS_FORM:
        in.px = (float)(20 + (k * 7) % 760), in.py = (float)(20 + (k * 13) % 560);
        break;
    case VS_LIST:
        in.w = 1280, in.h = 800, in.px = 640, in.py = (float)(10 + (k * 13) % 780);
        in.scroll = (k * 997) % (100000u * 24u - 800u);
        break;
    case VS_TEXT:
        in.w = 1280, in.h = 800;
        in.px = (float)(20 + (k * 7) % 1240), in.py = (float)(20 + (k * 13) % 760);
        break;
    case VS_SPRINGS:
        in.w = 1280, in.h = 800;
        break;
    case VS_RESIZE:
        in.w = (float)(320 + (k * 37) % 1600), in.h = (float)(240 + (k * 53) % 1000);
        in.px = 100, in.py = 100;
        break;
    case VS_IDLE:
        in.px = 400, in.py = 300;
        break;
    }
    return in;
}

// Capacity per scene, for every harness that sizes its tables (Clay's max element count, LCGF's
// node limit): LCGF's node count of the scene rounded up to a power of two, at least 256. An
// application sizes its tables for its own UI; one fixed number would favour whichever library
// touches less of an unused capacity.
static const uint32_t vs_capacity[VS_SCENES] = {256, 256, 256, 2048, 256, 256};

// Scene text shared by every harness (bench/scenes/form.zig and text.zig).
static const char *const vs_form_names[21] = {
    "Name", "Email", "Phone", "Street", "City", "Postcode", "Country", "Company", "Title", "Team", "Manager",
    "Website", "Timezone", "Language", "Currency", "Theme", "Font", "Density", "Backup", "Sync", "Alerts",
};
static const char *const vs_list_names[7] = {"alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf"};
static const char *const vs_prose[4] = {
    "Columns of rows replace trees of objects: every pass walks a few dense arrays from start to end, so the cache sees one stream per field and the vector units take eight rows at a time.",
    "A frame is rebuilt from scratch, laid out in a handful of passes and painted into a draw list that a renderer submits as it is. Nothing outlives the frame except what the caller keeps.",
    "Text is measured once per run and wrapped against the width the layout grants; lines break at spaces, and a word wider than the line is broken where it overflows.",
    "Idle costs nothing: when no input arrives and no spring moves, no frame is built, so the process sleeps until the next event and the battery is left alone.",
};

// The springs scene's 1,000 springs, stepped as prototype/ui.zig `Anims.step` does (semi-implicit
// Euler, stiffness 170, damping 26, dt capped at 1/30) for frameworks without an animation API.
typedef struct {
    float x[1000], v[1000];
    int started;
} VsSprings;

static float vs_spring_target(uint32_t tick, uint32_t i) { return ((tick / 30 + i) % 2) ? 40.0f : 4.0f; }

static void vs_springs_step(VsSprings *s, uint32_t tick, float dt) {
    float h = dt < 1.0f / 30.0f ? dt : 1.0f / 30.0f;
    for (uint32_t i = 0; i < 1000; i++) {
        float t = vs_spring_target(tick, i);
        if (!s->started) s->x[i] = t, s->v[i] = 0;
        float acc = 170.0f * (t - s->x[i]) - 26.0f * s->v[i];
        s->v[i] += acc * h;
        s->x[i] += s->v[i] * h;
    }
    s->started = 1;
}

static uint64_t vs_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static int vs_cmp(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

// Builds frame k of `scene`; returns a count of what it emitted (draw commands or vertices), so
// the work cannot be optimised away and the reader sees the output size.
static uint64_t vs_frame(int scene, uint32_t k);
// Idles as the framework's host loop would, until stdin closes.
static void vs_idle(void);

// The framework's name and version, printed in the header line.
static int vs_main(int argc, char **argv, const char *framework) {
    int scene = VS_FORM, idle = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--idle")) {
            idle = 1, scene = VS_IDLE;
        } else if (!strcmp(argv[i], "--scene") && i + 1 < argc) {
            const char *name = argv[++i];
            for (scene = 0; scene < VS_SCENES && strcmp(vs_scene_names[scene], name); scene++) {}
            if (scene == VS_SCENES) return fprintf(stderr, "unknown scene %s\n", name), 2;
        } else return fprintf(stderr, "usage: %s [--scene NAME] [--idle]\n", argv[0]), 2;
    }
    if (idle) {
        uint64_t out = vs_frame(scene, 0);
        printf("ready framework=%s out=%llu\n", framework, (unsigned long long)out);
        fflush(stdout);
        vs_idle();
        return 0;
    }
    static uint64_t samples[VS_FRAMES];
    uint64_t sink = 0, out = 0, built = 0;
    for (uint32_t k = 0; k < VS_FRAMES; k++) {
        uint64_t t0 = vs_now();
        out = vs_frame(scene, k);
        samples[k] = vs_now() - t0;
        sink += out;
        built += out != 0;
    }
    qsort(samples, VS_FRAMES, sizeof samples[0], vs_cmp);
    // frames= counts the polls that emitted something (all of them, unless the framework skips
    // unchanged frames itself); the timings cover every poll.
    printf("framework=%s scene=%s frames=%llu polls=%d out=%llu sink=%llu\n", framework, vs_scene_names[scene],
           (unsigned long long)built, VS_FRAMES, (unsigned long long)out, (unsigned long long)sink);
    printf("%-10s %9s %9s\n", "pass", "median us", "p99 us");
    printf("%-10s %9.1f %9.1f\n", "frame", samples[VS_FRAMES / 2] / 1000.0, samples[VS_FRAMES * 99 / 100] / 1000.0);
    return 0;
}

// Blocks on stdin until it closes: the host loop of a library that has no event loop of its own,
// as tools/bench/bench.zig --idle does.
static void vs_block_on_stdin(void) {
    char byte;
    while (read(0, &byte, 1) > 0) {}
}

#ifdef __cplusplus
}
#endif
#endif
