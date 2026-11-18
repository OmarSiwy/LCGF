// Borrow the shared XRGB framebuffer for a single redraw, then present it.
use std::ffi::{CStr, c_char, c_int};

unsafe extern "C" {
    fn resize_open(title: *const c_char);
    fn resize_next(width: *mut c_int, height: *mut c_int) -> *mut u32;
    fn resize_present();
}

pub fn run(title: &CStr, mut frame: impl FnMut(u32, u32, &mut [u32])) {
    unsafe { resize_open(title.as_ptr()) };
    loop {
        let (mut w, mut h) = (0, 0);
        let pixels = unsafe { resize_next(&mut w, &mut h) };
        if pixels.is_null() {
            return;
        }
        let buffer = unsafe { std::slice::from_raw_parts_mut(pixels, w as usize * h as usize) };
        frame(w as u32, h as u32, buffer);
        unsafe { resize_present() };
    }
}
