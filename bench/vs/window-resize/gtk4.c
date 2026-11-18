// GTK's native X11 configure, drawing-area allocation and Cairo software paint.
#include <gtk/gtk.h>

static void draw(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    (void)area; (void)data;
    if (w % 4 == 0) cairo_set_source_rgb(cr, 34 / 255., 51 / 255., 68 / 255.);
    else cairo_set_source_rgb(cr, 81 / 255., 98 / 255., 115 / 255.);
    cairo_paint(cr);
    cairo_set_source_rgb(cr, 230 / 255., 126 / 255., 40 / 255.);
    cairo_rectangle(cr, (w - 64) / 2, (h - 64) / 2, 64, 64);
    cairo_fill(cr);
}

static gboolean close_window(GtkWindow *window, gpointer loop) {
    (void)window;
    g_main_loop_quit(loop);
    return FALSE;
}

int main(void) {
    g_setenv("GDK_BACKEND", "x11", TRUE);
    g_setenv("GSK_RENDERER", "cairo", TRUE);
    g_setenv("GDK_DISABLE", "gl,vulkan", TRUE);
    gtk_init();
    GtkWidget *window = gtk_window_new();
    GtkWidget *area = gtk_drawing_area_new();
    gtk_window_set_title(GTK_WINDOW(window), "resize-gtk4");
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    gtk_window_set_default_size(GTK_WINDOW(window), 800, 600);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw, NULL, NULL);
    gtk_window_set_child(GTK_WINDOW(window), area);
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_signal_connect(window, "close-request", G_CALLBACK(close_window), loop);
    gtk_window_present(GTK_WINDOW(window));
    g_main_loop_run(loop);
    g_main_loop_unref(loop);
    return 0;
}
