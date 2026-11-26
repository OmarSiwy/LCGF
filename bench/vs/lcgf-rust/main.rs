//! The scenes of bench/scenes/ on LCGF from Rust: `lcgf::runtime` over the prebuilt liblcgf, no
//! Zig compiler. The driver is harness.rs's; the frame is bench/vs/lcgf/main.zig's, built through
//! the C seam (bindings/rust/lcgf-check/src/scenes.rs, which bindings/check/run.sh holds
//! byte-identical to the Zig scenes). Beside vs-lcgf it shows what a builder call costs across
//! the seam.

#[path = "../harness.rs"]
mod harness;
#[path = "../../../bindings/rust/lcgf-check/src/scenes.rs"]
mod scenes;

use lcgf::runtime::Context;
use std::alloc::{Layout, alloc};

fn main() {
    let mut ctx: Option<Context<'static>> = None;
    let mut state: Option<scenes::State> = None;
    let mut input = lcgf::Input::default();
    harness::main(
        "lcgf-rust",
        |scene, k| {
            if k == 0 {
                let s = scenes::State::new(scenes::NAMES[scene].1);
                let limits = s.limits();
                let n = Context::bytes(&limits);
                // Allocated once and kept, as vs-lcgf maps its buffer; never zeroed by hand, so
                // pages the scene never touches stay unresident.
                let buf = unsafe {
                    let p = alloc(Layout::from_size_align(n, lcgf::COLUMN_ALIGN).unwrap());
                    std::slice::from_raw_parts_mut(p, n)
                };
                ctx = Some(Context::new(buf, &limits).expect("context"));
                state = Some(s);
            }
            let (c, s) = (ctx.as_mut().unwrap(), state.as_mut().unwrap());
            s.input(&mut input, k);
            if !s.every() && !c.needs_frame(&input) {
                return 0;
            }
            let th = *c.theme();
            let mut f = c.begin(&input);
            s.build(&mut f, &th);
            let (d, _) = f.end();
            d.command_count() as u64 + d.quads().len() as u64
        },
        harness::block_on_stdin,
    );
}
