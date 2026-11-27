//! LCGF: Lightweight Comptime Graphics Framework. The package root.
//!
//! Each file under src/ is exported here as `pub const name = @import("dir/name.zig");`.
//! A file that is not exported is not compiled and its tests do not run.

const std = @import("std");

pub const simd = @import("core/simd.zig");
pub const input = @import("core/input.zig");
pub const types = @import("core/types.zig");
pub const mem = @import("core/mem.zig");
pub const tree = @import("core/tree.zig");
pub const strings = @import("core/strings.zig");
/// The format language of formatted labels (`spec.text`, a `.zon` `.text`), shared by every engine.
pub const text_format = @import("core/fmt.zig");
pub const texts = @import("core/texts.zig");
pub const customs = @import("core/customs.zig");
pub const layout = @import("layout/layout.zig");
pub const overlay = @import("layout/overlay.zig");
pub const scroll = @import("layout/scroll.zig");
pub const grid = @import("layout/grid.zig");
pub const rtl = @import("layout/rtl.zig");
pub const hit_targets = @import("interact/targets.zig");
pub const hit = @import("interact/hit.zig");
pub const flex = @import("layout/flex.zig");
pub const wrap = @import("layout/wrap.zig");
pub const baseline = @import("layout/baseline.zig");
pub const layout_check = @import("layout/check.zig");
pub const coefs = @import("layout/coefs.zig");
pub const levels = @import("layout/levels.zig");
pub const runs = @import("layout/runs.zig");
pub const incremental = @import("layout/incremental.zig");
pub const interaction = @import("interact/interaction.zig");
pub const focus = @import("interact/focus.zig");
pub const keyboard = @import("interact/keyboard.zig");
pub const gestures = @import("interact/gestures.zig");
pub const spec = @import("comptime/spec.zig");
pub const protocol = @import("text/protocol.zig");
pub const flatten = @import("comptime/flatten.zig");
pub const validate = @import("comptime/validate.zig");
pub const columns = @import("comptime/columns.zig");
pub const ct_features = @import("comptime/features.zig");
pub const ct_layout = @import("comptime/layout.zig");
pub const ct_paint = @import("comptime/paint.zig");
pub const ct_examples = @import("comptime/examples.zig");
pub const ct_dynamic = @import("comptime/dynamic.zig");
pub const signals = @import("comptime/signals.zig");
pub const events = @import("comptime/events.zig");
pub const prepared = @import("render/prepared.zig");
pub const color_output = @import("draw/color_output.zig");
pub const filter_primitives = @import("draw/filter_primitives.zig");
pub const units = @import("layout/units.zig");
pub const logical = @import("layout/logical.zig");
pub const decoration = @import("draw/decoration.zig");
pub const projective = @import("draw/projective.zig");
pub const motion = @import("anim/motion.zig");
pub const font_match = @import("text/font/match.zig");
pub const text_decorations = @import("text/layout/decorations.zig");
pub const compositor = @import("draw/compositor.zig");
pub const brushes = @import("draw/brushes.zig");
pub const color_math = @import("draw/color_math.zig");
pub const surface = @import("draw/surface.zig");
pub const geometry = @import("draw/geometry.zig");
pub const outline = @import("draw/outline.zig");
pub const theme_recipes = @import("theme/recipes.zig");
pub const style = @import("style/style.zig");
/// Many 2D primitives in caller-owned columns under a camera: `Frame.canvas`, `canvas.hit`.
pub const canvas = @import("draw/canvas.zig");
pub const draw_list = @import("draw/draw_list.zig");
pub const opentype = @import("text/font/opentype.zig");
pub const unicode_property = @import("text/unicode/property.zig");
pub const unicode_utf8 = @import("text/unicode/utf8.zig");
pub const unicode_grapheme = @import("text/unicode/grapheme.zig");
pub const unicode_word = @import("text/unicode/word.zig");
pub const paint = @import("draw/paint.zig");
pub const damage = @import("draw/damage.zig");
pub const features = @import("draw/features.zig");
pub const inherit = @import("draw/inherit.zig");
pub const order = @import("draw/order.zig");
pub const paths = @import("draw/paths.zig");
pub const tinyvg = @import("draw/tinyvg.zig");
pub const unicode_line = @import("text/unicode/line.zig");
pub const unicode_bidi = @import("text/unicode/bidi.zig");
pub const unicode_script = @import("text/unicode/script.zig");
pub const raster = @import("text/raster/raster.zig");
pub const raster_gamma = @import("text/raster/gamma.zig");
pub const raster_atlas = @import("text/raster/atlas.zig");
pub const raster_sdf = @import("text/raster/sdf.zig");
pub const shape = @import("text/shape/shape.zig");
pub const shape_layout = @import("text/shape/layout.zig");
pub const shape_cluster = @import("text/shape/cluster.zig");
pub const shape_cache = @import("text/shape/cache.zig");
pub const render_iface = @import("render/iface.zig");
pub const render_conformance = @import("render/conformance.zig");
pub const quad_shader = @import("render/shaders/quad.zig");
pub const canvas_shader = @import("render/shaders/canvas.zig");
pub const render_null = @import("render/null.zig");
pub const gpu_desc = @import("render/gpu/desc.zig");
pub const gpu_reflect = @import("render/gpu/reflect.zig");
pub const gpu_gradient = @import("render/gpu/gradient.zig");
pub const gpu_canvas = @import("render/gpu/canvas.zig");
pub const gpu_check = @import("render/gpu/check.zig");
pub const gpu_naga = @import("render/gpu/naga.zig");
pub const context = @import("runtime/context.zig");
pub const frame = @import("runtime/frame.zig");
pub const text_lines = @import("text/layout/lines.zig");
pub const text_spans = @import("text/layout/spans.zig");
pub const text_query = @import("text/layout/query.zig");
pub const text_stack = @import("text/layout/stack.zig");
pub const text_layout_tests = @import("text/layout/tests.zig");
pub const scheduler = @import("runtime/scheduler.zig");
pub const reuse = @import("runtime/reuse.zig");
pub const widgets_base = @import("widgets/base.zig");
/// The common runtime widgets with the frame and theme given once and options by name:
/// `const ui = widgets.on(f, th); ui.slider(.gain, &gain, .{ .max = 4 })`.
pub const widgets = @import("widgets/kit.zig");
pub const widgets_label = @import("widgets/label.zig");
pub const widgets_button = @import("widgets/button.zig");
pub const widgets_link = @import("widgets/link.zig");
pub const widgets_checkbox = @import("widgets/checkbox.zig");
pub const widgets_radio = @import("widgets/radio.zig");
pub const widgets_switch = @import("widgets/switch.zig");
pub const widgets_toggle = @import("widgets/toggle.zig");
pub const widgets_slider = @import("widgets/slider.zig");
pub const widgets_range = @import("widgets/range.zig");
pub const widgets_chip = @import("widgets/chip.zig");
pub const widgets_list = @import("widgets/list.zig");
pub const widgets_vlist = @import("widgets/vlist.zig");
pub const widgets_table = @import("widgets/table.zig");
pub const widgets_tree = @import("widgets/tree.zig");
pub const widgets_progress = @import("widgets/progress.zig");
pub const widgets_spinner = @import("widgets/spinner.zig");
pub const widgets_colorpicker = @import("widgets/colorpicker.zig");
pub const widgets_card = @import("widgets/card.zig");
pub const widgets_separator = @import("widgets/separator.zig");
pub const theme = @import("theme/theme.zig");
pub const theme_table = @import("theme/table.zig");
pub const theme_tests = @import("theme/tests.zig");
pub const widgets_check = @import("widgets/check.zig");
pub const widgets_spacer = @import("widgets/spacer.zig");
pub const widgets_accordion = @import("widgets/accordion.zig");
pub const widgets_tabs = @import("widgets/tabs.zig");
pub const widgets_keys = @import("widgets/keys.zig");
pub const widgets_splitter = @import("widgets/splitter.zig");
pub const widgets_dock = @import("widgets/dock.zig");
pub const widgets_records = @import("widgets/records.zig");
pub const widgets_scroll = @import("widgets/scroll.zig");
pub const widgets_toolbar = @import("widgets/toolbar.zig");
pub const widgets_statusbar = @import("widgets/statusbar.zig");
pub const widgets_breadcrumb = @import("widgets/breadcrumb.zig");
pub const widgets_icon = @import("widgets/icon.zig");
pub const widgets_popover = @import("widgets/popover.zig");
pub const widgets_tooltip = @import("widgets/tooltip.zig");
pub const widgets_menu = @import("widgets/menu.zig");
pub const widgets_menubar = @import("widgets/menubar.zig");
pub const widgets_contextmenu = @import("widgets/contextmenu.zig");
pub const widgets_dialog = @import("widgets/dialog.zig");
pub const widgets_toast = @import("widgets/toast.zig");
pub const widgets_select = @import("widgets/select.zig");
pub const widgets_combobox = @import("widgets/combobox.zig");
pub const widgets_datepicker = @import("widgets/datepicker.zig");
pub const widgets_image = @import("widgets/image.zig");
pub const widgets_textfield = @import("widgets/textfield.zig");
pub const widgets_search = @import("widgets/search.zig");
pub const widgets_number = @import("widgets/number.zig");
pub const widgets_textarea = @import("widgets/textarea.zig");
pub const a11y_tree = @import("a11y/tree.zig");
pub const a11y_settings = @import("a11y/settings.zig");
pub const settings_data = @import("a11y/settings_data.zig");
pub const render_sw = @import("render/sw/sw.zig");
/// The bundled bitmap font (DejaVu Sans Mono, 14 px) in `Mono`'s grid, for a software shell's text.
pub const render_sw_font = @import("render/sw/font.zig");
pub const png = @import("assets/png.zig");
pub const embed = @import("assets/embed.zig");
pub const image_jobs = @import("assets/image_jobs.zig");
pub const image_atlas = @import("assets/image_atlas.zig");
pub const image_mipmaps = @import("assets/image_mipmaps.zig");
pub const image_tests = @import("assets/image_tests.zig");
pub const render_wgpu = @import("render/wgpu/wgpu.zig");
pub const text_buffer = @import("text/edit/buffer.zig");
pub const text_moves = @import("text/edit/moves.zig");
pub const text_edit = @import("text/edit/edit.zig");
pub const text_history = @import("text/edit/history.zig");
pub const text_edit_tests = @import("text/edit/tests.zig");
pub const fallback = @import("text/fallback/fallback.zig");
pub const fallback_tests = @import("text/fallback/tests.zig");
pub const shell_materials = @import("shell/materials.zig");
pub const shell_iface = @import("shell/iface.zig");
pub const shell_example = @import("shell/example.zig");
pub const runtime_signals = @import("runtime/signals.zig");
pub const anims = @import("anim/anims.zig");
pub const tweens = @import("anim/tweens.zig");
pub const keyframes = @import("anim/keyframes.zig");
pub const flip = @import("anim/flip.zig");
/// What `Frame.animate` and `Frame.tween` can move: numbers, colours, and arrays, vectors and
/// structs of them.
pub const anim_values = @import("anim/values.zig");
pub const shell_headless = @import("shell/headless.zig");
pub const shell_baremetal_flush = @import("shell/baremetal/flush.zig");
pub const shell_baremetal_input = @import("shell/baremetal/input.zig");
pub const shell_baremetal_tick = @import("shell/baremetal/tick.zig");
pub const shell_baremetal_shell = @import("shell/baremetal/shell.zig");
pub const shell_baremetal_sim = @import("shell/baremetal/sim.zig");
pub const shell_web = @import("shell/web/web.zig");
pub const shell_x11_wire = @import("shell/x11/wire.zig");
pub const shell_x11_keys = @import("shell/x11/keys.zig");
pub const shell_x11_xim = @import("shell/x11/xim.zig");
pub const shell_win32_translate = @import("shell/win32/translate.zig");
pub const shell_ios_translate = @import("shell/ios/translate.zig");
pub const shell_android_translate = @import("shell/android/translate.zig");
pub const shell_macos_translate = @import("shell/macos/translate.zig");

