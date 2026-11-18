// Observe a single fixture on a private, 24-bit Xvfb screen. Each sample ends
// when the server completes a snapshot that matches the reference at every pixel.
#define _POSIX_C_SOURCE 200809L
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct { int w, h; } Size;
static const Size initial = {800, 600}, small = {900, 676}, large = {2514, 1420};
static const Size drag[] = {
    {1250, 900}, {1500, 1000}, {1750, 1100}, {2000, 1200}, {2250, 1300}
};
static Display *display;
static Pixmap snapshot;
static GC capture;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void pause_ns(long ns) {
    struct timespec ts = {0, ns};
    nanosleep(&ts, NULL);
}

static bool named_window(Window window, Atom property, const char *title) {
    Atom type;
    int format;
    unsigned long length, remaining;
    unsigned char *value = NULL;
    int status = XGetWindowProperty(display, window, property, 0, 64, False,
                                    AnyPropertyType, &type, &format, &length, &remaining, &value);
    bool match = status == Success && format == 8 && remaining == 0 && length == strlen(title) &&
                 memcmp(value, title, length) == 0;
    if (value) XFree(value);
    return match;
}

static Window find_client(const char *title) {
    Atom modern = XInternAtom(display, "_NET_WM_NAME", False);
    Atom legacy = XInternAtom(display, "WM_NAME", False);
    double deadline = now_ms() + 15000;
    do {
        Window root, parent, *children = NULL, found = None;
        unsigned count;
        if (!XQueryTree(display, DefaultRootWindow(display), &root, &parent, &children, &count)) break;
        for (unsigned i = 0; i < count; ++i) {
            XWindowAttributes a;
            if (XGetWindowAttributes(display, children[i], &a) && a.map_state == IsViewable &&
                a.width == initial.w && a.height == initial.h &&
                (named_window(children[i], modern, title) || named_window(children[i], legacy, title)))
                found = children[i];
        }
        if (children) XFree(children);
        if (found) return found;
        pause_ns(10000000);
    } while (now_ms() < deadline);
    fprintf(stderr, "No mapped 800x600 fixture on the private display\n");
    exit(1);
}

static uint32_t background(Size s) {
    return s.w % 4 == 0 ? 0x223344 : 0x516273;
}

static bool ready_corner(Window win, Size s) {
    XImage *im = XGetImage(display, win, s.w - 1, s.h - 1, 1, 1, AllPlanes, ZPixmap);
    if (!im) return false;
    bool ready = (XGetPixel(im, 0, 0) & 0xffffff) == background(s);
    XDestroyImage(im);
    return ready;
}

static bool complete(XImage *im, Size s, bool diagnostic) {
    if (im->bits_per_pixel != 32 || im->byte_order != LSBFirst) {
        fprintf(stderr, "Observer requires little-endian XRGB on a 24-bit X server\n");
        exit(1);
    }
    uint32_t bg = background(s);
    int left = (s.w - 64) / 2, top = (s.h - 64) / 2;
    for (int y = 0; y < s.h; ++y) {
        const char *row = im->data + (size_t)y * im->bytes_per_line;
        for (int x = 0; x < s.w; ++x) {
            uint32_t pixel;
            memcpy(&pixel, row + (size_t)x * 4, sizeof pixel);
            uint32_t expected = y >= top && y < top+64 && x >= left && x < left+64 ? 0xe67e28 : bg;
            if ((pixel & 0xffffff) != expected) {
                if (diagnostic)
                    fprintf(stderr, "Pixel (%d,%d) is #%06x, expected #%06x\n", x, y, pixel & 0xffffff, expected);
                return false;
            }
        }
    }
    return true;
}

static double wait_for_pixels(Window win, Size s, double start, double *readback_ms) {
    while (now_ms() - start < 5000) {
        if (ready_corner(win, s)) {
            // Freeze a server-side snapshot, then take the timestamp. A slow
            // full-window readback cannot move the endpoint of a valid sample.
            XCopyArea(display, win, snapshot, capture, 0, 0, s.w, s.h, 0, 0);
            XSync(display, False);
            double end = now_ms();
            XImage *im = XGetImage(display, snapshot, 0, 0, s.w, s.h, AllPlanes, ZPixmap);
            double readback = now_ms() - end;
            if (im) {
                bool ok = complete(im, s, false);
                XDestroyImage(im);
                if (ok) {
                    *readback_ms = readback;
                    return end - start;
                }
            }
        }
        pause_ns(250000);
    }
    XImage *last = XGetImage(display, win, 0, 0, s.w, s.h, AllPlanes, ZPixmap);
    if (last) {
        complete(last, s, true);
        fprintf(stderr, "Window center is #%06lx\n", XGetPixel(last, s.w/2, s.h/2) & 0xffffff);
        XDestroyImage(last);
    }
    fprintf(stderr, "No fully correct %dx%d frame within 5 seconds\n", s.w, s.h);
    exit(1);
}

static void request_size(Window win, Size s) {
    XResizeWindow(display, win, (unsigned)s.w, (unsigned)s.h);
    XFlush(display);
}

static void sample(Window win, Size s, int round, const char *kind) {
    double start = now_ms();
    request_size(win, s);
    double readback;
    double latency = wait_for_pixels(win, s, start, &readback);
    if (round > 0) printf("%d,%s,%.3f,%.3f\n", round, kind, latency, readback);
}

int main(int argc, char **argv) {
    int rounds = argc == 3 ? atoi(argv[1]) : 0;
    if (rounds < 1) return 2;
    display = XOpenDisplay(NULL);
    if (!display) return 2;
    Window win = find_client(argv[2]);
    XWindowAttributes attr;
    if (!XGetWindowAttributes(display, win, &attr) || attr.depth != 24 ||
        attr.visual->red_mask != 0xff0000 || attr.visual->green_mask != 0xff00 ||
        attr.visual->blue_mask != 0xff) {
        fprintf(stderr, "Window must use the Xvfb screen's 24-bit TrueColor visual\n");
        return 1;
    }
    snapshot = XCreatePixmap(display, win, large.w, large.h, DefaultDepth(display, DefaultScreen(display)));
    XGCValues values = {.graphics_exposures = False};
    capture = XCreateGC(display, snapshot, GCGraphicsExposures, &values);
    double readback;
    wait_for_pixels(win, initial, now_ms(), &readback);
    for (int i = 0; i <= rounds; ++i) {
        sample(win, large, i, "grow");
        sample(win, small, i, "shrink");
        for (size_t j = 0; j < sizeof drag / sizeof drag[0]; ++j) {
            request_size(win, drag[j]);
            pause_ns(8000000);
        }
        sample(win, large, i, "drag-settle");
        sample(win, initial, 0, "reset");
    }
    XFreeGC(display, capture);
    XFreePixmap(display, snapshot);
    XCloseDisplay(display);
    return 0;
}
