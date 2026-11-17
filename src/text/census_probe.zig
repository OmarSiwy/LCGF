//! Branch-census probe for the text passes (raster, atlas, SDF, caret); see src/census_probes.zig.
const lcgf = @import("lcgf");

export fn p_raster_coverage(acc: [*]const f32, out: [*]u8, n: usize) void {
    lcgf.raster.coverage(acc[0..lcgf.simd.padded(n)], out[0..lcgf.simd.padded(n)], n);
}
export fn p_gamma_apply(g: *const lcgf.raster_gamma.Gamma, lum: u8, cov: [*]const u8, out: [*]u8, n: usize) void {
    g.apply(lum, cov[0..n], out[0..n]);
}
export fn p_atlas_evict(c: *lcgf.raster_atlas.Cache, keep_from: u32) void {
    c.evict(keep_from);
}
export fn p_sdf_distances(segs: *const lcgf.raster.Segments, n: usize, w: u32, h: u32, img: [*]u8, len: usize) void {
    lcgf.raster_sdf.distances(segs, n, w, h, img[0..len], 31.75);
}
export fn p_cluster_hit(c: *const lcgf.shape_cluster.Carets, x: i32) u32 {
    return lcgf.shape_cluster.hit(c, x);
}
export fn p_cluster_caret_x(c: *const lcgf.shape_cluster.Carets, offset: u32) i32 {
    return lcgf.shape_cluster.caretX(c, offset);
}