test {
    std.testing.refAllDecls(@This());
}
pub const i18n_catalogue = @import("i18n/catalogue.zig");
pub const i18n_plural = @import("i18n/plural.zig");
pub const i18n_number = @import("i18n/number.zig");
pub const i18n_date = @import("i18n/date.zig");
pub const i18n_bundle = @import("i18n/bundle.zig");
pub const i18n_pseudo = @import("i18n/pseudo.zig");
pub const ct_interop = @import("comptime/interop.zig");
/// The comptime front end's tables as data, and the prebuilt frame that reads them behind the
/// C seam (C++ and Rust bindings: bindings/, tools/lcgf-gen/).
pub const abi = @import("abi/abi.zig");
pub const abi_words = @import("abi/words.zig");
pub const abi_plan = @import("abi/plan.zig");
pub const abi_seam = @import("abi/seam.zig");
pub const abi_zon = @import("abi/zon.zig");
pub const abi_api = @import("abi/api.zig");
pub const abi_view = @import("abi/view.zig");
pub const abi_canvas = @import("abi/canvas.zig");
pub const abi_ct = @import("abi/ct.zig");
pub const ct_tables = @import("comptime/tables.zig");

pub const embedded_fixed = @import("embedded/fixed.zig");
pub const embedded_framebuffer = @import("embedded/framebuffer.zig");
pub const embedded_font = @import("embedded/font.zig");
pub const embedded_spi = @import("embedded/spi.zig");

