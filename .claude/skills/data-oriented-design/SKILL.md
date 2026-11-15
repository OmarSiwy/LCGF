---
name: data-oriented-design
description: >
  Data-oriented design (DOD) principles for writing cache-friendly, high-performance code in
  Rust, Zig, Odin, and C. Covers struct-of-arrays (SoA) vs array-of-structs (AoS), cache line
  optimization, hot/cold splitting, index-based references, tagged unions, arena allocators, and
  batch processing. Based on Mike Acton's CppCon 2014 talk, Casey Muratori's performance-aware
  programming, Andrew Kelley's practical DOD in Zig, and Richard Fabian's Data-Oriented Design
  book. Use this skill whenever the user is: optimizing data layouts for performance, designing
  entity/component systems, writing compilers or parsers, working on game engines, restructuring
  structs for cache efficiency, debating SoA vs AoS, replacing pointer-heavy structures with
  index-based designs, or asking about memory layout, cache misses, padding, alignment, or how
  to make their data structures faster. Also trigger for questions about MultiArrayList in Zig,
  #soa in Odin, or ECS architecture.
---

# Data-Oriented Design

Your data layout determines your performance. DOD starts from what the hardware actually does
— moving cache lines, not objects — and structures code to match.

**The core insight:** Modern CPUs are not bottlenecked by computation. They are bottlenecked by
getting data to the CPU. A cache miss to main memory costs ~100 nanoseconds — enough time to
execute hundreds of instructions. DOD organizes data so the cache contains what you need, when
you need it.

---

## Foundational Principles

### 1. Think in terms of data transformations, not objects

A program transforms input data into output data. The question is not "what objects exist?" but
"what data do I have, and what transformations do I apply?"

Don't model the world. Model the *data flow*.

```
// OOP mental model:              // DOD mental model:
Monster.update()                  update_positions(positions, velocities, dt)
Monster.render()                  render_sprites(positions, sprites, camera)
Monster.takeDamage(amount)        apply_damage(health, damage_events)
```

### 2. Where there is one, there are many

If you have one monster, you almost certainly have thousands. Design for the plural case.
A single monster's fields are irrelevant — what matters is how thousands of monsters flow
through your pipeline.

### 3. Existence-based processing

Instead of checking `if (entity.is_alive)` on every entity every frame, maintain separate
collections: `alive_entities` and `dead_entities`. Move entities between them on state change.
The hot loop never branches.

---

## AoS vs SoA

### Array of Structs (AoS) — the default, often wrong

```rust
struct Entity {
    position: Vec3,  // 12 bytes
    velocity: Vec3,  // 12 bytes
    health: f32,     // 4 bytes
    sprite: u32,     // 4 bytes
    name: [32]u8,    // 32 bytes — cold data, rarely touched
}
// Total: 64 bytes per entity
// When updating positions, you load 64 bytes but only use 24 (position + velocity)
// That's 62% wasted cache bandwidth
let entities: Vec<Entity> = vec![...];
```

Every time you iterate to update positions, the cache loads each entity's name, health, and
sprite even though you only touch position and velocity.

### Struct of Arrays (SoA) — group by access pattern

```rust
struct Entities {
    positions: Vec<Vec3>,   // hot: touched every frame
    velocities: Vec<Vec3>,  // hot: touched every frame
    health: Vec<f32>,       // warm: touched on damage events
    sprites: Vec<u32>,      // warm: touched on render
    names: Vec<[32; u8]>,   // cold: touched on UI display
}
```

Now `update_positions` iterates two contiguous arrays of `Vec3`. Every byte loaded into the
cache is useful data. This can be 2-10x faster depending on entity count and field sizes.

### When to use which

**Use AoS when:** you always access all fields together, entity count is small, or you need
to pass individual entities across API boundaries.

**Use SoA when:** you process one or two fields at a time across many entities, the struct has
a mix of hot and cold fields, or you're in a tight loop processing thousands of items.

**Use hybrid (AoSoA)** for SIMD: groups of N entities packed together where N matches your
SIMD width (4 for SSE, 8 for AVX):

