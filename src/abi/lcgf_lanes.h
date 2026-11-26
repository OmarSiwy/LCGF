/* lcgf_lanes.h: the lane-named frames, by hand (lcgf.h, generated, includes it). A prebuilt
 * liblcgf_l{4,8,16}.a exports the frame for its own lane count; generated code names the one
 * its target flags pick (LCGF_FRAME, LCGF_CT_FRAME), so there is no dispatch. liblcgf_auto.a
 * (LCGF_LANES 0) picks the width from the CPU at the first call of any function: 8 with AVX2
 * (AVX-512 too) and 4 without; LCGF_FORCE_LANES=4, 8 or 16 forces one the CPU can run.
 * lcgf_auto_lanes() says which, or 0 before the first call. */
#ifndef LCGF_LANES_H
#define LCGF_LANES_H
#ifdef __cplusplus
extern "C" {
#endif

void lcgf_frame_u32_f32_l4(void *ui, void *state, const lcgf_input *in, lcgf_ui_output *out);
void lcgf_frame_u32_f32_l8(void *ui, void *state, const lcgf_input *in, lcgf_ui_output *out);
void lcgf_frame_u32_f32_l16(void *ui, void *state, const lcgf_input *in, lcgf_ui_output *out);
void lcgf_frame_u32_f32_auto(void *ui, void *state, const lcgf_input *in, lcgf_ui_output *out);
void lcgf_ct_frame_u32_f32_l4(void *ui, const void *state, float width, float height, lcgf_draw *out);
void lcgf_ct_frame_u32_f32_l8(void *ui, const void *state, float width, float height, lcgf_draw *out);
void lcgf_ct_frame_u32_f32_l16(void *ui, const void *state, float width, float height, lcgf_draw *out);
void lcgf_ct_frame_u32_f32_auto(void *ui, const void *state, float width, float height, lcgf_draw *out);
uint32_t lcgf_auto_lanes(void);

#ifndef LCGF_LANES
#if defined(__AVX512F__) && defined(LCGF_WANT_16_LANES)
#define LCGF_LANES 16
#elif defined(__AVX2__) || defined(__AVX__)
#define LCGF_LANES 8
#else
#define LCGF_LANES 4
#endif
#endif
#define LCGF_CAT_(a, b) a##b
#define LCGF_CAT(a, b) LCGF_CAT_(a, b)
#if LCGF_LANES == 0
#define LCGF_FRAME lcgf_frame_u32_f32_auto
#define LCGF_CT_FRAME lcgf_ct_frame_u32_f32_auto
#else
#define LCGF_FRAME LCGF_CAT(lcgf_frame_u32_f32_l, LCGF_LANES)
#define LCGF_CT_FRAME LCGF_CAT(lcgf_ct_frame_u32_f32_l, LCGF_LANES)
#endif

#ifdef __cplusplus
}
#endif
#endif
