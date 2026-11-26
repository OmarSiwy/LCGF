/* The Direct3D 12 back end translated for Linux, for the bindings' recorder gate only
 * (bindings/check/d3d12_record.c): DirectX-Headers' d3d12.h through its WSL adapter, in place of
 * Zig's MinGW-w64 headers (c.h), which refuse a non-Windows target. The projection
 * (src/render/d3d12/gpu.zig) then builds for x86-64 Linux and talks to the recorder's objects.
 * d3dcompiler.h is not part of DirectX-Headers: what the back end calls of it is declared here. */
#include <wsl/winadapter.h>
#include <directx/d3d12.h>

#define D3DCOMPILE_OPTIMIZATION_LEVEL3 (1 << 15)
HRESULT WINAPI D3DCompile(LPCVOID src, SIZE_T len, LPCSTR name, const void *defines, void *include, LPCSTR entry, LPCSTR target, UINT flags1,
                          UINT flags2, ID3DBlob **code, ID3DBlob **errors);
