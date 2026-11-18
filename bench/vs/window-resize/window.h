// Shared X11 software presenter for the comparison frameworks without an X11 window.
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

void resize_open(const char *title);
// Wait for a configure or expose. The XRGB framebuffer is valid until the next call.
uint32_t *resize_next(int *width, int *height);
void resize_present(void);
// Cairo image-surface fills for the frameworks that produce geometry.
void resize_rect(float x, float y, float w, float h, uint32_t rgb);
void resize_tri(float ax, float ay, float bx, float by, float cx, float cy, uint32_t rgb);
void resize_clip(int x, int y, int w, int h);

#ifdef __cplusplus
}
#endif
