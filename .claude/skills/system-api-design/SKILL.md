---
name: system-api-design
description: >
  Principles and patterns for designing system-level APIs (not web/REST APIs) in languages like
  Rust, Zig, C, and Odin. Based on Casey Muratori's five characteristics of reusable components,
  compression-oriented programming, and performance-aware design. Use this skill whenever the user
  is designing a library API, systems interface, FFI boundary, GPU/graphics API wrapper, game engine
  interface, middleware, SDK, or any reusable component meant for integration into performance-sensitive
  software. Also trigger when the user mentions: API granularity, immediate vs retained mode, flow control
  inversion, integration discontinuities, callback elimination, or asks how to structure a C-style API
  surface in Rust or Zig. Trigger even if the user just says "design an API for X" in a systems context.
---

# System-Level API Design

A guide for designing APIs for libraries, engines, SDKs, and reusable components in systems
programming. Rooted in Casey Muratori's "Designing and Evaluating Reusable Components" (2004),
refined with modern Rust and Zig idioms.

The core thesis: **write the usage code first, then build the API to serve it.** This is the
first and second rule. Not documentation, not architecture diagrams — the code a real user would
write to integrate your library.

---

## The Five Characteristics

Every system-level API can be evaluated on five measurable axes. Optimizing all five produces an
API that is gradually tiered, highly decoupled, stateless at its lowest level, and never inverts
control away from the caller.

### 1. Granularity (Can I do A, or must I do ABC?)

For every high-level operation, there must be lower-level primitives that achieve the same result
with more caller control. When this property breaks — a "granularity discontinuity" — the user
hits a cliff: they either use your abstraction wholesale or rewrite everything.

**Rule of thumb:** Never supply a higher-level function that can't be trivially replaced by a
few lower-level functions doing the same thing.

**Rust example — tiered rendering API:**

```rust
// Tier 1 (high-level): draw a textured quad in one call
pub fn draw_sprite(ctx: &mut RenderCtx, sprite: &Sprite, pos: Vec2) { ... }

// Tier 2 (mid-level): caller controls batching
pub fn begin_batch(ctx: &mut RenderCtx, texture: TextureId) -> Batch { ... }
pub fn push_quad(batch: &mut Batch, verts: [4]Vertex) { ... }
pub fn submit_batch(ctx: &mut RenderCtx, batch: Batch) { ... }

// Tier 3 (low-level): caller owns the command buffer entirely
pub fn map_vertex_buffer(ctx: &mut RenderCtx, size: usize) -> &mut [u8] { ... }
pub fn submit_draw_call(ctx: &mut RenderCtx, call: DrawCall) { ... }
```

The user who outgrows `draw_sprite` drops down to `begin_batch` without rewriting their renderer.

**Zig example — tiered audio API:**

```zig
// Tier 1: fire-and-forget
pub fn playSound(ctx: *AudioCtx, sound: SoundId, vol: f32) void { ... }

// Tier 2: caller controls the voice
pub fn acquireVoice(ctx: *AudioCtx) ?*Voice { ... }
pub fn setVoiceBuffer(voice: *Voice, buf: []const f32) void { ... }
pub fn releaseVoice(ctx: *AudioCtx, voice: *Voice) void { ... }

// Tier 3: caller mixes directly into the output buffer
pub fn lockMixBuffer(ctx: *AudioCtx) []f32 { ... }
pub fn unlockMixBuffer(ctx: *AudioCtx) void { ... }
```

### 2. Redundancy (Diagonal vs. Orthogonal)

Conventional wisdom says APIs should be orthogonal — small composable primitives. But forcing
users to compose five calls for the common case creates friction. Offer "diagonal" shortcuts for
the 80% path while keeping the orthogonal primitives available.

This is Chris Hecker's framing: you want to travel the shortest distance, not the Manhattan path.

```rust
// Orthogonal (always available)
let layout = Layout::new();
layout.set_direction(Direction::Horizontal);
layout.set_padding(Edges::uniform(8.0));
layout.set_gap(4.0);
let result = layout.compute(&children);

// Diagonal shortcut for the common case
let result = Layout::horizontal(8.0, 4.0).compute(&children);
```

### 3. Coupling (Does A secretly require B?)

Hidden dependencies between API parts create integration nightmares. Each function should
declare what it needs through its signature, not through implicit global state or initialization
order.

**Anti-pattern (coupled):**
```rust
// Must call init() before any other function, but nothing enforces this
pub fn init() { ... }
pub fn create_surface() -> Surface { ... }  // panics if init() wasn't called
```

