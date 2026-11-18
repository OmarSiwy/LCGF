// Slint's software platform receives the resized surface, evaluates bindings and paints it.
mod window;
use slint::platform::software_renderer::{MinimalSoftwareWindow, PremultipliedRgbaColor, RepaintBufferType};
use slint::platform::{Platform, WindowAdapter};
use slint::{ComponentHandle, PhysicalSize};
use std::rc::Rc;

slint::slint! {
    export component Scene inherits Window {
        background: mod(self.width / 1px, 4) == 0 ? #223344 : #516273;
        Rectangle {
            width: 64px; height: 64px;
            x: (parent.width - self.width) / 2;
            y: (parent.height - self.height) / 2;
            background: #e67e28;
        }
    }
}

struct Host(Rc<MinimalSoftwareWindow>);
impl Platform for Host {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.0.clone())
    }
}

fn main() {
    let adapter = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
    slint::platform::set_platform(Box::new(Host(adapter.clone()))).unwrap();
    let scene = Scene::new().unwrap();
    scene.show().unwrap();
    let mut buffer = Vec::new();
    window::run(c"resize-slint", |w, h, target| {
        adapter.set_size(PhysicalSize::new(w, h));
        scene.window().request_redraw();
        buffer.resize(target.len(), PremultipliedRgbaColor::default());
        adapter.draw_if_needed(|renderer| {
            renderer.render(&mut buffer, w as usize);
        });
        for (dst, pixel) in target.iter_mut().zip(&buffer) {
            *dst = u32::from_be_bytes([0, pixel.red, pixel.green, pixel.blue]);
        }
    });
}
