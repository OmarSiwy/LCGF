// A recording Direct3D 12, for the bindings' D3D12 gate (bindings/check/run.sh): fake COM objects
// built on DirectX-Headers' C interfaces, whose methods log their arguments (every field of the
// structs they take) instead of doing anything. The Zig projection (src/render/d3d12/gpu.zig),
// lcgf/gpu.hpp with LCGF_GPU_D3D12 and lcgf::gpu with `d3d12` make the same resources, pipelines
// and frame on them; run.sh requires their logs to be equal.
//
// A vtable slot nobody implemented here stops the program, so a projection that starts calling
// a new method fails until the method is logged. D3DCompile and D3D12SerializeRootSignature are
// here too: the first logs the HLSL's length and FNV-1a hash, the second the whole root
// signature, and each returns a blob of that hash.
//
// Struct-returning methods (a descriptor heap's start, a resource's description) take the
// Windows ABI's form, a result pointer after `this`, which the three projections use on every
// target. (WSL's d3d12 returns them by value: the projections are for Windows.)
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <wsl/winadapter.h>
#include <directx/d3d12.h>

typedef struct Obj {
    const void* lpVtbl;
    int id;
    // Resources: their description and, in an UPLOAD heap, memory.
    D3D12_RESOURCE_DESC desc;
    unsigned char* mem;
    // Descriptor heaps: their type. Blobs: their bytes.
    D3D12_DESCRIPTOR_HEAP_TYPE heap;
    uint32_t blob[4];
} Obj;

static char* log_buf;
static size_t log_len, log_cap;
static int next_id = 1;

static void out(const char* fmt, ...) {
    char tmp[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof tmp) n = sizeof tmp - 1;
    if (log_len + (size_t)n + 1 > log_cap) {
        log_cap = (log_cap + (size_t)n + 1) * 2;
        log_buf = realloc(log_buf, log_cap);
    }
    memcpy(log_buf + log_len, tmp, (size_t)n);
    log_len += (size_t)n;
}

const char* lcgf_d3d12_record_log(size_t* len) {
    *len = log_len;
    return log_buf ? log_buf : "";
}

static uint32_t fnv(const void* p, size_t n) {
    const unsigned char* s = p;
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < n; ++i) h = (h ^ s[i]) * 0x01000193u;
    return h;
}

static int idOf(const void* o) { return o ? ((const Obj*)o)->id : 0; }
static void obj(const char* name, const void* o) {
    if (o) out(" %s=#%d", name, idOf(o));
    else out(" %s=null", name);
}
static void bytes(const void* p, size_t n) {
    const unsigned char* b = p;
    out(" [");
    for (size_t i = 0; i < n; ++i) out("%02x", b[i]);
    out("]");
}

// Every slot starts here; the ones this file implements are written over it.
static void unimplemented(void) {
    fprintf(stderr, "d3d12_record: a COM method this recorder does not implement was called; add it to bindings/check/d3d12_record.c\n");
    abort();
}
static void fill(void* vtbl, size_t size) {
    void (**slots)(void) = vtbl;
    for (size_t i = 0; i < size / sizeof(void*); ++i) slots[i] = unimplemented;
}

static Obj* make(const void* vtbl) {
    Obj* o = calloc(1, sizeof *o);
    o->lpVtbl = vtbl;
    o->id = next_id++;
    return o;
}

static ULONG STDMETHODCALLTYPE Release(void* This) {
    out("#%d Release\n", idOf(This));
    return 0;
}

// ---- blobs ----------------------------------------------------------------------------------

static ID3D10BlobVtbl blob_vtbl;
static LPVOID STDMETHODCALLTYPE BlobPointer(ID3DBlob* This) { return ((Obj*)This)->blob; }
static SIZE_T STDMETHODCALLTYPE BlobSize(ID3DBlob* This) {
    (void)This;
    return sizeof(((Obj*)0)->blob);
}
static Obj* makeBlob(uint32_t hash) {
    Obj* b = make(&blob_vtbl);
    b->blob[0] = hash;
    b->blob[1] = 0x4c434746; // "LCGF"
    return b;
}

// ---- resources and heaps --------------------------------------------------------------------

