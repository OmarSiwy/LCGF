// Clay emits its positioned rectangles. Paint each returned command into the XImage.
#define CLAY_IMPLEMENTATION
#include "clay.h"
#include "window.h"
#include <stdlib.h>
#include <stdio.h>

static void fail(Clay_ErrorData error) {
    fprintf(stderr, "%.*s\n", error.errorText.length, error.errorText.chars);
    exit(1);
}

int main(void) {
    uint32_t n = Clay_MinMemorySize();
    Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(n, malloc(n)), (Clay_Dimensions){800,600}, (Clay_ErrorHandler){fail, NULL});
    resize_open("resize-clay");
    int w, h;
    while (resize_next(&w, &h)) {
        Clay_SetLayoutDimensions((Clay_Dimensions){w, h});
        Clay_BeginLayout();
        Clay_Color bg = w % 4 == 0 ? (Clay_Color){34,51,68,255} : (Clay_Color){81,98,115,255};
        CLAY({.layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}, .childAlignment = {CLAY_ALIGN_X_CENTER, CLAY_ALIGN_Y_CENTER}}, .backgroundColor = bg}) {
            CLAY({.layout = {.sizing = {CLAY_SIZING_FIXED(64), CLAY_SIZING_FIXED(64)}}, .backgroundColor = {230,126,40,255}}) {}
        }
        Clay_RenderCommandArray list = Clay_EndLayout();
        for (int i = 0; i < list.length; ++i) {
            Clay_RenderCommand *cmd = Clay_RenderCommandArray_Get(&list, i);
            if (cmd->commandType != CLAY_RENDER_COMMAND_TYPE_RECTANGLE) abort();
            Clay_BoundingBox b = cmd->boundingBox;
            Clay_Color c = cmd->renderData.rectangle.backgroundColor;
            resize_rect(b.x, b.y, b.width, b.height, ((uint32_t)c.r << 16) | ((uint32_t)c.g << 8) | (uint32_t)c.b);
        }
        resize_present();
    }
}
