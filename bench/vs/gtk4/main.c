// The six harness.h scenes rendered by GTK 4. GTK owns the controls, Pango layout and
// GSK render nodes. Active polls deliver X11 pointer motion, allocate the requested
// viewport and take a snapshot. The output count is the number of top-level GSK
// nodes. GTK can reuse a cached node, and dispatching its main context can also
// service paints. The native resize-to-pixels fixture lives in window-resize/.
// GTK widget size requests round spring widths to integer pixels. Idle runs the native
// GLib loop. Build with pkg-config gtk4-x11 and run under Xvfb.
#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <glib-unix.h>
#include "../harness.h"

typedef struct { GtkWindow parent; } BenchWindow;
typedef GtkWindowClass BenchWindowClass;
G_DEFINE_TYPE(BenchWindow, bench_window, GTK_TYPE_WINDOW)

static uint64_t window_snapshots;

static void window_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    GTK_WIDGET_CLASS(bench_window_parent_class)->snapshot(widget, snapshot);
    window_snapshots++;
}

static void bench_window_class_init(BenchWindowClass *klass) {
    GTK_WIDGET_CLASS(klass)->snapshot = window_snapshot;
}

static void bench_window_init(BenchWindow *self) { (void)self; }

// Indices are the list's data. GtkListView asks the model for items on demand and
// recycles the factory-created row widgets as the scrolled window moves.
typedef struct { GObject parent; } RowModel;
typedef GObjectClass RowModelClass;

static GType row_type(GListModel *model) { (void)model; return G_TYPE_OBJECT; }
static guint row_count(GListModel *model) { (void)model; return 100000; }
static gpointer row_at(GListModel *model, guint position) {
    return position < row_count(model) ? g_object_new(G_TYPE_OBJECT, NULL) : NULL;
}
static void row_model_interface(GListModelInterface *iface) {
    iface->get_item_type = row_type;
    iface->get_n_items = row_count;
    iface->get_item = row_at;
}
G_DEFINE_TYPE_WITH_CODE(RowModel, row_model, G_TYPE_OBJECT,
                        G_IMPLEMENT_INTERFACE(G_TYPE_LIST_MODEL, row_model_interface))
static void row_model_class_init(RowModelClass *klass) { (void)klass; }
static void row_model_init(RowModel *model) { (void)model; }

static GtkWindow *window;
static GtkWidget *scene_widget;
static GtkAdjustment *list_scroll;
static GtkWidget *bars[1000];
static VsSprings springs;
static Display *xdisplay;
static Window xwindow;

