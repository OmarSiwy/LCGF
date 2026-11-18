// egui's centered layout and tessellator emit untextured opaque triangles for Cairo.
mod window;
use egui::{Color32, Context, Frame, Pos2, RawInput, Rect, Sense, Vec2, epaint::Primitive};

unsafe extern "C" {
    fn resize_tri(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, rgb: u32);
    fn resize_clip(x: i32, y: i32, w: i32, h: i32);
}

fn main() {
    let ctx = Context::default();
    ctx.tessellation_options_mut(|options| options.feathering = false);
    window::run(c"resize-egui", |w, h, _| {
        let screen = Rect::from_min_size(Pos2::ZERO, Vec2::new(w as f32, h as f32));
        let raw = RawInput {
            screen_rect: Some(screen),
            ..Default::default()
        };
        let bg = if w % 4 == 0 {
            Color32::from_rgb(34, 51, 68)
        } else {
            Color32::from_rgb(81, 98, 115)
        };
        let output = ctx.run_ui(raw, |ui| {
            egui::CentralPanel::no_frame()
                .frame(Frame::NONE.fill(bg))
                .show(ui, |ui| {
                    ui.centered_and_justified(|ui| {
                        let (rect, _) = ui.allocate_exact_size(Vec2::splat(64.0), Sense::hover());
                        ui.painter().rect_filled(rect, 0, Color32::from_rgb(230, 126, 40));
                    });
                });
        });
        for item in ctx.tessellate(output.shapes, output.pixels_per_point) {
            let Primitive::Mesh(mesh) = item.primitive else {
                panic!("unexpected callback")
            };
            let clip = item.clip_rect.intersect(screen);
            unsafe {
                resize_clip(
                    clip.min.x as i32,
                    clip.min.y as i32,
                    clip.width() as i32,
                    clip.height() as i32,
                )
            };
            for tri in mesh.triangles() {
                let [a, b, c] = tri.map(|i| &mesh.vertices[i as usize]);
                assert!(a.color == b.color && a.color == c.color);
                let rgb = u32::from_be_bytes([0, a.color.r(), a.color.g(), a.color.b()]);
                unsafe { resize_tri(a.pos.x, a.pos.y, b.pos.x, b.pos.y, c.pos.x, c.pos.y, rgb) };
            }
        }
    });
}
