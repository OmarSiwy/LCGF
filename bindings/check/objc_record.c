// A recording Objective-C runtime, for the bindings' Metal gate (bindings/check/run.sh): a shared
// library with libobjc's and Metal's entry points that logs every message the Metal projection
// sends, with its arguments, instead of sending it. The Zig projection (src/render/metal/gpu.zig,
// through objc.loadFrom), lcgf/gpu.hpp with LCGF_GPU_METAL and lcgf::gpu with `metal` all open
// it in place of the system's; run.sh requires their logs to be equal.
//
// objc_msgSend is assembly that keeps the argument registers and the caller's stack and calls
// `record`, which reads the arguments by the selector's signature (`sigs`), as System V passes
// them on x86-64: integers and pointers in six registers then the stack, floats in eight vector
// registers then the stack, structs over 16 bytes on the stack. A selector it does not know
// stops the program: a new message must be added to `sigs` before it can be compared.
//
// Objects are numbered as they are made (#1, #2, ...), classes printed by name, so the log does
// not depend on addresses. A buffer has memory (`contents`), and the bytes a copy or a
// set*Bytes: call moves are logged; a string keeps its text, and a long one (MSL) is logged as
// its length and FNV-1a hash.
#if !defined(__x86_64__) || !defined(__ELF__)
#error "objc_record.c: the recorder is for x86-64 ELF (System V)"
#endif
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Obj {
    int id;           // 0 for a class
    const char* cls;  // a class's name
    unsigned char* mem;
    size_t len;
    char* str;
} Obj;

static char* log_buf;
static size_t log_len, log_cap;
static int next_id = 1;