**Fixed (decoupled via type state):**
```rust
pub struct Instance { /* proof that init happened */ }

pub fn init(config: &Config) -> Result<Instance, Error> { ... }
pub fn create_surface(instance: &Instance, ...) -> Result<Surface, Error> { ... }
// Impossible to call create_surface without a valid Instance
```

**Zig equivalent — coupling through explicit parameters:**
```zig
pub const Instance = struct { ... };

pub fn init(config: Config) !Instance { ... }
pub fn createSurface(instance: *Instance, ...) !Surface { ... }
// The dependency is visible in the function signature
```

### 4. Retention (Does the API hold state on my behalf?)

At the most granular tier, the API should hold no state — the caller owns everything. Higher
tiers can cache and retain for convenience, but there must always be a path where the caller
manages all data.

**Retained mode** (convenient but opaque):
```rust
renderer.add_mesh(mesh_id, &vertices, &indices);  // renderer stores a copy
renderer.draw(mesh_id);                             // uses internal copy
// Problem: who owns the data? When is it freed? Can I update it?
```

**Immediate mode** (caller owns data):
```rust
renderer.draw_mesh(&vertices, &indices);  // borrows, never stores
// Caller owns the data, decides lifetime, can change it every frame
```

**Best: offer both, with the retained layer trivially replaceable:**
```rust
// Retained convenience layer
impl MeshCache {
    pub fn store(&mut self, id: MeshId, verts: &[Vertex], idxs: &[u16]) { ... }
    pub fn draw(&self, renderer: &mut Renderer, id: MeshId) {
        let mesh = &self.meshes[id];
        renderer.draw_mesh(&mesh.vertices, &mesh.indices);  // calls immediate
    }
}
```

### 5. Flow Control (Who calls whom?)

The application should always dictate control flow. Callbacks, inheritance, and framework-style
inversion are red flags in system-level APIs.

**Anti-pattern (library controls flow):**
```rust
// Library calls YOU — you lose control of when/how things happen
trait GameLoop {
    fn on_update(&mut self, dt: f32);
    fn on_render(&mut self, ctx: &mut RenderCtx);
}
fn run_game(game: &mut dyn GameLoop) { /* library owns the loop */ }
```

**Fixed (caller controls flow):**
```rust
// Caller owns the loop — library is a tool, not a framework
loop {
    let dt = timer.elapsed();
    game_state.update(dt);
    renderer.begin_frame();
    game_state.render(&mut renderer);
    renderer.end_frame();
    window.swap_buffers();
}
```

**Zig — caller-driven I/O:**
```zig
// Anti-pattern: callback-based I/O
pub fn readAsync(fd: fd_t, callback: *const fn([]u8) void) void { ... }

// Fixed: polling / caller-driven
pub fn pollRead(fd: fd_t, buf: []u8) ReadResult {
    return .{ .bytes_read = n, .status = .ready };
}
// Caller decides when to poll, what to do with the result, how to schedule
```

---

## Compression-Oriented Programming

Instead of designing architecture upfront (UML, class hierarchies, patterns), write the usage
code first and compress iteratively:

1. **Inline everything.** Write the solution directly. No functions, no abstractions.
2. **Notice duplication.** When you do the same thing a second time, extract the shared portion.
3. **Compress semantically.** Name the extracted thing after what it *means*, not what it *is*.
4. **Repeat.** Architecture emerges from compression, not from pre-planning.

The resulting code is simultaneously minimal (easy to read), consistent (shared paths go through
shared code), and extensible (recomposable pieces are already there).

**Practical Rust example:**

```rust
// Step 1: Inline — just do the thing twice
let area_circle = std::f32::consts::PI * radius * radius;
let area_rect = width * height;
let area_triangle = 0.5 * base * height;

// Step 2: Notice the pattern — it's always: coefficient * dim1 * dim2
// Step 3: Compress
fn area(coeff: f32, a: f32, b: f32) -> f32 { coeff * a * b }
// or even better, batch with a lookup table:
const COEFFS: [ShapeKind; 3] = [PI, 1.0, 0.5];
fn areas(shapes: &[Shape]) -> Vec<f32> {
    shapes.iter().map(|s| COEFFS[s.kind as usize] * s.dim1 * s.dim2).collect()
}
```

The key insight from Casey's "Clean Code, Horrible Performance": when code is organized by
*operation* rather than by *type*, common patterns become visible and exploitable. Scattering
logic across class files hides the very structure that enables optimization.

---

## Rust-Specific API Patterns

### Tagged unions over virtual dispatch
Prefer `enum` + `match` over `dyn Trait`. It's faster (no vtable indirection), exhaustive
(compiler catches missing cases), and the data is contiguous in memory.