static GtkWidget *box(GtkOrientation dir, int spacing) {
    return gtk_box_new(dir, spacing);
}
static void append(GtkWidget *parent, GtkWidget *child) {
    gtk_box_append(GTK_BOX(parent), child);
}
static GtkWidget *label(const char *text) {
    GtkWidget *w = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(w), 0);
    return w;
}
static GtkWidget *scroll(GtkWidget *child) {
    GtkWidget *w = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(w), GTK_POLICY_NEVER, GTK_POLICY_EXTERNAL);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(w), child);
    return w;
}
static void margin(GtkWidget *w, int px) {
    gtk_widget_set_margin_start(w, px);
    gtk_widget_set_margin_end(w, px);
    gtk_widget_set_margin_top(w, px);
    gtk_widget_set_margin_bottom(w, px);
}
static GtkWidget *form(void) {
    GtkWidget *col = box(GTK_ORIENTATION_VERTICAL, 4);
    margin(col, 12);
    GtkWidget *title = label("Account settings");
    gtk_widget_add_css_class(title, "heading");
    append(col, title);
    append(col, gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    for (guint i = 0; i < G_N_ELEMENTS(vs_form_names); i++) {
        GtkWidget *row = box(GTK_ORIENTATION_HORIZONTAL, 6);
        GtkWidget *name = label(vs_form_names[i]);
        gtk_widget_set_size_request(name, 90, -1);
        append(row, name);
        GtkWidget *entry = gtk_entry_new();
        gtk_editable_set_text(GTK_EDITABLE(entry), vs_form_names[i]);
        gtk_widget_set_hexpand(entry, TRUE);
        append(row, entry);
        append(row, gtk_check_button_new_with_label("On"));
        GtkWidget *slider = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, .01);
        gtk_range_set_value(GTK_RANGE(slider), .5);
        gtk_widget_set_hexpand(slider, TRUE);
        append(row, slider);
        append(col, row);
    }
    GtkWidget *buttons = box(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_halign(buttons, GTK_ALIGN_END);
    append(buttons, gtk_button_new_with_label("Cancel"));
    append(buttons, gtk_button_new_with_label("Reset"));
    append(buttons, gtk_button_new_with_label("Save"));
    append(col, buttons);
    return scroll(col);
}

static void row_setup(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data) {
    (void)factory; (void)data;
    GtkWidget *row = box(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_size_request(row, -1, 24);
    GtkWidget *name = label(NULL);
    gtk_widget_set_margin_start(name, 8);
    append(row, name);
    append(row, label(NULL));
    GtkWidget *swatch = box(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_size_request(swatch, 12, 12);
    gtk_widget_set_valign(swatch, GTK_ALIGN_CENTER);
    gtk_widget_add_css_class(swatch, "accent-box");
    append(row, swatch);
    gtk_list_item_set_child(item, row);
}
static void row_bind(GtkSignalListItemFactory *factory, GtkListItem *item, gpointer data) {
    (void)factory; (void)data;
    guint index = gtk_list_item_get_position(item);
    GtkWidget *row = gtk_list_item_get_child(item);
    GtkWidget *name = gtk_widget_get_first_child(row);
    char text[32];
    g_snprintf(text, sizeof(text), "Row %u", index);
    gtk_label_set_text(GTK_LABEL(name), text);
    gtk_label_set_text(GTK_LABEL(gtk_widget_get_next_sibling(name)), vs_list_names[index % 7]);
    if (index & 1) gtk_widget_add_css_class(row, "odd");
    else gtk_widget_remove_css_class(row, "odd");
}
static GtkWidget *list(void) {
    GtkListItemFactory *factory = gtk_signal_list_item_factory_new();
    g_signal_connect(factory, "setup", G_CALLBACK(row_setup), NULL);
    g_signal_connect(factory, "bind", G_CALLBACK(row_bind), NULL);
    GtkNoSelection *selection = gtk_no_selection_new(g_object_new(row_model_get_type(), NULL));
    GtkWidget *view = gtk_list_view_new(GTK_SELECTION_MODEL(selection), factory);
    GtkWidget *w = scroll(view);
    list_scroll = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(w));
    return w;
}

static GtkWidget *prose(void) {
    GtkWidget *row = box(GTK_ORIENTATION_HORIZONTAL, 16);
    margin(row, 12);
    GtkWidget *chapters = box(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_size_request(chapters, 160, -1);
    for (int i = 1; i <= 120; i++) {
        char text[32];
        g_snprintf(text, sizeof(text), "Chapter %d", i);
        append(chapters, label(text));
    }
    append(row, chapters);
    GtkWidget *body = box(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_hexpand(body, TRUE);
    append(row, body);
    for (int s = 0; s < 12; s++) {
        char text[32];
        g_snprintf(text, sizeof(text), "Section %d", s + 1);
        GtkWidget *heading = label(text);
        gtk_widget_add_css_class(heading, "heading");
        append(body, heading);
        for (int p = 0; p < 4; p++) {
            GtkWidget *paragraph = label(vs_prose[(s + p) % 4]);
            gtk_label_set_wrap(GTK_LABEL(paragraph), TRUE);
            gtk_label_set_wrap_mode(GTK_LABEL(paragraph), PANGO_WRAP_WORD_CHAR);
            append(body, paragraph);
        }
    }
    return scroll(row);
}

static GtkWidget *spring_grid(void) {
    GtkWidget *grid = box(GTK_ORIENTATION_VERTICAL, 2);
    margin(grid, 8);
    for (int y = 0; y < 40; y++) {
        GtkWidget *row = box(GTK_ORIENTATION_HORIZONTAL, 2);
        append(grid, row);
        for (int x = 0; x < 25; x++) {
            GtkWidget *bar = box(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_widget_add_css_class(bar, "accent-box");
            gtk_widget_set_size_request(bar, 4, 16);
            gtk_widget_set_valign(bar, GTK_ALIGN_CENTER);
            bars[y * 25 + x] = bar;
            append(row, bar);
        }
    }
    return grid;
}

static void pump(void) {
    while (g_main_context_iteration(NULL, FALSE)) {}
}
static void start(int scene, VsInput in) {
    gtk_init();
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css,
        "window { background: #1e1f24; color: #e6e6eb; font-size: 14px; }"
        ".heading { font-size: 20px; }.accent-box { background: #5a8cff; }"
        "listview row { padding: 0; margin: 0; border: none; min-height: 0; background: #282a32; }"
        "listview row .odd { background: #3b3d48; }");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    window = g_object_new(bench_window_get_type(), NULL);
    gtk_window_set_decorated(window, FALSE);
    gtk_window_set_default_size(window, (int)in.w, (int)in.h);
    scene_widget = scene == VS_LIST ? list() : scene == VS_SPRINGS ? spring_grid()
                 : scene == VS_TEXT || scene == VS_RESIZE ? prose() : form();
    gtk_window_set_child(window, scene_widget);
    gtk_window_present(window);
    gtk_window_set_focus(window, NULL);
    while (!window_snapshots) g_main_context_iteration(NULL, TRUE);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
    xdisplay = gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
    xwindow = gdk_x11_surface_get_xid(surface);
}

static uint64_t vs_frame(int scene, uint32_t k) {
    VsInput in = vs_input(scene, k);
    if (!k) start(scene, in);
    uint64_t before = window_snapshots;
    if (scene == VS_IDLE && k) {
        pump();
        return window_snapshots - before;
    }
    static float previous_x, previous_y;
    if (!k || in.px != previous_x || in.py != previous_y) {
        XWarpPointer(xdisplay, None, xwindow, 0, 0, 0, 0, (int)in.px, (int)in.py);
        XSync(xdisplay, False);
        previous_x = in.px;
        previous_y = in.py;
    }
    pump();
    if (scene == VS_LIST) gtk_adjustment_set_value(list_scroll, in.scroll);
    if (scene == VS_SPRINGS) {
        vs_springs_step(&springs, in.tick, in.dt);
        for (int i = 0; i < 1000; i++)
            gtk_widget_set_size_request(bars[i], (int)(springs.x[i] + .5f), 16);
    }
    int minimum;
    gtk_widget_measure(scene_widget, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, NULL, NULL, NULL);
    gtk_widget_measure(scene_widget, GTK_ORIENTATION_VERTICAL, (int)in.w, &minimum, NULL, NULL, NULL);
    gtk_widget_allocate(scene_widget, (int)in.w, (int)in.h, -1, NULL);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gtk_widget_snapshot_child(GTK_WIDGET(window), scene_widget, snapshot);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    if (!node) g_error("GTK produced an empty snapshot for %s", vs_scene_names[scene]);
    uint64_t count = gsk_render_node_get_node_type(node) == GSK_CONTAINER_NODE
                   ? gsk_container_node_get_n_children(node) : 1;
    gsk_render_node_unref(node);
    return count;
}

static gboolean stdin_ready(gint fd, GIOCondition condition, gpointer data) {
    char byte;
    if ((condition & (G_IO_HUP | G_IO_ERR)) || read(fd, &byte, 1) <= 0) {
        g_main_loop_quit(data);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}
static void vs_idle(void) {
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    g_unix_fd_add(STDIN_FILENO, G_IO_IN | G_IO_HUP | G_IO_ERR, stdin_ready, loop);
    g_main_loop_run(loop);
    g_main_loop_unref(loop);
}

int main(int argc, char **argv) {
    g_setenv("GDK_BACKEND", "x11", TRUE);
    g_setenv("GSK_RENDERER", "cairo", TRUE);
    g_setenv("GDK_DISABLE", "gl,vulkan", TRUE);
    char name[48];
    snprintf(name, sizeof(name), "gtk4-%u.%u.%u", gtk_get_major_version(),
             gtk_get_minor_version(), gtk_get_micro_version());
    return vs_main(argc, argv, name);
}
