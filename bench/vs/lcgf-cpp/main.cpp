// The scenes of bench/scenes/ on LCGF from C++: lcgf/runtime.hpp over the prebuilt liblcgf, no
// Zig compiler. The driver is harness.h's; the frame is bench/vs/lcgf/main.zig's, built through
// the C seam (bindings/cpp/scenes/scenes.hpp, which bindings/check/run.sh holds byte-identical to
// the Zig scenes). Beside vs-lcgf it shows what a builder call costs across the seam.
#include <sys/mman.h>

#include <optional>

#include "../harness.h"
#include "../../../bindings/cpp/scenes/scenes.hpp"

namespace {
std::optional<lcgf::Context> ctx;
lcgf::Input in;

std::uint64_t frame(int scene, std::uint32_t k) {
    const auto s = scenes::Scene(scene);
    if (k == 0) {
        // Mapped on first use, as vs-lcgf maps its buffer: pages never touched stay unresident.
        const lcgf_limits l = scenes::limits(s);
        const std::size_t bytes = lcgf::Context::Bytes(l);
        void* p = mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        ctx.emplace(std::span<std::byte>{static_cast<std::byte*>(p), bytes}, l);
    }
    scenes::input(s, in, k);
    if (!scenes::every(s) && !ctx->NeedsFrame(in)) return 0;
    lcgf::Frame f = ctx->Begin(in);
    scenes::build(s, f, ctx->theme());
    const lcgf::DrawList& d = ctx->End();
    return d.command_count() + d.quads().size();
}
} // namespace

static std::uint64_t vs_frame(int scene, std::uint32_t k) { return frame(scene, k); }
static void vs_idle(void) { vs_block_on_stdin(); }

int main(int argc, char** argv) { return vs_main(argc, argv, "lcgf-cpp"); }