```rust
// AoSoA for SIMD-friendly layout (group of 8 for AVX)
struct EntityBlock {
    x: [8; f32],  // 8 x-positions contiguous — perfect for _mm256_load_ps
    y: [8; f32],
    z: [8; f32],
    vx: [8; f32],
    vy: [8; f32],
    vz: [8; f32],
}
```

---

## Zig: First-Class DOD Support

### MultiArrayList — automatic SoA

Zig's standard library provides `MultiArrayList`, which automatically converts a struct
definition into SoA layout while keeping AoS-like access syntax:

```zig
const std = @import("std");

const Entity = struct {
    position: [3]f32,
    velocity: [3]f32,
    health: f32,
    sprite_id: u32,
};

// This stores Entity fields in separate arrays internally
var entities = std.MultiArrayList(Entity){};

pub fn init(allocator: std.mem.Allocator) !void {
    try entities.ensureTotalCapacity(allocator, 10000);
}

pub fn updatePositions(dt: f32) void {
    const positions = entities.items(.position);
    const velocities = entities.items(.velocity);

    // Iterates two contiguous arrays — cache-optimal
    for (positions, velocities) |*pos, vel| {
        pos[0] += vel[0] * dt;
        pos[1] += vel[1] * dt;
        pos[2] += vel[2] * dt;
    }
}
```

Under the hood, `MultiArrayList` uses comptime reflection (`@typeInfo`) to decompose the
struct into separate arrays, sorted by alignment for optimal packing. Switching from AoS
(`ArrayList(Entity)`) to SoA (`MultiArrayList(Entity)`) is often a one-line change.

### Comptime SoA type generation

You can build your own SoA transformation using Zig's comptime:

```zig
fn SoA(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".fields;
    var new_fields: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |field, i| {
        new_fields[i] = .{
            .name = field.name,
            .type = std.ArrayList(field.type),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &new_fields,
        .decls = &.{},
        .is_tuple = false,
    }});
}
// SoA(Entity) generates a struct with ArrayList fields for each Entity field
```

### Index-based references (replacing pointers)

Pointers are 8 bytes on 64-bit systems. If you have fewer than 4 billion items, a `u32` index
is half the size and doesn't invalidate on reallocation:

```zig
const EntityId = enum(u32) { _ };  // type-safe index

const World = struct {
    positions: std.MultiArrayList(Position),
    // Reference other entities by index, not pointer
    parent: []EntityId,

    pub fn getPosition(self: *const World, id: EntityId) Position {
        return self.positions.get(@intFromEnum(id));
    }
};
```

Benefits: halves pointer size, survives reallocation, serialization-friendly, enables SoA
layout naturally, and avoids the aliasing problems that plague pointer-heavy code.

---

## Rust: DOD Patterns

### SoA with separate Vecs

Rust doesn't have built-in SoA, but the pattern is straightforward:

```rust
// AoS (default)
struct Particle { pos: Vec3, vel: Vec3, life: f32, color: Color }
let particles: Vec<Particle> = Vec::new();

// SoA (manual)
struct Particles {
    pos: Vec<Vec3>,
    vel: Vec<Vec3>,
    life: Vec<f32>,
    color: Vec<Color>,
    len: usize,
}

impl Particles {
    fn update(&mut self, dt: f32) {
        // Only touches pos and vel — color and life stay out of cache
        for (pos, vel) in self.pos.iter_mut().zip(self.vel.iter()) {
            *pos += *vel * dt;
        }
    }
}
```

### Tagged unions — DOD-friendly polymorphism

Instead of trait objects (vtable indirection, scattered heap allocations), use enums:

```rust
enum Shape {
    Circle(f32),           // radius
    Rect(f32, f32),        // width, height
    Triangle(f32, f32),    // base, height
}

// Process all shapes in a tight loop — no indirection, no cache misses
fn total_area(shapes: &[Shape]) -> f32 {
    shapes.iter().map(|s| match s {
        Shape::Circle(r) => std::f32::consts::PI * r * r,
        Shape::Rect(w, h) => w * h,
        Shape::Triangle(b, h) => 0.5 * b * h,
    }).sum()
}
```