pub const vertical_text = @import("text/layout/vertical.zig");

pub const inline_objects = @import("text/layout/inline_objects.zig");

pub const image_sampling = @import("draw/image_sampling.zig");
pub const svg = @import("draw/svg.zig");
pub const vector = @import("draw/vector.zig");

pub const effects = @import("render/effects.zig");

pub const text_break_policy = @import("text/layout/break_policy.zig");
pub const text_display = @import("text/layout/display.zig");

pub const cursor = @import("draw/cursor.zig");
pub const capabilities = @import("render/capabilities.zig");

pub const scroll_policy = @import("layout/scroll_policy.zig");

pub const scroll_area = @import("widgets/scroll_area.zig");

pub const special_layout = @import("layout/special.zig");

pub const document_layout = @import("layout/document.zig");

pub const rounding = @import("layout/rounding.zig");
pub const text_intrinsic = @import("text/layout/intrinsic.zig");
pub const math_text = @import("text/layout/math.zig");
pub const ornamental_text = @import("text/layout/ornament.zig");
pub const text_counters = @import("text/layout/counters.zig");

pub const backgrounds = @import("draw/backgrounds.zig");
pub const image_variants = @import("draw/image_variants.zig");

pub const masks = @import("draw/masks.zig");

pub const grid_names = @import("layout/grid_names.zig");
pub const text_metrics = @import("text/layout/metrics.zig");

pub const text_emphasis = @import("text/layout/emphasis.zig");
