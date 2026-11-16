// The scenes of bench/scenes/ on Dear ImGui (https://github.com/ocornut/imgui), for the comparison
// of docs/perf/vs.md. A frame is input, ImGui::NewFrame, the widgets, and ImGui::Render, which
// fills ImDrawData (vertex and index buffers per draw command). That matches what tools/bench times
// as `frame` (build, layout, paint into a draw list); neither rasterises. The renderer is ImGui's
// own null back end (backends/imgui_impl_null.cpp): it accepts the font atlas and draws nothing.
// Widgets are ImGui's own (InputText, Checkbox, SliderFloat, Button, TextWrapped, a list clipper);
// text is ImGui's default font (ProggyClean, rasterised into the atlas on first use) at 14 px and
// 20 px; springs come from bench/vs/harness.h, since ImGui has no animation API.
#include "imgui.h"
#include "imgui_impl_null.h"
#include "../harness.h"

static const ImU32 panel = IM_COL32(30, 31, 36, 255), control = IM_COL32(58, 60, 70, 255),
                   accent = IM_COL32(90, 140, 255, 255);
static const ImGuiWindowFlags fixed = ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                                      ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus;

static char fields[21][32];
static bool checks[21];
static float values[21];

static void form() {
    ImGui::PushFont(nullptr, 20);
    ImGui::TextUnformatted("Account settings");
    ImGui::PopFont();
    ImGui::Separator();
    for (int r = 0; r < 21; r++) {
        ImGui::PushID(r);
        ImGui::AlignTextToFramePadding();
        ImGui::TextUnformatted(vs_form_names[r]);
        ImGui::SameLine(12 + 90 + 6);
        ImGui::SetNextItemWidth(220);
        ImGui::InputText("##field", fields[r], sizeof fields[r]);
        ImGui::SameLine();
        ImGui::Checkbox("On", &checks[r]);
        ImGui::SameLine();
        ImGui::SetNextItemWidth(-1);
        ImGui::SliderFloat("##value", &values[r], 0, 1);
        ImGui::PopID();
    }
    float w = ImGui::CalcTextSize("CancelResetSave").x + 6 * ImGui::GetStyle().FramePadding.x + 2 * 6;
    ImGui::SetCursorPosX(ImGui::GetContentRegionAvail().x + ImGui::GetCursorPosX() - w);
    ImGui::Button("Cancel");
    ImGui::SameLine();
    ImGui::Button("Reset");
    ImGui::SameLine();
    ImGui::Button("Save");
}

static void list(uint32_t scroll) {
    ImGui::SetScrollY((float)scroll);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float width = ImGui::GetContentRegionAvail().x;
    ImGuiListClipper clip;
    clip.Begin(100000, 24);
    while (clip.Step()) {
        for (int r = clip.DisplayStart; r < clip.DisplayEnd; r++) {
            ImVec2 p = ImGui::GetCursorScreenPos();
            dl->AddRectFilled(p, ImVec2(p.x + width, p.y + 24), r % 2 ? control : panel);
            ImGui::SetCursorScreenPos(ImVec2(p.x + 8, p.y + (24 - ImGui::GetTextLineHeight()) / 2));
            ImGui::Text("Row %d", r);
            ImGui::SameLine();
            ImGui::TextUnformatted(vs_list_names[r % 7]);
            ImGui::SameLine();
            ImVec2 q = ImGui::GetCursorScreenPos();
            dl->AddRectFilled(q, ImVec2(q.x + 12, q.y + 12), accent);
            ImGui::Dummy(ImVec2(12, 12));
            ImGui::SetCursorScreenPos(ImVec2(p.x, p.y + 24));
            ImGui::Dummy(ImVec2(0, 0));
        }
    }
}

static void prose() {
    ImGui::BeginChild("sidebar", ImVec2(160, 0));
    for (int i = 0; i < 120; i++) ImGui::Text("Chapter %d", i + 1);
    ImGui::EndChild();
    ImGui::SameLine(0, 16);
    ImGui::BeginChild("main");
    for (int s = 0; s < 12; s++) {
        ImGui::PushFont(nullptr, 20);
        ImGui::Text("Section %d", s + 1);
        ImGui::PopFont();
        for (int p = 0; p < 4; p++) ImGui::TextWrapped("%s", vs_prose[(s + p) % 4]);
    }
    ImGui::EndChild();
}

static VsSprings springs_state;
static void springs(uint32_t tick, float dt) {
    vs_springs_step(&springs_state, tick, dt);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    for (int r = 0; r < 40; r++) {
        for (int c = 0; c < 25; c++) {
            if (c) ImGui::SameLine(0, 2);
            ImVec2 p = ImGui::GetCursorScreenPos();
            float w = springs_state.x[r * 25 + c];
            dl->AddRectFilled(p, ImVec2(p.x + w, p.y + 16), accent);
            ImGui::Dummy(ImVec2(w, 16));
        }
    }
}

static uint64_t vs_frame(int scene, uint32_t k) {
    VsInput in = vs_input(scene, k);
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(in.w, in.h);
    io.DeltaTime = in.dt;
    io.AddMousePosEvent(in.px, in.py);
    ImGui_ImplNullRender_NewFrame();
    ImGui::NewFrame();
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(io.DisplaySize);
    bool is_list = scene == VS_LIST;
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(is_list ? 0 : (scene == VS_SPRINGS ? 8 : 12), is_list ? 0 : 12));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(6, scene == VS_SPRINGS ? 2 : (is_list ? 0 : 4)));
    ImGui::Begin("scene", nullptr, fixed);
    switch (scene) {
    case VS_FORM:
    case VS_IDLE: form(); break;
    case VS_LIST: list(in.scroll); break;
    case VS_TEXT:
    case VS_RESIZE: prose(); break;
    case VS_SPRINGS: springs(in.tick, in.dt); break;
    }
    ImGui::End();
    ImGui::PopStyleVar(2);
    ImGui::Render();
    ImDrawData *dd = ImGui::GetDrawData();
    ImGui_ImplNullRender_RenderDrawData(dd);
    return (uint64_t)dd->TotalVtxCount;
}

// Dear ImGui has no event loop or idle mode: the application decides when to build a frame
// (https://github.com/ocornut/imgui/wiki/Implementing-Power-Save%2C-aka-Idling-outside-of-ImGui).
// Here the host sleeps until input arrives, as tools/bench does.
static void vs_idle(void) { vs_block_on_stdin(); }

int main(int argc, char **argv) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    ImGui_ImplNullRender_Init();
    ImGui::GetStyle().FontSizeBase = 14;
    for (float &v : values) v = 0.5f;
    for (int r = 0; r < 21; r++) snprintf(fields[r], sizeof fields[r], "%s", vs_form_names[r]);
    return vs_main(argc, argv, "dear-imgui-" IMGUI_VERSION);
}
