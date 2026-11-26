//! Links the prebuilt liblcgf for this target's lane count, from `LCGF_PREFIX` (an installed
//! `zig build abi`). The lane count follows the target features, as the C++ header does: 8 with
//! AVX, else 4; `LCGF_LANES` overrides it. The crate names the matching frame symbol, so there
//! is no dispatch at run time. The `lanes-auto` feature (or `LCGF_LANES=auto`) links
//! liblcgf_auto.a instead, which picks the width from the CPU at the first call.
use std::env;

fn main() {
    println!("cargo::rerun-if-env-changed=LCGF_PREFIX");
    println!("cargo::rerun-if-env-changed=LCGF_LANES");
    println!("cargo::rustc-check-cfg=cfg(lcgf_lanes, values(\"4\", \"8\", \"16\", \"auto\"))");
    let prefix =
        env::var("LCGF_PREFIX").expect("set LCGF_PREFIX to an installed `zig build abi` prefix");
    let features = env::var("CARGO_CFG_TARGET_FEATURE").unwrap_or_default();
    let auto = env::var_os("CARGO_FEATURE_LANES_AUTO").is_some();
    let lanes = env::var("LCGF_LANES").unwrap_or_else(|_| {
        if auto {
            "auto".into()
        } else if features.split(',').any(|f| f == "avx") {
            "8".into()
        } else {
            "4".into()
        }
    });
    // Relink when the archive is rebuilt, not only when the variables change.
    let lib = if lanes == "auto" {
        "lcgf_auto".to_string()
    } else {
        format!("lcgf_l{lanes}")
    };
    println!("cargo::rerun-if-changed={prefix}/lib/lib{lib}.a");
    println!("cargo::rustc-link-search=native={prefix}/lib");
    println!("cargo::rustc-link-lib=static={lib}");
    println!("cargo::rustc-cfg=lcgf_lanes=\"{lanes}\"");
}
