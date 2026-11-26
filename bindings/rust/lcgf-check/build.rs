//! Links the command recorders (bindings/check/record.c and, with `d3d12`, d3d12_record.c,
//! installed by `zig build abi`) for lcgf-gpu-check and lcgf-d3d12-check, and builds the static
//! UIs' frames for lcgf-ct-check.
fn main() {
    // The specs are where lcgf-ct-check's include_ui! finds them (LCGF_SPECS); builds of the
    // other checks (the Metal ones) do not set it, and need no static UI.
    println!("cargo::rerun-if-env-changed=LCGF_SPECS");
    if std::env::var_os("LCGF_SPECS").is_some() {
        for ui in [
            "mixer", "card", "settings", "badge", "dash", "todo", "feed", "controls", "palette",
            "meter",
        ] {
            lcgf_build::static_ui(&format!("static/{ui}.zon"));
        }
        lcgf_build::static_ui("../../../tools/lcgf-gen/markup/testdata/seam/volume.html");
    }
    let prefix = std::env::var("LCGF_PREFIX").expect("LCGF_PREFIX");
    println!("cargo::rerun-if-env-changed=LCGF_PREFIX");
    println!("cargo::rustc-link-search=native={prefix}/lib");
    println!("cargo::rustc-link-lib=static=lcgf_record");
    // The recording Direct3D 12 (bindings/check/d3d12_record.c), for lcgf-d3d12-check.
    if std::env::var_os("CARGO_FEATURE_D3D12").is_some() {
        println!("cargo::rustc-link-lib=static=lcgf_d3d12_record");
    }
}