static ID3D12ResourceVtbl resource_vtbl;
static ID3D12DescriptorHeapVtbl heap_vtbl;
static ID3D12RootSignatureVtbl root_vtbl;
static ID3D12PipelineStateVtbl pso_vtbl;

static HRESULT STDMETHODCALLTYPE Map(ID3D12Resource* This, UINT sub, const D3D12_RANGE* range, void** data) {
    Obj* r = (Obj*)This;
    out("#%d Map %u", r->id, sub);
    if (range) out(" range={%llu %llu}", (unsigned long long)range->Begin, (unsigned long long)range->End);
    else out(" range=null");
    out("\n");
    if (!r->mem) r->mem = calloc(1, (size_t)r->desc.Width + 1);
    *data = r->mem;
    return S_OK;
}
static void STDMETHODCALLTYPE Unmap(ID3D12Resource* This, UINT sub, const D3D12_RANGE* range) {
    (void)range;
    out("#%d Unmap %u\n", idOf(This), sub);
}
static D3D12_RESOURCE_DESC* STDMETHODCALLTYPE GetDesc(ID3D12Resource* This, D3D12_RESOURCE_DESC* ret) {
    *ret = ((Obj*)This)->desc;
    return ret;
}
static D3D12_GPU_VIRTUAL_ADDRESS STDMETHODCALLTYPE GetGPUVirtualAddress(ID3D12Resource* This) {
    return 0x100000000ull + (uint64_t)idOf(This) * 0x10000ull;
}
static D3D12_CPU_DESCRIPTOR_HANDLE* STDMETHODCALLTYPE HeapCpu(ID3D12DescriptorHeap* This, D3D12_CPU_DESCRIPTOR_HANDLE* ret) {
    ret->ptr = (SIZE_T)idOf(This) << 20;
    return ret;
}
static D3D12_GPU_DESCRIPTOR_HANDLE* STDMETHODCALLTYPE HeapGpu(ID3D12DescriptorHeap* This, D3D12_GPU_DESCRIPTOR_HANDLE* ret) {
    ret->ptr = ((UINT64)idOf(This) << 20) | (1ull << 40);
    return ret;
}

// ---- the device -----------------------------------------------------------------------------

static void resourceDesc(const D3D12_RESOURCE_DESC* d) {
    out(" desc={dim %d align %llu %llux%ux%u mips %u fmt %d samples %u/%u layout %d flags 0x%x}", d->Dimension, (unsigned long long)d->Alignment,
        (unsigned long long)d->Width, d->Height, d->DepthOrArraySize, d->MipLevels, d->Format, d->SampleDesc.Count, d->SampleDesc.Quality, d->Layout,
        d->Flags);
}