static void out(const char* fmt, ...) {
    char tmp[1024];
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

const char* lcgf_objc_record_log(size_t* len) {
    *len = log_len;
    return log_buf ? log_buf : "";
}

static Obj* make(void) {
    Obj* o = calloc(1, sizeof *o);
    o->id = next_id++;
    return o;
}

static uint32_t fnv(const char* s, size_t n) {
    uint32_t h = 0x811c9dc5u;
    for (size_t i = 0; i < n; ++i) h = (h ^ (unsigned char)s[i]) * 0x01000193u;
    return h;
}

static void object(const void* p) {
    const Obj* o = p;
    if (!o) {
        out(" nil");
    } else if (o->id == 0) {
        out(" %s", o->cls);
    } else if (o->str) {
        size_t n = strlen(o->str);
        if (n <= 48 && !strchr(o->str, '\n')) out(" #%d@\"%s\"", o->id, o->str);
        else out(" #%d@<%zu bytes %08x>", o->id, n, fnv(o->str, n));
    } else {
        out(" #%d", o->id);
    }
}

static void bytes(const unsigned char* p, size_t n) {
    out(" [");
    for (size_t i = 0; i < n; ++i) out("%02x", p[i]);
    out("]");
}

// ---- the runtime's own functions --------------------------------------------------------------

#define MAX_CLASSES 64
static Obj classes[MAX_CLASSES];
static int class_count;

void* objc_getClass(const char* name) {
    for (int i = 0; i < class_count; ++i)
        if (strcmp(classes[i].cls, name) == 0) return &classes[i];
    if (class_count == MAX_CLASSES) abort();
    classes[class_count].cls = strdup(name);
    return &classes[class_count++];
}

#define MAX_SELS 512
static char* sels[MAX_SELS];
static int sel_count;

// A selector is its interned name, so `record` reads the name back from it.
void* sel_registerName(const char* name) {
    for (int i = 0; i < sel_count; ++i)
        if (strcmp(sels[i], name) == 0) return sels[i];
    if (sel_count == MAX_SELS) abort();
    sels[sel_count] = strdup(name);
    return sels[sel_count++];
}

void* objc_autoreleasePoolPush(void) {
    out("pool push\n");
    return (void*)1;
}

void objc_autoreleasePoolPop(void* token) {
    (void)token;
    out("pool pop\n");
}

void* MTLCreateSystemDefaultDevice(void) {
    Obj* o = make();
    out("MTLCreateSystemDefaultDevice -> #%d\n", o->id);
    return o;
}

// ---- messages -------------------------------------------------------------------------------

// Arguments: o object, u NSUInteger, i NSInteger, b BOOL, f float, d double, p an out-pointer,
// s a C string, B a pointer to bytes whose length is the next (u) argument, U<n> / D<n> a struct
// of n 64-bit unsigned / double fields (passed in memory: all are over 16 bytes). Returns: v
// nothing, o a new object, r the receiver, m a buffer's memory, s a C string.
typedef struct {
    const char* name;
    const char* args;
    char ret;
} Sig;

static const Sig sigs[] = {
    {"new", "", 'o'},
    {"release", "", 'v'},
    {"retain", "", 'r'},
    {"stringWithUTF8String:", "s", 'o'},
    {"UTF8String", "", 's'},
    {"localizedDescription", "", 'o'},
    {"newCommandQueue", "", 'o'},
    {"commandBuffer", "", 'o'},
    {"commit", "", 'v'},
    {"waitUntilCompleted", "", 'v'},
    {"newBufferWithLength:options:", "uu", 'o'},
    {"contents", "", 'm'},
    {"texture2DDescriptorWithPixelFormat:width:height:mipmapped:", "uuub", 'o'},
    {"setUsage:", "u", 'v'},
    {"setStorageMode:", "u", 'v'},
    {"setTextureType:", "u", 'v'},
    {"setSampleCount:", "u", 'v'},
    {"newTextureWithDescriptor:", "o", 'o'},
    {"setMinFilter:", "u", 'v'},
    {"setMagFilter:", "u", 'v'},
    {"setMipFilter:", "u", 'v'},
    {"setSAddressMode:", "u", 'v'},
    {"setTAddressMode:", "u", 'v'},
    {"setRAddressMode:", "u", 'v'},
    {"setLodMinClamp:", "f", 'v'},
    {"setLodMaxClamp:", "f", 'v'},
    {"setCompareFunction:", "u", 'v'},
    {"newSamplerStateWithDescriptor:", "o", 'o'},
    {"newLibraryWithSource:options:error:", "oop", 'o'},
    {"newFunctionWithName:", "o", 'o'},
    {"setVertexFunction:", "o", 'v'},
    {"setFragmentFunction:", "o", 'v'},
    {"setRasterSampleCount:", "u", 'v'},
    {"setAlphaToCoverageEnabled:", "b", 'v'},
    {"vertexDescriptor", "", 'o'},
    {"attributes", "", 'o'},
    {"layouts", "", 'o'},
    {"objectAtIndexedSubscript:", "u", 'o'},
    {"setFormat:", "u", 'v'},
    {"setOffset:", "u", 'v'},
    {"setBufferIndex:", "u", 'v'},
    {"setStride:", "u", 'v'},
    {"setStepFunction:", "u", 'v'},
    {"setStepRate:", "u", 'v'},
    {"setVertexDescriptor:", "o", 'v'},
    {"colorAttachments", "", 'o'},
    {"setPixelFormat:", "u", 'v'},
    {"setWriteMask:", "u", 'v'},
    {"setBlendingEnabled:", "b", 'v'},
    {"setSourceRGBBlendFactor:", "u", 'v'},
    {"setDestinationRGBBlendFactor:", "u", 'v'},
    {"setRgbBlendOperation:", "u", 'v'},
    {"setSourceAlphaBlendFactor:", "u", 'v'},
    {"setDestinationAlphaBlendFactor:", "u", 'v'},
    {"setAlphaBlendOperation:", "u", 'v'},
    {"newRenderPipelineStateWithDescriptor:error:", "op", 'o'},
    {"newComputePipelineStateWithFunction:error:", "op", 'o'},
    {"blitCommandEncoder", "", 'o'},
    {"copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:", "ououu", 'v'},
    {"copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:",
     "ouuuU3ouuU3", 'v'},
    {"copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:",
     "ouuU3U3ouuu", 'v'},
    {"endEncoding", "", 'v'},
    {"renderPassDescriptor", "", 'o'},
    {"setTexture:", "o", 'v'},
    {"setLoadAction:", "u", 'v'},
    {"setStoreAction:", "u", 'v'},
    {"setResolveTexture:", "o", 'v'},
    {"setClearColor:", "D4", 'v'},
    {"renderCommandEncoderWithDescriptor:", "o", 'o'},
    {"computeCommandEncoder", "", 'o'},
    {"setRenderPipelineState:", "o", 'v'},
    {"setCullMode:", "u", 'v'},
    {"setFrontFacingWinding:", "u", 'v'},
    {"setTriangleFillMode:", "u", 'v'},
    {"setVertexBuffer:offset:atIndex:", "ouu", 'v'},
    {"setFragmentBuffer:offset:atIndex:", "ouu", 'v'},
    {"setVertexTexture:atIndex:", "ou", 'v'},
    {"setFragmentTexture:atIndex:", "ou", 'v'},
    {"setVertexSamplerState:atIndex:", "ou", 'v'},
    {"setFragmentSamplerState:atIndex:", "ou", 'v'},
    {"setVertexBytes:length:atIndex:", "Buu", 'v'},
    {"setFragmentBytes:length:atIndex:", "Buu", 'v'},
    {"setViewport:", "D6", 'v'},
    {"setScissorRect:", "U4", 'v'},
    {"setBlendColorRed:green:blue:alpha:", "ffff", 'v'},
    {"drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", "uuuuu", 'v'},
    {"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:", "uuuouuiu", 'v'},
    {"setComputePipelineState:", "o", 'v'},
    {"setBuffer:offset:atIndex:", "ouu", 'v'},
    {"setTexture:atIndex:", "ou", 'v'},
    {"setSamplerState:atIndex:", "ou", 'v'},
    {"setBytes:length:atIndex:", "Buu", 'v'},
    {"dispatchThreadgroups:threadsPerThreadgroup:", "U3U3", 'v'},
};

typedef struct {
    const uint64_t* gpr;    // rdi, rsi, rdx, rcx, r8, r9
    const uint64_t* xmm;    // the low 64 bits of xmm0..xmm7
    const uint64_t* stack;  // the caller's stack arguments
    int gi, fi, si;
} Args;

static uint64_t next_int(Args* a) { return a->gi < 6 ? a->gpr[a->gi++] : a->stack[a->si++]; }
static uint64_t next_float(Args* a) { return a->fi < 8 ? a->xmm[a->fi++] : a->stack[a->si++]; }

uint64_t lcgf_objc_record(const uint64_t* regs, const uint64_t* stack) {
    Obj* self = (Obj*)regs[0];
    const char* sel = (const char*)regs[1];
    const Sig* sig = NULL;
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; ++i)
        if (strcmp(sigs[i].name, sel) == 0) sig = &sigs[i];
    if (!sig) {
        fprintf(stderr, "objc_record: no signature for -%s; add it to bindings/check/objc_record.c\n", sel);
        abort();
    }
    Args a = {regs, regs + 6, stack, 2, 0, 0};
    uint64_t vals[16] = {0}; // the object and integer arguments, for the calls that need them
    int nint = 0;
    object(self);
    out(" %s", sel);
    for (const char* p = sig->args; *p; ++p) {
        switch (*p) {
        case 'o': {
            uint64_t v = next_int(&a);
            if (nint < 16) vals[nint++] = v;
            object((const void*)v);
            break;
        }
        case 'u': {
            uint64_t v = next_int(&a);
            if (nint < 16) vals[nint++] = v;
            out(" %llu", (unsigned long long)v);
            break;
        }
        case 'i': out(" %lld", (long long)next_int(&a)); break;
        case 'b': out(" %s", (next_int(&a) & 0xff) ? "YES" : "NO"); break;
        case 'p': out(" %s", next_int(&a) ? "&" : "NULL"); break;
        case 's': {
            const char* str = (const char*)next_int(&a);
            const size_t n = strlen(str);
            if (n <= 48 && !strchr(str, '\n')) out(" \"%s\"", str);
            else out(" <%zu bytes %08x>", n, fnv(str, n));
            break;
        }
        case 'f': {
            uint64_t v = next_float(&a);
            float f;
            memcpy(&f, &v, 4);
            out(" %g", (double)f);
            break;
        }
        case 'd': {
            uint64_t v = next_float(&a);
            double d;
            memcpy(&d, &v, 8);
            out(" %g", d);
            break;
        }
        case 'B': {
            const unsigned char* ptr = (const unsigned char*)next_int(&a);
            uint64_t n = next_int(&a);
            ++p; // the length's own 'u'
            bytes(ptr, (size_t)n);
            out(" %llu", (unsigned long long)n);
            break;
        }
        case 'U':
        case 'D': {
            const int n = p[1] - '0';
            const uint64_t* w = &a.stack[a.si];
            a.si += n;
            out(" {");
            for (int k = 0; k < n; ++k) {
                if (*p == 'U') {
                    out(k ? " %llu" : "%llu", (unsigned long long)w[k]);
                } else {
                    double d;
                    memcpy(&d, &w[k], 8);
                    out(k ? " %g" : "%g", d);
                }
            }
            out("}");
            ++p;
            break;
        }
        default: abort();
        }
    }
    // What a copy moves: the source bytes, read from the (shared) buffer's memory.
    if (strcmp(sel, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:") == 0) {
        const Obj* src = (const Obj*)vals[0];
        const uint64_t off = vals[1], size = vals[4];
        if (src && src->mem && off + size <= src->len) bytes(src->mem + off, (size_t)size);
    }
    uint64_t ret = 0;
    switch (sig->ret) {
    case 'o': {
        Obj* o = make();
        if (strcmp(sel, "newBufferWithLength:options:") == 0) {
            o->len = (size_t)vals[0];
            o->mem = calloc(1, o->len ? o->len : 1);
        } else if (strcmp(sel, "stringWithUTF8String:") == 0) {
            o->str = strdup((const char*)regs[2]);
        }
        out(" ->");
        object(o);
        ret = (uint64_t)o;
        break;
    }
    case 'r': ret = (uint64_t)self; break;
    case 'm': ret = (uint64_t)self->mem; break;
    case 's': ret = (uint64_t)(self && self->str ? self->str : ""); break;
    default: break;
    }
    out("\n");
    return ret;
}

// objc_msgSend: the six integer and eight vector argument registers stored on the stack, a
// pointer to them and to the caller's stack arguments passed to `lcgf_objc_record`, its result
// returned in rax.
__asm__(
    ".text\n"
    ".globl objc_msgSend\n"
    ".type objc_msgSend,@function\n"
    "objc_msgSend:\n"
    "  pushq %rbp\n"
    "  movq %rsp, %rbp\n"
    "  subq $112, %rsp\n"
    "  movq %rdi, 0(%rsp)\n"
    "  movq %rsi, 8(%rsp)\n"
    "  movq %rdx, 16(%rsp)\n"
    "  movq %rcx, 24(%rsp)\n"
    "  movq %r8, 32(%rsp)\n"
    "  movq %r9, 40(%rsp)\n"
    "  movsd %xmm0, 48(%rsp)\n"
    "  movsd %xmm1, 56(%rsp)\n"
    "  movsd %xmm2, 64(%rsp)\n"
    "  movsd %xmm3, 72(%rsp)\n"
    "  movsd %xmm4, 80(%rsp)\n"
    "  movsd %xmm5, 88(%rsp)\n"
    "  movsd %xmm6, 96(%rsp)\n"
    "  movsd %xmm7, 104(%rsp)\n"
    "  movq %rsp, %rdi\n"
    "  leaq 16(%rbp), %rsi\n"
    "  call lcgf_objc_record\n"
    "  leave\n"
    "  ret\n"
    ".size objc_msgSend, .-objc_msgSend\n");
