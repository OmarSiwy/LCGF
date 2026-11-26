//! A static UI's frame, built from a crate's build script, for `include_ui!(.., static)`'s
//! `SeamUi`: liblcgf's static frame specialized to the UI's tables, as Zig's compiler
//! specializes a comptime UI.
//!
//! ```ignore
//! // build.rs, with `lcgf` a dependency and `lcgf-build` a build-dependency
//! fn main() {
//!     lcgf_build::static_ui("controls.zon");
//! }
//! ```
//!
//! With a Zig compiler (`LCGF_ZIG`, else `zig` on `PATH`; `LCGF_ZIG=OFF` for none) it runs
//! `lcgf-gen --static --lang zig` and `zig build-lib` against the lcgf sources in
//! `<prefix>/share/lcgf/zig`, for the CPU `-C target-cpu` names (`LCGF_ZIG_CPU` overrides it).
//! Without one it builds `lcgf-gen --static --lang c` with the C compiler (`CC`, else `cc`):
//! clang specializes it, somewhat slower; any other compiler calls liblcgf's frame, which reads
//! the tables as data. The spec is found as `include_ui!` finds it: relative to `$LCGF_SPECS`
//! when set, else to the crate's manifest directory.

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Builds and links `lcgf_ui_<name>_frame` for the static UI spec `spec`.
pub fn static_ui(spec: &str) {
    let base = env::var("LCGF_SPECS")
        .or_else(|_| env::var("CARGO_MANIFEST_DIR"))
        .expect("CARGO_MANIFEST_DIR");
    let spec_path = Path::new(&base).join(spec);
    let name = spec_path
        .file_stem()
        .and_then(|s| s.to_str())
        .expect("a spec file name")
        .to_string();
    let prefix = env::var("DEP_LCGF_PREFIX")
        .or_else(|_| env::var("LCGF_PREFIX"))
        .expect("set LCGF_PREFIX to an installed `zig build abi` prefix");
    let lanes = env::var("DEP_LCGF_LANES")
        .expect("lcgf as a dependency (its build script names the lanes)");
    let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let lcgf_gen = env::var("LCGF_GEN")
        .map(PathBuf::from)
        .unwrap_or_else(|_| Path::new(&prefix).join("bin").join("lcgf-gen"));
    for v in ["LCGF_ZIG", "LCGF_ZIG_CPU", "LCGF_SPECS", "CC"] {
        println!("cargo::rerun-if-env-changed={v}");
    }
    println!("cargo::rerun-if-changed={}", spec_path.display());
    let lib = out.join(format!("liblcgf_ui_{name}.a"));
    match zig(&lanes) {
        Some(zig) => {
            let src = out.join(format!("{name}.lcgf.zig"));
            run(Command::new(&lcgf_gen)
                .arg(&spec_path)
                .args(["--static", "--lang", "zig", "-o"])
                .arg(&src));
            let share = Path::new(&prefix).join("share/lcgf/zig");
            let cpu = env::var("LCGF_ZIG_CPU").unwrap_or_else(|_| target_cpu());
            let mut c = Command::new(zig);
            c.args([
                "build-lib",
                "-OReleaseFast",
                "-fPIC",
                "-mcpu",
                &cpu,
                "--name",
                &format!("lcgf_ui_{name}"),
            ])
            .arg("--cache-dir")
            .arg(out.join("zig-cache"))
            .args(["--dep", "lcgf"])
            .arg(format!("-Mroot={}", src.display()))
            .args(["--dep", "build_options", "--dep", "unicode_tables"])
            .arg(format!("-Mlcgf={}", share.join("src/lcgf.zig").display()))
            .arg(format!(
                "-Mbuild_options={}",
                share.join(format!("options_l{lanes}.zig")).display()
            ))
            .arg(format!(
                "-Municode_tables={}",
                share.join("unicode_tables.zig").display()
            ))
            .arg(format!("-femit-bin={}", lib.display()));
            run(&mut c);
        }
        None => {
            println!(
                "cargo::warning=lcgf: no Zig compiler (LCGF_ZIG, or zig on PATH): static UI {name}'s frame is built from C, specialized only by clang and otherwise slower"
            );
            let src = out.join(format!("{name}.lcgf.c"));
            let obj = out.join(format!("{name}.lcgf.o"));
            run(Command::new(&lcgf_gen)
                .arg(&spec_path)
                .args(["--static", "--lang", "c", "-o"])
                .arg(&src));
            let cc = env::var("CC").unwrap_or_else(|_| "cc".into());
            let lanes_def = if lanes == "auto" {
                "0".to_string()
            } else {
                lanes.clone()
            };
            run(Command::new(&cc)
                .args([
                    "-c",
                    "-O3",
                    "-fPIC",
                    "-ffp-contract=off",
                    "-fno-strict-aliasing",
                ])
                .arg(format!("-DLCGF_LANES={lanes_def}"))
                .arg(format!("-I{prefix}/include"))
                .arg(format!("-I{prefix}/share/lcgf"))
                .arg(&src)
                .arg("-o")
                .arg(&obj));
            let _ = std::fs::remove_file(&lib);
            run(Command::new(env::var("AR").unwrap_or_else(|_| "ar".into()))
                .arg("crs")
                .arg(&lib)
                .arg(&obj));
        }
    }
    println!("cargo::rustc-link-search=native={}", out.display());
    println!("cargo::rustc-link-lib=static=lcgf_ui_{name}");
}

/// The Zig compiler to build frames with, if any: not for liblcgf_auto.a, whose lane count is
/// chosen at run time.
fn zig(lanes: &str) -> Option<String> {
    if lanes == "auto" {
        return None;
    }
    let zig = env::var("LCGF_ZIG").unwrap_or_else(|_| "zig".into());
    if zig == "OFF" {
        return None;
    }
    Command::new(&zig)
        .arg("version")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|_| zig)
}

/// The CPU rustc builds for: `-C target-cpu` from the encoded flags, else the baseline.
fn target_cpu() -> String {
    let flags = env::var("CARGO_ENCODED_RUSTFLAGS").unwrap_or_default();
    let mut it = flags.split('\x1f').peekable();
    let mut cpu = "baseline".to_string();
    while let Some(f) = it.next() {
        let v = if f == "-C" {
            it.next().unwrap_or("")
        } else {
            f.strip_prefix("-C").unwrap_or("")
        };
        if let Some(c) = v.strip_prefix("target-cpu=") {
            cpu = c.to_string();
        }
    }
    cpu
}

fn run(c: &mut Command) {
    let status = c.status().unwrap_or_else(|e| panic!("{c:?}: {e}"));
    assert!(status.success(), "{c:?} failed: {status}");
}