Casey Muratori's "Clean Code, Horrible Performance" demonstrated that this approach is roughly
**15x faster** than the equivalent virtual-dispatch class hierarchy, because it eliminates vtable
lookups, enables branch prediction, and keeps data contiguous.

If the variants have very different sizes, consider splitting into separate homogeneous arrays
instead (existence-based processing):

```rust
struct World {
    circles: Vec<Circle>,
    rects: Vec<Rect>,
    triangles: Vec<Triangle>,
}
// Each loop processes a uniform, tightly-packed array
```

### Arena allocation

Arenas batch allocations and free everything at once. Ideal for frame-scoped or phase-scoped
data in games and compilers:

```rust
use bumpalo::Bump;

fn process_frame(arena: &Bump, events: &[Event]) -> FrameResult {
    // All allocations from this arena are freed when `arena.reset()` is called
    let transforms = arena.alloc_slice_fill_default::<Transform>(entity_count);
    let commands = bumpalo::collections::Vec::new_in(arena);

    for event in events {
        // Fast bump allocation — just increment a pointer
        commands.push(process_event(event, transforms));
    }
    FrameResult { commands }
}
// At frame end: arena.reset(); — one operation frees everything
```

### Index handles with generational IDs

Prevent use-after-free with generational indices:

```rust
#[derive(Clone, Copy, PartialEq, Eq)]
struct Handle {
    index: u32,
    generation: u32,
}

struct Pool<T> {
    items: Vec<Option<T>>,
    generations: Vec<u32>,
    free_list: Vec<u32>,
}

impl<T> Pool<T> {
    fn get(&self, handle: Handle) -> Option<&T> {
        if self.generations[handle.index as usize] != handle.generation {
            return None;  // stale handle — slot has been reused
        }
        self.items[handle.index as usize].as_ref()
    }

    fn remove(&mut self, handle: Handle) -> Option<T> {
        let idx = handle.index as usize;
        if self.generations[idx] != handle.generation { return None; }
        self.generations[idx] += 1;  // invalidate all existing handles
        self.free_list.push(handle.index);
        self.items[idx].take()
    }
}
```

---

## Odin: Built-In SoA

Odin has SoA as a first-class language feature via the `#soa` directive:

```odin
Vector3 :: struct { x, y, z: f32 }

// AoS — normal array
entities_aos: [1000]Vector3

// SoA — same syntax, different memory layout
entities_soa: #soa[1000]Vector3

// Access looks identical:
entities_soa[0].x = 1.0    // accesses the x array at index 0
entities_soa.x[0] = 1.0    // equivalent — both syntaxes work

// The compiler proves they're the same:
assert(&entities_soa[0].x == &entities_soa.x[0])
```

No metaprogramming, no macros, no library — the language itself understands SoA. This is the
lowest-friction path to DOD in any modern language.

---

## Hot/Cold Splitting

Separate frequently-accessed fields from rarely-accessed fields:

```rust
// Before: one big struct
struct Entity {
    // HOT — every frame
    pos: Vec3, vel: Vec3,
    // WARM — every few frames
    health: f32, armor: f32,
    // COLD — rarely
    name: String, description: String, lore_id: u64,
}

// After: split by access frequency
struct EntityHot { pos: Vec3, vel: Vec3 }
struct EntityCold { name: String, description: String, lore_id: u64 }

struct World {
    hot: Vec<EntityHot>,     // tight loop over this
    health: Vec<f32>,        // separate warm data
    armor: Vec<f32>,
    cold: Vec<EntityCold>,   // rarely touched, fine if it's slow
}
```

The hot loop now iterates a 24-byte struct instead of a 100+ byte struct. Each cache line
holds 2-3x more useful data.

---

## Struct Packing and Alignment

### Padding wastes cache space