```rust
enum Shape {
    Circle { radius: f32 },
    Rect { w: f32, h: f32 },
    Triangle { base: f32, height: f32 },
}

fn area(s: &Shape) -> f32 {
    match s {
        Shape::Circle { radius } => PI * radius * radius,
        Shape::Rect { w, h } => w * h,
        Shape::Triangle { base, height } => 0.5 * base * height,
    }
}
```

### Typestate pattern for compile-time enforcement
Encode API states into the type system so invalid transitions don't compile.

```rust
struct Pipeline<S: PipelineState> { inner: RawPipeline, _state: PhantomData<S> }
struct Unbound;
struct Bound;

impl Pipeline<Unbound> {
    fn bind(self, target: &RenderTarget) -> Pipeline<Bound> { ... }
}
impl Pipeline<Bound> {
    fn draw(&self, mesh: &Mesh) { ... }  // only available after binding
}
// Pipeline<Unbound> has no draw() — calling it is a compile error
```

### Accept borrowed, return owned
Take `&str` not `&String`, `&[T]` not `&Vec<T>`. Return owned types so callers aren't
fighting lifetimes at the API boundary.

### Explicit allocators (when applicable)
For performance-critical paths, consider taking an allocator parameter rather than using
the global allocator, similar to Zig's approach:

```rust
pub fn decode(data: &[u8], alloc: &dyn Allocator) -> Result<Image, Error> { ... }
```

---

## Zig-Specific API Patterns

### Explicit allocator parameter
Zig's defining API pattern: every function that allocates takes an `std.mem.Allocator`.
No hidden allocations. The caller controls memory strategy.

```zig
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Ast {
    var nodes = std.ArrayList(Node).init(allocator);
    defer nodes.deinit();
    // ... parse into nodes ...
    return Ast{ .nodes = try nodes.toOwnedSlice() };
}
```

### Comptime generics for zero-cost abstraction
Instead of runtime polymorphism, use comptime to generate specialized types:

```zig
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        pub fn push(self: *@This(), item: T) void {
            self.buf[(self.head + self.len) % capacity] = item;
            if (self.len < capacity) self.len += 1
            else self.head = (self.head + 1) % capacity;
        }

        pub fn get(self: *const @This(), index: usize) ?T {
            if (index >= self.len) return null;
            return self.buf[(self.head + index) % capacity];
        }
    };
}
// Usage: var rb = RingBuffer(f32, 256){};
```

### Error sets — visible, composable, no exceptions
Functions return error unions. Callers see exactly what can fail. No hidden control flow.

```zig
const InitError = error{ DeviceNotFound, OutOfMemory, InvalidConfig };

pub fn init(config: Config) InitError!Device {
    const raw = openDevice(config.id) orelse return error.DeviceNotFound;
    const mem = allocator.alloc(u8, config.buf_size) catch return error.OutOfMemory;
    return Device{ .handle = raw, .buffer = mem };
}
```

### defer/errdefer for RAII without destructors
Resource cleanup is explicit and local, visible at the point of acquisition:

```zig
pub fn processFile(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();  // always runs on scope exit

    const buf = try allocator.alloc(u8, 4096);
    errdefer allocator.free(buf);  // only runs if function returns an error

    // ... work with file and buf ...
}
```

---

## The Evaluation Checklist

When reviewing a system API, run through these questions:

1. **Usage code first?** Can you write the integration code in under 10 minutes?
2. **Granularity:** Can every high-level call be replaced by lower-level equivalents?
3. **Redundancy:** Are common operations achievable in one or two calls?
4. **Coupling:** Can you use feature A without initializing unrelated feature B?
5. **Retention:** Is there an immediate-mode path where the caller owns all data?
6. **Flow control:** Does the caller always decide when things happen?
7. **No API-specific types for common data:** Does it accept standard types (slices, raw
   pointers, basic structs) instead of forcing wrappers?
8. **Compression check:** Is there duplicated logic that could be unified?
9. **Performance awareness:** Does the structure enable batch processing and cache-friendly access?

---

## Key Sources

- Casey Muratori, "Designing and Evaluating Reusable Components" (2004) — caseymuratori.com/blog_0024
- Casey Muratori, "Semantic Compression" — caseymuratori.com/blog_0015
- Casey Muratori, "The Worst API Ever Made" — caseymuratori.com/blog_0025
- Casey Muratori, "Clean Code, Horrible Performance" — computerenhance.com
- Chris Hecker, "API Design" — chrishecker.com/API_Design
- Vurtun's API design notes — gist.github.com/vurtun/192cac1f1818417d7b4067d60e4fe921
- Rust API Guidelines — rust-lang.github.io/api-guidelines
- Zig documentation — ziglang.org/documentation
