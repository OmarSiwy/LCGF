// Dear ImGui lays out a full-window scene and produces indexed triangles. Cairo
// paints those triangles; this opaque untextured scene only uses the white texel.
#include "imgui.h"
#include "imgui_impl_null.h"
#include "window.h"
#include <cstdlib>

int main() {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    ImGui_ImplNullRender_Init(); // font atlas lifecycle; the mesh below is rendered by Cairo
    ImGuiStyle &style = ImGui::GetStyle();
    style.AntiAliasedFill = false;
    style.WindowBorderSize = style.WindowRounding = 0;
    style.WindowPadding = ImVec2(0, 0);
    resize_open("resize-imgui");
    int w, h;
    while (resize_next(&w, &h)) {
        io.DisplaySize = ImVec2(w, h);
        ImGui_ImplNullRender_NewFrame();
        ImGui::NewFrame();
        ImGui::SetNextWindowPos(ImVec2(0, 0));
        ImGui::SetNextWindowSize(io.DisplaySize);
        ImGui::PushStyleColor(ImGuiCol_WindowBg, w % 4 == 0 ? IM_COL32(34,51,68,255) : IM_COL32(81,98,115,255));
        ImGui::Begin("scene", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoInputs | ImGuiWindowFlags_NoSavedSettings);
        auto avail = ImGui::GetContentRegionAvail();
        ImGui::SetCursorPos(ImVec2((avail.x - 64) / 2, (avail.y - 64) / 2));
        ImGui::InvisibleButton("block", ImVec2(64,64));
        ImGui::GetWindowDrawList()->AddRectFilled(ImGui::GetItemRectMin(), ImGui::GetItemRectMax(), IM_COL32(230,126,40,255));
        ImGui::End();
        ImGui::PopStyleColor();
        ImGui::Render();
        auto *draw = ImGui::GetDrawData();
        for (auto *list : draw->CmdLists) {
            for (const auto &cmd : list->CmdBuffer) {
                if (cmd.UserCallback) abort();
                auto r = cmd.ClipRect;
                resize_clip((int)r.x, (int)r.y, (int)(r.z-r.x), (int)(r.w-r.y));
                const auto *indices = list->IdxBuffer.Data + cmd.IdxOffset;
                const auto *vertices = list->VtxBuffer.Data + cmd.VtxOffset;
                for (unsigned i = 0; i < cmd.ElemCount; i += 3) {
                    const auto &a = vertices[indices[i]], &b = vertices[indices[i+1]], &c = vertices[indices[i+2]];
                    if (a.col != b.col || a.col != c.col) abort();
                    uint32_t rgb = ((a.col & 255) << 16) | (a.col & 0xff00) | ((a.col >> 16) & 255);
                    resize_tri(a.pos.x, a.pos.y, b.pos.x, b.pos.y, c.pos.x, c.pos.y, rgb);
                }
            }
        }
        ImGui_ImplNullRender_RenderDrawData(draw);
        resize_present();
    }
}
