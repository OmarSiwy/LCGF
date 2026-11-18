// The regular Iced widget layout/paint and tiny-skia rasterizer at scale factor 1.
mod window;
use iced_core::{Color, Element, Font, Length, Pixels, Rectangle, Size, Theme, mouse, renderer};
use iced_runtime::user_interface::{self, UserInterface};
use iced_tiny_skia::{Renderer, graphics::Viewport};
use iced_widget::{container, space};

fn main() {
    let mut renderer = Renderer::new(Font::DEFAULT, Pixels(14.0));
    let mut cache = Some(user_interface::Cache::default());
    window::run(c"resize-iced", |w, h, target| {
        let block = container(space())
            .width(64)
            .height(64)
            .style(|_| container::Style::default().background(Color::from_rgb8(230, 126, 40)));
        let view: Element<'_, (), Theme, Renderer> = container(block).center(Length::Fill).into();
        let mut ui = UserInterface::build(
            view,
            Size::new(w as f32, h as f32),
            cache.take().unwrap(),
            &mut renderer,
        );
        ui.draw(
            &mut renderer,
            &Theme::Dark,
            &renderer::Style {
                text_color: Color::WHITE,
            },
            mouse::Cursor::Unavailable,
        );
        cache = Some(ui.into_cache());
        let viewport = Viewport::with_physical_size(Size::new(w, h), 1.0);
        let bg = if w % 4 == 0 {
            Color::from_rgb8(34, 51, 68)
        } else {
            Color::from_rgb8(81, 98, 115)
        };
        let mut mask = tiny_skia::Mask::new(w, h).unwrap();
        // iced_tiny_skia already writes the BGR channel order of its native software surface.
        let bytes = unsafe { std::slice::from_raw_parts_mut(target.as_mut_ptr().cast(), target.len() * 4) };
        let mut pixmap = tiny_skia::PixmapMut::from_bytes(bytes, w, h).unwrap();
        renderer.draw(
            &mut pixmap,
            &mut mask,
            &viewport,
            &[Rectangle::with_size(viewport.logical_size())],
            bg,
        );
    });
}