static HRESULT STDMETHODCALLTYPE CreateCommittedResource(ID3D12Device* This, const D3D12_HEAP_PROPERTIES* heap, D3D12_HEAP_FLAGS flags,
                                                         const D3D12_RESOURCE_DESC* desc, D3D12_RESOURCE_STATES state, const D3D12_CLEAR_VALUE* clear,
                                                         REFIID riid, void** ppv) {
    (void)riid;
    Obj* r = make(&resource_vtbl);
    r->desc = *desc;
    out("#%d CreateCommittedResource heap={type %d page %d pool %d nodes %u %u} flags 0x%x", idOf(This), heap->Type, heap->CPUPageProperty,
        heap->MemoryPoolPreference, heap->CreationNodeMask, heap->VisibleNodeMask, flags);
    resourceDesc(desc);
    out(" state 0x%x clear=%s -> #%d\n", state, clear ? "set" : "null", r->id);
    *ppv = r;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE CreateDescriptorHeap(ID3D12Device* This, const D3D12_DESCRIPTOR_HEAP_DESC* d, REFIID riid, void** ppv) {
    (void)riid;
    Obj* h = make(&heap_vtbl);
    h->heap = d->Type;
    out("#%d CreateDescriptorHeap type %d n %u flags 0x%x node %u -> #%d\n", idOf(This), d->Type, d->NumDescriptors, d->Flags, d->NodeMask, h->id);
    *ppv = h;
    return S_OK;
}

static UINT STDMETHODCALLTYPE GetDescriptorHandleIncrementSize(ID3D12Device* This, D3D12_DESCRIPTOR_HEAP_TYPE type) {
    (void)This;
    static const UINT sizes[] = {32, 16, 8, 8};
    return sizes[type];
}

static HRESULT STDMETHODCALLTYPE CreateRootSignature(ID3D12Device* This, UINT node, const void* blob, SIZE_T size, REFIID riid, void** ppv) {
    (void)riid;
    Obj* r = make(&root_vtbl);
    out("#%d CreateRootSignature node %u blob %08x size %zu -> #%d\n", idOf(This), node, fnv(blob, size), (size_t)size, r->id);
    *ppv = r;
    return S_OK;
}

static void shaderCode(const char* name, D3D12_SHADER_BYTECODE b) {
    if (b.pShaderBytecode) out(" %s=%08x/%zu", name, fnv(b.pShaderBytecode, b.BytecodeLength), (size_t)b.BytecodeLength);
    else out(" %s=null", name);
}

static HRESULT STDMETHODCALLTYPE CreateGraphicsPipelineState(ID3D12Device* This, const D3D12_GRAPHICS_PIPELINE_STATE_DESC* d, REFIID riid, void** ppv) {
    (void)riid;
    Obj* p = make(&pso_vtbl);
    out("#%d CreateGraphicsPipelineState", idOf(This));
    obj("root", d->pRootSignature);
    shaderCode("VS", d->VS);
    shaderCode("PS", d->PS);
    shaderCode("DS", d->DS);
    shaderCode("HS", d->HS);
    shaderCode("GS", d->GS);
    out(" so=%u blend={a2c %d independent %d", d->StreamOutput.NumEntries, d->BlendState.AlphaToCoverageEnable, d->BlendState.IndependentBlendEnable);
    for (UINT i = 0; i < 8; ++i) {
        const D3D12_RENDER_TARGET_BLEND_DESC* t = &d->BlendState.RenderTarget[i];
        out(" [%d %d %d %d %d %d %d %d %d %d 0x%x]", t->BlendEnable, t->LogicOpEnable, t->SrcBlend, t->DestBlend, t->BlendOp, t->SrcBlendAlpha,
            t->DestBlendAlpha, t->BlendOpAlpha, t->LogicOp, 0, t->RenderTargetWriteMask);
    }
    const D3D12_RASTERIZER_DESC* r = &d->RasterizerState;
    out("} mask 0x%x raster={fill %d cull %d ccw %d bias %d %g %g clip %d ms %d aa %d forced %u cons %d}", d->SampleMask, r->FillMode, r->CullMode,
        r->FrontCounterClockwise, r->DepthBias, (double)r->DepthBiasClamp, (double)r->SlopeScaledDepthBias, r->DepthClipEnable, r->MultisampleEnable,
        r->AntialiasedLineEnable, r->ForcedSampleCount, r->ConservativeRaster);
    const D3D12_DEPTH_STENCIL_DESC* ds = &d->DepthStencilState;
    out(" depth={%d %d %d stencil %d}", ds->DepthEnable, ds->DepthWriteMask, ds->DepthFunc, ds->StencilEnable);
    out(" input={");
    for (UINT i = 0; i < d->InputLayout.NumElements; ++i) {
        const D3D12_INPUT_ELEMENT_DESC* e = &d->InputLayout.pInputElementDescs[i];
        out("%s%s%u fmt %d slot %u off %u class %d step %u", i ? ", " : "", e->SemanticName, e->SemanticIndex, e->Format, e->InputSlot, e->AlignedByteOffset,
            e->InputSlotClass, e->InstanceDataStepRate);
    }
    out("} cut %d topo %d rts %u [", d->IBStripCutValue, d->PrimitiveTopologyType, d->NumRenderTargets);
    for (UINT i = 0; i < 8; ++i) out(i ? " %d" : "%d", d->RTVFormats[i]);
    out("] dsv %d samples %u/%u node %u flags 0x%x -> #%d\n", d->DSVFormat, d->SampleDesc.Count, d->SampleDesc.Quality, d->NodeMask, d->Flags, p->id);
    *ppv = p;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE CreateComputePipelineState(ID3D12Device* This, const D3D12_COMPUTE_PIPELINE_STATE_DESC* d, REFIID riid, void** ppv) {
    (void)riid;
    Obj* p = make(&pso_vtbl);
    out("#%d CreateComputePipelineState", idOf(This));
    obj("root", d->pRootSignature);
    shaderCode("CS", d->CS);
    out(" node %u flags 0x%x -> #%d\n", d->NodeMask, d->Flags, p->id);
    *ppv = p;
    return S_OK;
}

static void STDMETHODCALLTYPE CreateConstantBufferView(ID3D12Device* This, const D3D12_CONSTANT_BUFFER_VIEW_DESC* d, D3D12_CPU_DESCRIPTOR_HANDLE at) {
    out("#%d CreateConstantBufferView {0x%llx %u} at 0x%zx\n", idOf(This), (unsigned long long)d->BufferLocation, d->SizeInBytes, (size_t)at.ptr);
}

static void STDMETHODCALLTYPE CreateShaderResourceView(ID3D12Device* This, ID3D12Resource* res, const D3D12_SHADER_RESOURCE_VIEW_DESC* d,
                                                       D3D12_CPU_DESCRIPTOR_HANDLE at) {
    out("#%d CreateShaderResourceView", idOf(This));
    obj("res", res);
    if (d)
        out(" {fmt %d dim %d map 0x%x buffer %llu %u %u 0x%x}", d->Format, d->ViewDimension, d->Shader4ComponentMapping, (unsigned long long)d->Buffer.FirstElement,
            d->Buffer.NumElements, d->Buffer.StructureByteStride, d->Buffer.Flags);
    else out(" null");
    out(" at 0x%zx\n", (size_t)at.ptr);
}

static void STDMETHODCALLTYPE CreateUnorderedAccessView(ID3D12Device* This, ID3D12Resource* res, ID3D12Resource* counter,
                                                        const D3D12_UNORDERED_ACCESS_VIEW_DESC* d, D3D12_CPU_DESCRIPTOR_HANDLE at) {
    out("#%d CreateUnorderedAccessView", idOf(This));
    obj("res", res);
    obj("counter", counter);
    if (d)
        out(" {fmt %d dim %d buffer %llu %u %u %llu 0x%x}", d->Format, d->ViewDimension, (unsigned long long)d->Buffer.FirstElement, d->Buffer.NumElements,
            d->Buffer.StructureByteStride, (unsigned long long)d->Buffer.CounterOffsetInBytes, d->Buffer.Flags);
    else out(" null");
    out(" at 0x%zx\n", (size_t)at.ptr);
}

static void STDMETHODCALLTYPE CreateRenderTargetView(ID3D12Device* This, ID3D12Resource* res, const D3D12_RENDER_TARGET_VIEW_DESC* d,
                                                     D3D12_CPU_DESCRIPTOR_HANDLE at) {
    out("#%d CreateRenderTargetView", idOf(This));
    obj("res", res);
    out(" %s at 0x%zx\n", d ? "desc" : "null", (size_t)at.ptr);
}

static void STDMETHODCALLTYPE CreateSampler(ID3D12Device* This, const D3D12_SAMPLER_DESC* d, D3D12_CPU_DESCRIPTOR_HANDLE at) {
    out("#%d CreateSampler {filter 0x%x address %d %d %d bias %g aniso %u cmp %d border %g %g %g %g lod %g %g} at 0x%zx\n", idOf(This), d->Filter,
        d->AddressU, d->AddressV, d->AddressW, (double)d->MipLODBias, d->MaxAnisotropy, d->ComparisonFunc, (double)d->BorderColor[0],
        (double)d->BorderColor[1], (double)d->BorderColor[2], (double)d->BorderColor[3], (double)d->MinLOD, (double)d->MaxLOD, (size_t)at.ptr);
}

static void STDMETHODCALLTYPE GetCopyableFootprints(ID3D12Device* This, const D3D12_RESOURCE_DESC* d, UINT first, UINT n, UINT64 base,
                                                    D3D12_PLACED_SUBRESOURCE_FOOTPRINT* layouts, UINT* rows, UINT64* row_sizes, UINT64* total) {
    out("#%d GetCopyableFootprints", idOf(This));
    resourceDesc(d);
    out(" %u %u %llu\n", first, n, (unsigned long long)base);
    // Four bytes a pixel (the formats the projections upload); rows padded to 256 bytes.
    const UINT64 row = d->Width * 4, pitch = (row + 255) & ~255ull;
    if (layouts) {
        layouts->Offset = base;
        layouts->Footprint.Format = d->Format;
        layouts->Footprint.Width = (UINT)d->Width;
        layouts->Footprint.Height = d->Height;
        layouts->Footprint.Depth = 1;
        layouts->Footprint.RowPitch = (UINT)pitch;
    }
    if (rows) *rows = d->Height;
    if (row_sizes) *row_sizes = row;
    if (total) *total = pitch * (d->Height - 1) + row;
}

// ---- the command list -----------------------------------------------------------------------

static void STDMETHODCALLTYPE CopyBufferRegion(ID3D12GraphicsCommandList* This, ID3D12Resource* dst, UINT64 dst_off, ID3D12Resource* src, UINT64 src_off,
                                               UINT64 n) {
    out("#%d CopyBufferRegion", idOf(This));
    obj("dst", dst);
    out(" %llu", (unsigned long long)dst_off);
    obj("src", src);
    out(" %llu %llu", (unsigned long long)src_off, (unsigned long long)n);
    const Obj* s = (const Obj*)src;
    if (s && s->mem && src_off + n <= s->desc.Width) bytes(s->mem + src_off, (size_t)n);
    out("\n");
}

static void location(const char* name, const D3D12_TEXTURE_COPY_LOCATION* l) {
    out(" %s={", name);
    obj("res", l->pResource);
    if (l->Type == D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX) {
        out(" sub %u}", l->SubresourceIndex);
    } else {
        const D3D12_PLACED_SUBRESOURCE_FOOTPRINT* f = &l->PlacedFootprint;
        out(" footprint %llu fmt %d %ux%ux%u pitch %u}", (unsigned long long)f->Offset, f->Footprint.Format, f->Footprint.Width, f->Footprint.Height,
            f->Footprint.Depth, f->Footprint.RowPitch);
    }
}

static void STDMETHODCALLTYPE CopyTextureRegion(ID3D12GraphicsCommandList* This, const D3D12_TEXTURE_COPY_LOCATION* dst, UINT x, UINT y, UINT z,
                                                const D3D12_TEXTURE_COPY_LOCATION* src, const D3D12_BOX* box) {
    out("#%d CopyTextureRegion", idOf(This));
    location("dst", dst);
    out(" %u %u %u", x, y, z);
    location("src", src);
    out(" box=%s\n", box ? "set" : "null");
}

static void STDMETHODCALLTYPE ResourceBarrier(ID3D12GraphicsCommandList* This, UINT n, const D3D12_RESOURCE_BARRIER* b) {
    out("#%d ResourceBarrier", idOf(This));
    for (UINT i = 0; i < n; ++i) {
        out(" {type %d flags %d", b[i].Type, b[i].Flags);
        if (b[i].Type == D3D12_RESOURCE_BARRIER_TYPE_TRANSITION) {
            obj("res", b[i].Transition.pResource);
            out(" sub 0x%x 0x%x->0x%x}", b[i].Transition.Subresource, b[i].Transition.StateBefore, b[i].Transition.StateAfter);
        } else if (b[i].Type == D3D12_RESOURCE_BARRIER_TYPE_UAV) {
            obj("res", b[i].UAV.pResource);
            out("}");
        } else {
            out("}");
        }
    }
    out("\n");
}

static void STDMETHODCALLTYPE IASetPrimitiveTopology(ID3D12GraphicsCommandList* This, D3D12_PRIMITIVE_TOPOLOGY t) {
    out("#%d IASetPrimitiveTopology %d\n", idOf(This), t);
}
static void STDMETHODCALLTYPE RSSetViewports(ID3D12GraphicsCommandList* This, UINT n, const D3D12_VIEWPORT* v) {
    out("#%d RSSetViewports", idOf(This));
    for (UINT i = 0; i < n; ++i)
        out(" {%g %g %g %g %g %g}", (double)v[i].TopLeftX, (double)v[i].TopLeftY, (double)v[i].Width, (double)v[i].Height, (double)v[i].MinDepth,
            (double)v[i].MaxDepth);
    out("\n");
}
static void STDMETHODCALLTYPE RSSetScissorRects(ID3D12GraphicsCommandList* This, UINT n, const D3D12_RECT* r) {
    out("#%d RSSetScissorRects", idOf(This));
    for (UINT i = 0; i < n; ++i) out(" {%d %d %d %d}", (int)r[i].left, (int)r[i].top, (int)r[i].right, (int)r[i].bottom);
    out("\n");
}
static void STDMETHODCALLTYPE OMSetBlendFactor(ID3D12GraphicsCommandList* This, const FLOAT k[4]) {
    out("#%d OMSetBlendFactor %g %g %g %g\n", idOf(This), (double)k[0], (double)k[1], (double)k[2], (double)k[3]);
}
static void STDMETHODCALLTYPE SetPipelineState(ID3D12GraphicsCommandList* This, ID3D12PipelineState* p) {
    out("#%d SetPipelineState", idOf(This));
    obj("pso", p);
    out("\n");
}
static void STDMETHODCALLTYPE SetDescriptorHeaps(ID3D12GraphicsCommandList* This, UINT n, ID3D12DescriptorHeap* const* heaps) {
    out("#%d SetDescriptorHeaps", idOf(This));
    for (UINT i = 0; i < n; ++i) out(" #%d", idOf(heaps[i]));
    out("\n");
}
static void STDMETHODCALLTYPE SetGraphicsRootSignature(ID3D12GraphicsCommandList* This, ID3D12RootSignature* r) {
    out("#%d SetGraphicsRootSignature", idOf(This));
    obj("root", r);
    out("\n");
}
static void STDMETHODCALLTYPE SetComputeRootSignature(ID3D12GraphicsCommandList* This, ID3D12RootSignature* r) {
    out("#%d SetComputeRootSignature", idOf(This));
    obj("root", r);
    out("\n");
}
static void STDMETHODCALLTYPE SetGraphicsRootDescriptorTable(ID3D12GraphicsCommandList* This, UINT param, D3D12_GPU_DESCRIPTOR_HANDLE h) {
    out("#%d SetGraphicsRootDescriptorTable %u 0x%llx\n", idOf(This), param, (unsigned long long)h.ptr);
}
static void STDMETHODCALLTYPE SetComputeRootDescriptorTable(ID3D12GraphicsCommandList* This, UINT param, D3D12_GPU_DESCRIPTOR_HANDLE h) {
    out("#%d SetComputeRootDescriptorTable %u 0x%llx\n", idOf(This), param, (unsigned long long)h.ptr);
}
static void STDMETHODCALLTYPE IASetVertexBuffers(ID3D12GraphicsCommandList* This, UINT start, UINT n, const D3D12_VERTEX_BUFFER_VIEW* v) {
    out("#%d IASetVertexBuffers %u", idOf(This), start);
    for (UINT i = 0; i < n; ++i) out(" {0x%llx %u %u}", (unsigned long long)v[i].BufferLocation, v[i].SizeInBytes, v[i].StrideInBytes);
    out("\n");
}
static void STDMETHODCALLTYPE IASetIndexBuffer(ID3D12GraphicsCommandList* This, const D3D12_INDEX_BUFFER_VIEW* v) {
    out("#%d IASetIndexBuffer {0x%llx %u fmt %d}\n", idOf(This), (unsigned long long)v->BufferLocation, v->SizeInBytes, v->Format);
}
static void STDMETHODCALLTYPE OMSetRenderTargets(ID3D12GraphicsCommandList* This, UINT n, const D3D12_CPU_DESCRIPTOR_HANDLE* rtvs, BOOL single,
                                                 const D3D12_CPU_DESCRIPTOR_HANDLE* dsv) {
    out("#%d OMSetRenderTargets", idOf(This));
    for (UINT i = 0; i < n; ++i) out(" 0x%zx", (size_t)rtvs[i].ptr);
    out(" single %d dsv=%s\n", single, dsv ? "set" : "null");
}
static void STDMETHODCALLTYPE ClearRenderTargetView(ID3D12GraphicsCommandList* This, D3D12_CPU_DESCRIPTOR_HANDLE rtv, const FLOAT c[4], UINT n,
                                                    const D3D12_RECT* rects) {
    (void)rects;
    out("#%d ClearRenderTargetView 0x%zx %g %g %g %g rects %u\n", idOf(This), (size_t)rtv.ptr, (double)c[0], (double)c[1], (double)c[2], (double)c[3], n);
}
static void STDMETHODCALLTYPE DrawInstanced(ID3D12GraphicsCommandList* This, UINT v, UINT i, UINT fv, UINT fi) {
    out("#%d DrawInstanced %u %u %u %u\n", idOf(This), v, i, fv, fi);
}
static void STDMETHODCALLTYPE DrawIndexedInstanced(ID3D12GraphicsCommandList* This, UINT n, UINT i, UINT fi, INT bv, UINT fin) {
    out("#%d DrawIndexedInstanced %u %u %u %d %u\n", idOf(This), n, i, fi, bv, fin);
}
static void STDMETHODCALLTYPE Dispatch(ID3D12GraphicsCommandList* This, UINT x, UINT y, UINT z) {
    out("#%d Dispatch %u %u %u\n", idOf(This), x, y, z);
}
static void STDMETHODCALLTYPE ResolveSubresource(ID3D12GraphicsCommandList* This, ID3D12Resource* dst, UINT ds, ID3D12Resource* src, UINT ss, DXGI_FORMAT f) {
    out("#%d ResolveSubresource", idOf(This));
    obj("dst", dst);
    out(" %u", ds);
    obj("src", src);
    out(" %u fmt %d\n", ss, f);
}

// ---- free functions -------------------------------------------------------------------------

HRESULT WINAPI D3DCompile(LPCVOID src, SIZE_T len, LPCSTR name, const void* defines, void* include, LPCSTR entry, LPCSTR target, UINT flags1, UINT flags2,
                          ID3DBlob** code, ID3DBlob** errors) {
    const uint32_t h = fnv(src, len) ^ fnv(entry, strlen(entry)) * 31 ^ fnv(target, strlen(target)) * 131;
    Obj* b = makeBlob(h);
    out("D3DCompile %08x/%zu \"%s\" defines=%s include=%s %s %s 0x%x 0x%x -> #%d\n", fnv(src, len), (size_t)len, name ? name : "", defines ? "set" : "null",
        include ? "set" : "null", entry, target, flags1, flags2, b->id);
    *code = (ID3DBlob*)b;
    if (errors) *errors = NULL;
    return S_OK;
}

HRESULT WINAPI D3D12SerializeRootSignature(const D3D12_ROOT_SIGNATURE_DESC* d, D3D_ROOT_SIGNATURE_VERSION version, ID3DBlob** blob, ID3DBlob** errors) {
    const size_t start = log_len;
    out("D3D12SerializeRootSignature v%d flags 0x%x params", version, d->Flags);
    for (UINT p = 0; p < d->NumParameters; ++p) {
        const D3D12_ROOT_PARAMETER* rp = &d->pParameters[p];
        out(" {type %d vis %d", rp->ParameterType, rp->ShaderVisibility);
        if (rp->ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE)
            for (UINT r = 0; r < rp->DescriptorTable.NumDescriptorRanges; ++r) {
                const D3D12_DESCRIPTOR_RANGE* g = &rp->DescriptorTable.pDescriptorRanges[r];
                out(" [%d n %u reg %u space %u off %u]", g->RangeType, g->NumDescriptors, g->BaseShaderRegister, g->RegisterSpace,
                    g->OffsetInDescriptorsFromTableStart);
            }
        out("}");
    }
    out(" static %u", d->NumStaticSamplers);
    Obj* b = makeBlob(fnv(log_buf + start, log_len - start));
    out(" -> #%d\n", b->id);
    *blob = (ID3DBlob*)b;
    if (errors) *errors = NULL;
    return S_OK;
}

// ---- making the vtables ---------------------------------------------------------------------

static ID3D12DeviceVtbl device_vtbl;
static ID3D12GraphicsCommandListVtbl list_vtbl;
static int ready;

static void init(void) {
    if (ready) return;
    ready = 1;
    fill(&blob_vtbl, sizeof blob_vtbl);
    blob_vtbl.Release = (void*)Release;
    blob_vtbl.GetBufferPointer = BlobPointer;
    blob_vtbl.GetBufferSize = BlobSize;

    fill(&resource_vtbl, sizeof resource_vtbl);
    resource_vtbl.Release = (void*)Release;
    resource_vtbl.Map = Map;
    resource_vtbl.Unmap = Unmap;
    resource_vtbl.GetDesc = (void*)GetDesc;
    resource_vtbl.GetGPUVirtualAddress = GetGPUVirtualAddress;

    fill(&heap_vtbl, sizeof heap_vtbl);
    heap_vtbl.Release = (void*)Release;
    heap_vtbl.GetCPUDescriptorHandleForHeapStart = (void*)HeapCpu;
    heap_vtbl.GetGPUDescriptorHandleForHeapStart = (void*)HeapGpu;

    fill(&root_vtbl, sizeof root_vtbl);
    root_vtbl.Release = (void*)Release;
    fill(&pso_vtbl, sizeof pso_vtbl);
    pso_vtbl.Release = (void*)Release;

    fill(&device_vtbl, sizeof device_vtbl);
    device_vtbl.Release = (void*)Release;
    device_vtbl.CreateCommittedResource = CreateCommittedResource;
    device_vtbl.CreateDescriptorHeap = CreateDescriptorHeap;
    device_vtbl.GetDescriptorHandleIncrementSize = GetDescriptorHandleIncrementSize;
    device_vtbl.CreateRootSignature = CreateRootSignature;
    device_vtbl.CreateGraphicsPipelineState = CreateGraphicsPipelineState;
    device_vtbl.CreateComputePipelineState = CreateComputePipelineState;
    device_vtbl.CreateConstantBufferView = CreateConstantBufferView;
    device_vtbl.CreateShaderResourceView = CreateShaderResourceView;
    device_vtbl.CreateUnorderedAccessView = CreateUnorderedAccessView;
    device_vtbl.CreateRenderTargetView = CreateRenderTargetView;
    device_vtbl.CreateSampler = CreateSampler;
    device_vtbl.GetCopyableFootprints = GetCopyableFootprints;

    fill(&list_vtbl, sizeof list_vtbl);
    list_vtbl.Release = (void*)Release;
    list_vtbl.CopyBufferRegion = CopyBufferRegion;
    list_vtbl.CopyTextureRegion = CopyTextureRegion;
    list_vtbl.ResourceBarrier = ResourceBarrier;
    list_vtbl.IASetPrimitiveTopology = IASetPrimitiveTopology;
    list_vtbl.RSSetViewports = RSSetViewports;
    list_vtbl.RSSetScissorRects = RSSetScissorRects;
    list_vtbl.OMSetBlendFactor = OMSetBlendFactor;
    list_vtbl.SetPipelineState = SetPipelineState;
    list_vtbl.SetDescriptorHeaps = SetDescriptorHeaps;
    list_vtbl.SetGraphicsRootSignature = SetGraphicsRootSignature;
    list_vtbl.SetComputeRootSignature = SetComputeRootSignature;
    list_vtbl.SetGraphicsRootDescriptorTable = SetGraphicsRootDescriptorTable;
    list_vtbl.SetComputeRootDescriptorTable = SetComputeRootDescriptorTable;
    list_vtbl.IASetVertexBuffers = IASetVertexBuffers;
    list_vtbl.IASetIndexBuffer = IASetIndexBuffer;
    list_vtbl.OMSetRenderTargets = OMSetRenderTargets;
    list_vtbl.ClearRenderTargetView = ClearRenderTargetView;
    list_vtbl.DrawInstanced = DrawInstanced;
    list_vtbl.DrawIndexedInstanced = DrawIndexedInstanced;
    list_vtbl.Dispatch = Dispatch;
    list_vtbl.ResolveSubresource = ResolveSubresource;
}

/// The recording device (#1) and command list (#2) a run starts from.
void* lcgf_d3d12_record_device(void) {
    init();
    return make(&device_vtbl);
}
void* lcgf_d3d12_record_list(void) {
    init();
    return make(&list_vtbl);
}