```rust
// Bad: 24 bytes due to padding
struct Bad {
    a: u8,   // 1 byte + 7 padding
    b: u64,  // 8 bytes
    c: u8,   // 1 byte + 7 padding
}

// Good: 16 bytes (or 10 with repr(packed), but beware alignment)
#[repr(C)]
struct Good {
    b: u64,  // 8 bytes (largest first)
    a: u8,   // 1 byte
    c: u8,   // 1 byte + 6 trailing padding
}
```

**Rule of thumb:** sort fields by alignment (largest first) to minimize padding. In Zig, the
compiler does this automatically for non-`extern` structs.

### Encoding booleans into enums

Instead of wasting a byte (or more, with padding) per boolean:

```zig
// Before: bool wastes space and has padding implications
const Creature = struct {
    kind: enum { elf, orc },
    is_alive: bool,
    health: u16,
};

// After: encode the boolean into the enum
const Creature = struct {
    state: enum { alive_elf, dead_elf, alive_orc, dead_orc },
    health: u16,
};
```

This was a technique Andrew Kelley demonstrated when optimizing the Zig compiler.

### Replace pointers with indices

On 64-bit systems, every pointer is 8 bytes. If your collection has fewer than 65,536 items,
a `u16` index is 4x smaller:

```rust
// Before: 8 bytes per reference
struct Node { parent: Option<*const Node>, ... }

// After: 2 bytes per reference
type NodeIdx = u16;
struct Node { parent: Option<NodeIdx>, ... }
struct Tree { nodes: Vec<Node> }  // index into this
```

This is the single most impactful DOD technique for pointer-heavy structures like trees,
graphs, and ASTs. The Zig compiler itself uses `u32` indices instead of pointers throughout
its AST representation.

---

## Batch Processing

Process data in bulk rather than one-at-a-time. This enables SIMD, amortizes function call
overhead, and keeps the instruction cache hot:

```rust
// Bad: process one at a time
for entity in &entities {
    entity.update(dt);  // virtual dispatch, scattered data
}

// Good: batch by operation
fn update_positions(pos: &mut [Vec3], vel: &[Vec3], dt: f32) {
    // Compiler can auto-vectorize this
    for (p, v) in pos.iter_mut().zip(vel.iter()) {
        p.x += v.x * dt;
        p.y += v.y * dt;
        p.z += v.z * dt;
    }
}

fn apply_gravity(vel: &mut [Vec3], gravity: f32, dt: f32) {
    for v in vel.iter_mut() {
        v.y -= gravity * dt;
    }
}
```

Organizing by operation (not by entity) makes patterns visible, enables vectorization, and
is the natural result of DOD + compression-oriented programming.

---

## Decision Guide

When designing a data structure, ask:

1. **How many?** If fewer than ~64, AoS is probably fine. If hundreds+, think SoA.
2. **Which fields are accessed together?** Group hot fields. Split cold fields.
3. **Pointers or indices?** If the collection can reallocate, indices are safer and smaller.
4. **Homogeneous or heterogeneous?** If all items are the same type, use a flat array. If
   there are variants, consider separate arrays per variant (existence-based) or tagged unions.
5. **Who owns the memory?** Consider arenas for phase-scoped data instead of individual allocs.
6. **Can this be batched?** Process arrays of data, not individual items.

---

## Key Sources

- Mike Acton, "Data-Oriented Design and C++" (CppCon 2014)
- Richard Fabian, *Data-Oriented Design* — dataorienteddesign.com
- Andrew Kelley, "Practical Data-Oriented Design" (Vimeo)
- Casey Muratori, "Clean Code, Horrible Performance" — computerenhance.com
- Casey Muratori, "Performance-Aware Programming" series
- Robert Nystrom, "Data Locality" in *Game Programming Patterns* — gameprogrammingpatterns.com
- Zig MultiArrayList deep-dive — andreashohmann.com/zig-struct-of-arrays
- Odin language SOA — odin-lang.org
- HackMD DOD notes (Roc compiler) — hackmd.io/@Q66MPiW4T7yNTKOCaEb-Lw/ryfenBCO5
