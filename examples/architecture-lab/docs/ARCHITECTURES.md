# Choosing and extending an architecture

This lab implements five application structures over the same LCGF interface and record workload. The differences are **who owns state, who accepts actions, and who controls navigation**. They share the feature views, record columns, business rules, virtualization, and renderer so those concerns do not accidentally decide the comparison.

**MVVP is explicitly a project-defined hybrid here:** Model–View–ViewModel–Presenter. Its presenter coordinates a model and a presentation-state owner. It is a separate implementation from the standard **MVVM** variant, which is also included. Read the ownership contracts below instead of inferring behavior from an acronym.

## Select a build

The build option is a compile-time choice:

```sh
zig build run -Darchitecture=viper -Doptimize=ReleaseFast
zig build run -Darchitecture=mvp -Doptimize=ReleaseFast
zig build run -Darchitecture=mvvp -Doptimize=ReleaseFast
zig build run -Darchitecture=mvvm -Doptimize=ReleaseFast
zig build run -Darchitecture=mvvm_c -Doptimize=ReleaseFast
```

Use the same choice with other application steps, for example:

```sh
zig build test -Darchitecture=mvvm_c
zig build bench -Darchitecture=mvvm_c -Doptimize=ReleaseFast
zig build snapshot -Darchitecture=mvvm_c -- mvvm-c.ppm
```

The supplied desktop host uses Linux/X11; the headless steps do not need a display. Match the exact Zig version and dependency pin in the project manifest. The architecture selection does not change the compiler or renderer.

## Precise ownership

| Variant | Persistent owners | Command handling | Owner of the selected page |
|---|---|---|---|
| **VIPER** | `App` directly owns sidebar state, top-bar state, workspace state, and projection cache. | Feature interactors apply local actions; feature routers return application requests; `App` dispatches them. | `App.page`. |
| **MVP** | `App.model` is one state aggregate containing the domain model, chrome, page, and cache. | The stateless presenter queries that state, calls the passive view, and commits its actions. | The model state; the presenter changes it. |
| **MVVP** | `App.model` owns shared feature data. `App.view_model` owns chrome, page, cache, and command-error state. | The ViewModel applies local chrome commands and emits requests. The presenter applies domain and navigation operations. | The ViewModel stores it; the presenter controls changes. |
| **MVVM** | `App.model` owns shared feature data. `App.view_model` owns chrome, page, cache, and command-error state. | The view reads a projection and sends its command result to the ViewModel. The ViewModel invokes model use cases directly. | The ViewModel owns and changes it. |
| **MVVM-C** | `App` owns the model, feature ViewModel, and coordinator as separate values. | The ViewModel handles feature commands and returns application requests. The coordinator interprets application flow. | `Coordinator.page` only. |

“Owns” means an ordinary Zig struct contains the data. None of these variants requires a heap object, runtime interface, observer graph, callback registry, or pointer from every component back to the application.

The shared feature model deliberately retains the existing workspace's record store, selection, and scroll state. This makes the lab a comparison of **application orchestration over one feature implementation**. It does not claim that every implementation makes a different decision about every field. In a larger application, selection and scroll can move into a feature ViewModel if that boundary better matches the product.

### Start at these files

| Structure | Entry point and control boundary |
|---|---|
| VIPER | [`src/app.zig`](../src/app.zig), then [`src/modules/`](../src/modules/). |
| MVP | [`mvp/root.zig`](../src/architectures/mvp/root.zig), [`mvp/presenter.zig`](../src/architectures/mvp/presenter.zig). |
| MVVP | [`mvvp/root.zig`](../src/architectures/mvvp/root.zig), [`mvvp/view_model.zig`](../src/architectures/mvvp/view_model.zig), [`mvvp/presenter.zig`](../src/architectures/mvvp/presenter.zig). |
| MVVM | [`mvvm/root.zig`](../src/architectures/mvvm/root.zig), [`mvvm/view.zig`](../src/architectures/mvvm/view.zig), [`mvvm/view_model.zig`](../src/architectures/mvvm/view_model.zig). |
| MVVM-C | [`mvvm_c/root.zig`](../src/architectures/mvvm_c/root.zig), [`mvvm_c/view_model.zig`](../src/architectures/mvvm_c/view_model.zig), [`mvvm_c/coordinator.zig`](../src/architectures/mvvm_c/coordinator.zig). |
| Shared domain | [`architectures/domain.zig`](../src/architectures/domain.zig). |
| Shared composition and observations | [`architectures/common.zig`](../src/architectures/common.zig). |

`common.draw` builds the same layout and calls the same feature view functions. It returns commands and performs no action dispatch. Each alternative architecture owns its command phase. The original VIPER root composes those feature views directly.

## Follow one action through the variants

Clicking **Advance** produces the same top-bar action in every variant. The workspace's shared interactor performs the same contiguous progress update.

