//! Branch-census probe for the text passes (raster, atlas, SDF, caret); see src/census_probes.zig.
const lcgr = @import("lcgr");

export fn p_raster_coverage(acc: [*]const f32, out: [*]u8, n: usize) void {
    lcgr.raster.coverage(acc[0..lcgr.simd.padded(n)], out[0..lcgr.simd.padded(n)], n);
}
export fn p_gamma_apply(g: *const lcgr.raster_gamma.Gamma, lum: u8, cov: [*]const u8, out: [*]u8, n: usize) void {
    g.apply(lum, cov[0..n], out[0..n]);
}
export fn p_atlas_evict(c: *lcgr.raster_atlas.Cache, keep_from: u32) void {
    c.evict(keep_from);
}
export fn p_sdf_distances(segs: *const lcgr.raster.Segments, n: usize, w: u32, h: u32, img: [*]u8, len: usize) void {
    lcgr.raster_sdf.distances(segs, n, w, h, img[0..len], 31.75);
}
export fn p_cluster_hit(c: *const lcgr.shape_cluster.Carets, x: i32) u32 {
    return lcgr.shape_cluster.hit(c, x);
}
export fn p_cluster_caret_x(c: *const lcgr.shape_cluster.Carets, offset: u32) i32 {
    return lcgr.shape_cluster.caretX(c, offset);
}
