#include "window.h"
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <cairo.h>
#include <stdio.h>
#include <stdlib.h>

static Display *display;
static Window window;
static XImage *image;
static cairo_t *paint;
static int width = 800, height = 600;
static Atom close_window;

static void fail(const char *reason) {
    fprintf(stderr, "resize benchmark: %s\n", reason);
    exit(1);
}

void resize_open(const char *title) {
    display = XOpenDisplay(NULL);
    if (!display) fail("cannot connect to DISPLAY");
    int screen = DefaultScreen(display);
    Visual *v = DefaultVisual(display, screen);
    if (DefaultDepth(display, screen) != 24 || v->red_mask != 0xff0000 ||
        v->green_mask != 0xff00 || v->blue_mask != 0xff)
        fail("expected a 24-bit TrueColor X11 screen");
    window = XCreateSimpleWindow(display, RootWindow(display, screen), 0, 0, width, height, 0, 0, 0);
    close_window = XInternAtom(display, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(display, window, &close_window, 1);
    XStoreName(display, window, title);
    XSelectInput(display, window, ExposureMask | StructureNotifyMask);
    XMapWindow(display, window);
}

uint32_t *resize_next(int *w, int *h) {
    int redraw = 0;
    do {
        XEvent event;
        XNextEvent(display, &event);
        if (event.type == DestroyNotify || (event.type == ClientMessage &&
            (Atom)event.xclient.data.l[0] == close_window)) return NULL;
        if (event.type == ConfigureNotify) {
            width = event.xconfigure.width;
            height = event.xconfigure.height;
            redraw = 1;
        }
        if (event.type == Expose) redraw = 1;
    } while (!redraw || XPending(display));

    if (!image || image->width != width || image->height != height) {
        if (paint) cairo_destroy(paint);
        if (image) XDestroyImage(image);
        int screen = DefaultScreen(display);
        image = XCreateImage(display, DefaultVisual(display, screen), 24, ZPixmap, 0,
                             NULL, width, height, 32, 0);
        if (!image || image->bits_per_pixel != 32 || image->bytes_per_line != width * 4)
            fail("expected a 32-bit packed XImage");
        image->data = calloc((size_t)height, image->bytes_per_line);
        if (!image->data) fail("cannot allocate XImage");
        cairo_surface_t *surface = cairo_image_surface_create_for_data((unsigned char *)image->data,
            CAIRO_FORMAT_RGB24, width, height, image->bytes_per_line);
        paint = cairo_create(surface);
        cairo_surface_destroy(surface);
        if (cairo_status(paint) != CAIRO_STATUS_SUCCESS) fail(cairo_status_to_string(cairo_status(paint)));
        cairo_set_antialias(paint, CAIRO_ANTIALIAS_NONE);
    }
    *w = width;
    *h = height;
    return (uint32_t *)image->data;
}

void resize_present(void) {
    cairo_surface_flush(cairo_get_target(paint));
    XPutImage(display, window, DefaultGC(display, DefaultScreen(display)),
              image, 0, 0, 0, 0, width, height);
    XFlush(display);
}

static void source(uint32_t rgb) {
    cairo_set_source_rgb(paint, ((rgb >> 16) & 255) / 255.0,
                         ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0);
}

void resize_clip(int x, int y, int w, int h) {
    cairo_reset_clip(paint);
    cairo_rectangle(paint, x, y, w, h);
    cairo_clip(paint);
}

void resize_rect(float x, float y, float w, float h, uint32_t rgb) {
    source(rgb);
    cairo_rectangle(paint, x, y, w, h);
    cairo_fill(paint);
}

void resize_tri(float ax, float ay, float bx, float by, float cx, float cy, uint32_t rgb) {
    source(rgb);
    cairo_move_to(paint, ax, ay);
    cairo_line_to(paint, bx, by);
    cairo_line_to(paint, cx, cy);
    cairo_close_path(paint);
    cairo_fill(paint);
}