| Variant | Path from the emitted top-bar action to the domain operation |
|---|---|
| VIPER | `App.commit` → top-bar router → `App.route(.advance)` → workspace interactor. |
| MVP | Presenter `commit` interprets `.advance` and calls `model.apply(.advance)`. |
| MVVP | ViewModel `topbarCommand` returns a request → presenter `apply`/`route` → `model.apply(.advance)`. |
| MVVM | View calls ViewModel `accept` → ViewModel `commit` → `model.apply(.advance)`. |
| MVVM-C | Coordinator `commit` asks the ViewModel to interpret the action → coordinator routes the request → ViewModel `workspaceCommand` → model. |

Navigation exposes the distinction more clearly. In MVVM, navigation is a ViewModel operation. In MVVM-C, the feature ViewModel has no page field and cannot navigate by itself; it emits a request. In this MVVP hybrid, the page is stored in the ViewModel but changed by the presenter. Those are explicit ownership choices, not different names for one controller.

## The frame and command contract

Every variant follows the same boundary:

1. Refresh the derived projection when its inputs changed.
2. Give the views a read-only projection of the committed state.
3. Collect typed actions in fixed-capacity batches.
4. Reject the complete input batch if a view reports command overflow.
5. Apply successful commands in the order **sidebar, top bar, workspace**.
6. Request another frame when state changed.

A read-only projection is a temporary borrow, not a deep copy of 100,000 records. Views finish using it before commands mutate the model or invalidate the cache.

Navigation wins over a scroll action produced by the previous page's view. Each implementation records the old page and skips that stale scroll if navigation changes the page during the same batch. A selection action still carries a stable `ItemId`, so it can remain meaningful across the page change. This ordering is part of the behavior contract and is exercised in [`architecture_tests.zig`](../src/architecture_tests.zig).

The command boundary returns whether a change occurred. Do not write `changed or reduce(...)`: short-circuiting can skip a later action once `changed` is true. Evaluate the reducer first, as the implementations do.

The ordinary build wrappers call `ctx.waker.post()` after committing changes. That matters because `Frame.finish()` clears LCGF signal dirtiness. If an external host or test calls `commit` directly, it owns the scheduling step too; the returned boolean does not independently wake an OS event wait.

Command overflow rejection is not a general transaction over rendering or external effects. A later LCGF output-capacity error remains a host outcome. Expensive I/O needs its own explicit request/completion boundary.

## Data and memory rules shared by all five

### Keep large passes contiguous

The record store uses fixed-capacity progress and active columns. The presenter cache holds filtered `u32` storage indices, not copies of entire records. Small sidebar and top-bar state remain ordinary structs.

Filtering and advancing records are O(N) domain/projection passes. Drawing formats and emits only visible rows. An architecture wrapper does not change those costs. A pointer move or scroll with the same page and revision does not invalidate the filtered projection.

### Treat capacities as part of the API

`Buffer(Action, 8)` owns eight inline action slots and exposes only its live prefix through `items()`. `append` returns `error.Full`; it cannot silently grow or discard an action. The application owns LCGF's node, text, string, and other budgets separately.

Keep action payloads as values, stable IDs, or explicitly owned handles. A `[]const u8` inside a command does not own its bytes. For editable text, either copy into a bounded payload, arrange owner-backed storage, or drain before the borrowed storage expires under a documented contract.

### Keep borrows short

| Value | Validity rule |
|---|---|
| Projection/feature model slices | Consume before the store or cache is mutated or moved. |
| `Commands.items()` | Borrows its command buffer; consume while that buffer remains alive. |
| Formatted stack label | Safe for an LCGF text call that copies bytes immediately; unsafe to retain as a pointer. |
| LCGF `Node`, tree, draw output | Frame/context storage; do not keep as persistent domain state. |
| Context's backing buffer | Must stay at the address from which the context carved its columns. |

All five roots, including VIPER's `App`, expose a `snapshot()` method for read-only test/benchmark observations. It borrows the live progress/active columns. Its `completed`, `visible_count`, and projection-build fields describe the **last projection**, which can lag a just-committed command until another projection is built.

The cache belongs to one store. Replacing that store requires invalidation even if its revision happens to match. Current filters preserve storage order, enabling binary search for a selected ID's visible position. A future arbitrary sort needs an appropriate reverse mapping or search rule.

## Add a module like the sidebar or top bar

Suppose a right-hand **inspector** needs a local expanded/collapsed setting and a button that navigates to the running-jobs page. Give it a feature directory under `src/modules/inspector/` and keep its local behavior independent of the selected application structure.

### 1. Define state and owned intent

In `entity.zig`:

```zig
const navigation = @import("../../core/navigation.zig");

pub const State = struct {
    expanded: bool = true,
};

pub const Action = union(enum) {
    set_expanded: bool,
    navigate: navigation.Page,
};
```

