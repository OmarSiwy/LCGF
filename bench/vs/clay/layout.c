// Clay's side of the "layout alone" wasm size (src/render/web/layout.zig is LCGR's): the same
// three-box frame (a toolbar, a sidebar and a filling view), laid out into render commands, one
// exported function returning the view's width. Built like LCGR's module (wasm32-freestanding,
// ReleaseSmall, no entry, only that export), not with CLAY_WASM, which exports Clay's whole API.
#define CLAY_IMPLEMENTATION
#include "clay.h"

static char arena[1 << 20];
static void on_error(Clay_ErrorData e) { (void)e; }

__attribute__((export_name("clay_layout"))) float clay_layout(float width, float height) {
    Clay_SetMaxElementCount(64);
    Clay_SetMaxMeasureTextCacheWordCount(64);
    uint32_t bytes = Clay_MinMemorySize();
    if (bytes > sizeof arena) return 0;
    Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(bytes, arena), (Clay_Dimensions){width, height},
                    (Clay_ErrorHandler){on_error, 0});
    Clay_BeginLayout();
    CLAY({.id = CLAY_ID("root"), .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}, .layoutDirection = CLAY_TOP_TO_BOTTOM}}) {
        CLAY({.id = CLAY_ID("toolbar"), .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(50)}}, .backgroundColor = {40, 40, 48, 255}}) {}
        CLAY({.id = CLAY_ID("body"), .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}}}) {
            CLAY({.id = CLAY_ID("sidebar"), .layout = {.sizing = {CLAY_SIZING_FIXED(160), CLAY_SIZING_GROW(0)}}, .backgroundColor = {30, 30, 36, 255}}) {}
            CLAY({.id = CLAY_ID("view"), .layout = {.sizing = {CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0)}}}) {}
        }
    }
    Clay_EndLayout();
    return Clay_GetElementData(CLAY_ID("view")).boundingBox.width;
}