The local reducer handles `.set_expanded`, returns `false` for the same value, and leaves navigation to the owning architecture. The VIPER router translates `.navigate` into the existing shared navigation request. Other variants interpret the same action at their command boundary.

### 2. Project the information to display

Use a small presenter model such as `Model { expanded: bool, title: []const u8 }`. Its title must borrow bytes owned by the caller for the duration of drawing. Do not duplicate the entire workspace in the inspector. For selected-record content, pass stable IDs and the required values or a const borrow.

### 3. Draw and emit commands

The view has the same contract as the sidebar/top bar:

```zig
const button = @import("../../ui/button.zig");

pub fn draw(
    frame: *lcgf.frame.Frame,
    theme: *const lcgf.widgets_base.Theme,
    model: presenter.Model,
    commands: *Buffer(entity.Action, 8),
) error{Full}!void {
    _ = frame.open(.from("inspector"), .{
        .size = .{ .px(220), .fill },
        .pad = @splat(12),
        .gap = 8,
        .fill = theme.panel,
    });
    defer frame.close();

    _ = lcgf.widgets_base.label(frame, theme, model.title);
    var expanded = model.expanded;
    _ = lcgf.widgets_base.checkbox(
        frame, theme, .from("inspector.expanded"), &expanded, "Show details",
    );
    if (expanded != model.expanded)
        try commands.append(.{ .set_expanded = expanded });
    if (button.draw(
        frame, theme, .from("inspector.running"), "Show running jobs",
    ).clicked)
        try commands.append(.{ .navigate = .running });
}
```

Use the same imports and `root.zig` facade pattern as the existing modules. The shared button helper supplies Enter/Space activation and a visible keyboard focus border. A mutable widget receives a local draft, and the interactor receives the action afterward. `defer frame.close()` keeps nesting balanced if the command buffer fills.

Namespaced IDs prevent unrelated controls from colliding. For multiple inspector instances, take a root ID as an argument and derive children with `Id.with(...)` instead of reusing fixed names.

### 4. Choose the owner and command handler

| Variant | Put inspector state here | Apply its actions here |
|---|---|---|
| VIPER | `src/app.zig`'s `App`. | Add an inspector dispatch method using its interactor/router. |
| MVP | The aggregate state in `common.State` / `mvp/model.zig`. | `mvp/presenter.zig`'s commit phase. |
| MVVP | Its `ViewModel`. | Local expansion in a ViewModel command method; navigation returned to its presenter. |
| MVVM | Its `ViewModel`. | A ViewModel command method can apply expansion and invoke navigation directly. |
| MVVM-C | Its feature `ViewModel`. | Local expansion in the ViewModel; a navigation request resolved by the coordinator. |

For an extension that exists across the whole lab, add the inspector model to `common.Projection`, its batch to `common.Commands`, and its draw call to `common.draw`. Update every variant's commit interface and forwarding calls. Also update the original VIPER composition in `src/app.zig`, which does not call `common.draw`. Preserve a documented batch order and the common failure boundary.

If building only one chosen architecture for a product, extend its composition and command boundary directly; maintaining all five variants is a comparison-lab concern.

### 5. Test the useful contract

Test an actual local state change, a no-op update, and the navigation request. Add a real LCGF input scenario that activates the view and verifies the follow-up frame. When extending all variants, add the same scenario to the cross-architecture contract so their state, draw commands, text, wake behavior, and ordering remain equivalent.

For the full VIPER file-by-file recipe, see [Adding modules](ADDING_MODULES.md). Decorative cards, labels, and progress bars can remain plain view helpers; they need no separate state owner or router.

## Choosing for your application

| Structure | Useful when | Main maintenance cost |
|---|---|---|
| VIPER | A feature has substantial use cases and navigation that benefit from explicit boundaries. | More files and forwarding; trivial features should remain helpers. |
| MVP | One presenter can clearly coordinate a passive view and its model. | A growing presenter can accumulate unrelated feature and navigation responsibilities. |
| MVVP hybrid | You deliberately want a separate projection/chrome owner and an explicit presenter coordinating domain operations. | Team members must learn this project's precise hybrid contract. |
| MVVM | Presentation state and user commands belong naturally in one ViewModel. | Keep domain rules in the model/use cases as the ViewModel grows. |
| MVVM-C | Several screens, flows, or reusable feature ViewModels need one navigation owner. | Coordinator requests and forwarding add structure that a small single-screen app may not need. |

These are structural tradeoffs. There is no speed winner implied by the acronym. All five use static calls and the same large data passes; optimized code may erase much of the forwarding. Actual timings can also be dominated by text, layout, software pixel shading, or presentation instead of controller work.

Compare equivalent workloads with fixed compiler, optimization mode, CPU target, data size, and viewport. Separate command dispatch, projection scans, UI build/layout, software rendering, and complete frames. Treat small differences near measurement noise as inconclusive, and choose the structure whose ownership remains clearest as the product grows.
