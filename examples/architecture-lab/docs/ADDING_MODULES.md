# Adding and splitting modules

## Decide what owns behavior

A **module** owns a coherent feature: an inspector, document tab strip, search panel, or workspace. It has state or use cases that deserve independent tests.

A **view helper** is a visual building block: a labeled value, toolbar button, card, or progress bar. Give it a function and pass its data in. It does not need an entity, interactor, presenter, and router merely to satisfy an acronym.

Start with this question: *If this component changes, what state and behavior should remain independently understandable?* Use that answer as the module boundary. A sidebar and top bar are separate here because their local behavior differs, while their application requests meet at the coordinator.

## Worked example: an inspector control

Suppose a right-hand inspector displays the selected workspace item and has a pin setting. The example below implements that setting and its visual control; capturing a particular item's ID is the next domain operation. The workspace still owns records and selection. The coordinator decides which item the inspector receives.

Create `src/modules/inspector/` and use the existing feature directories as the file pattern. The following small example shows the responsibilities; integrate it through the coordinator as described afterward.

### 1. Define owned state and intent

In `entity.zig`:

```zig
pub const State = struct {
    pinned: bool = false,
};

pub const Action = union(enum) {
    set_pinned: bool,
};
```

The action describes an explicit desired value. Applying `.set_pinned = true` twice has the same result as applying it once, which is useful when replaying or coalescing commands. A `.toggle` action is also valid when toggling itself is the intended operation.

In a complete pinned inspector, retain the pinned item's stable ID as well. Put that identity contract in a shared domain file if multiple features need it; do not import a sibling's UI implementation.

### 2. Apply the invariant in the interactor

In `interactor.zig`:

```zig
const entity = @import("entity.zig");

pub fn reduce(state: *entity.State, action: entity.Action) bool {
    return switch (action) {
        .set_pinned => |value| blk: {
            if (state.pinned == value) break :blk false;
            state.pinned = value;
            break :blk true;
        },
    };
}
```

Returning whether state changed lets the coordinator wake a frame only when needed. Validate domain constraints here. If an item ID does not exist, reject it here or return a typed failure that the caller can present.

### 3. Project only what the view needs

In `presenter.zig`:

```zig
const entity = @import("entity.zig");

pub const Model = struct {
    pinned: bool,
    title: []const u8,
};

pub fn make(state: *const entity.State, title: []const u8) Model {
    return .{ .pinned = state.pinned, .title = title };
}
```

`title` borrows the caller's bytes and is consumed during drawing. Never construct a model containing a slice into a presenter's local array and return it: that array's lifetime ends at return. Return an inline buffer with its length, use caller-owned storage, or format the label inside the view.

Do not copy the whole workspace into this model. Pass the selected record's small value fields or a read-only view with a clear lifetime.

### 4. Build a view that emits actions

In `view.zig`:

```zig
const lcgf = @import("lcgf");
const entity = @import("entity.zig");
const presenter = @import("presenter.zig");
const Buffer = @import("../../core/commands.zig").Buffer;
const widgets = lcgf.widgets_base;

pub fn draw(
    frame: *lcgf.frame.Frame,
    theme: *const widgets.Theme,
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

    _ = widgets.label(frame, theme, model.title);
    var pinned = model.pinned;
    _ = widgets.checkbox(
        frame, theme, .from("inspector.pin"), &pinned, "Pin inspector",
    );
    if (pinned != model.pinned)
        try commands.append(.{ .set_pinned = pinned });
}
```

The checkbox can mutate its local draft without mutating the entity. `defer frame.close()` keeps the LCGF nesting balanced even if appending an action fails.

Give every interactive widget a namespaced, stable ID. For repeated inspector fields, derive child IDs from their domain keys with `Id.with(key)`. If the application has two inspector instances, pass a root ID into the view and derive both instances' child IDs from their respective roots.

### 5. Keep the router small

This inspector's only action is local, so `router.zig` can return `null` for every action:

```zig
const entity = @import("entity.zig");
const navigation = @import("../../core/navigation.zig");

pub fn route(_: entity.Action) ?navigation.Request {
    return null;
}
```

If it later offers “Show item in workspace,” add a shared request carrying the stable item ID. The coordinator handles that request and calls the relevant workspace operation. The inspector still does not import the workspace.

Expose `State`, `Action`, `Commands`, and the implementation namespaces from `root.zig`, following the sidebar or top-bar facade.

## Integrate through the coordinator

Make the additions in `src/app.zig` in the same places as the existing modules:

1. Import the inspector facade and add its owned state to `App`.
2. Create its command batch alongside the existing per-frame batches.
3. Make its model from const state and compose its view in the body layout.
4. Propagate a view/command error through the existing failure path before applying any actions.
5. Drain successful actions through its interactor and router, accumulating the `changed` result.
6. Use the coordinator's existing wake path when any state changed.

For expensive derived content, add a presenter cache with an explicit revision key. Cache calculations that are actually costly, and include every input that can change their result. A cache keyed only by store revision will become stale if its filter or sort order changes.

## Split a growing component by data and behavior

Suppose the workspace grows a table, details pane, graph, and command palette. Keep `workspace/view.zig` as composition code, and extract their views into small files. Promote a part into its own module when it gains independent state or use cases.

Do not make every child a pointer-bearing object. Pass const models down and actions up. Keep large data in shared stores owned at an appropriate application level; child modules retain IDs or selection/filter state, not cloned datasets.

For a custom canvas, use `Frame.custom` to reserve its layout rectangle. Put a small handle in its payload, and have the host draw that content at the corresponding custom command. Keep graphics resources in the host or renderer owner. A frame-local node pointer is not a durable canvas handle.

## Verify behavior that can actually break

Add tests for the inspector's state transition and no-op reduction. Then add one integration test that activates its real LCGF control and checks the entity, another frame is scheduled, and the updated state is displayed.

For a list or table, test selection identity across filtering, keyboard navigation, a scroll far from the first row, and bounded node count. For an editable field, test invalid input and temporary-buffer lifetimes. For any added memoization, test keyboard focus and activation with the pointer elsewhere.

Run `zig build test check` and the relevant benchmark after integration. A new module is complete when its ownership, mutation boundary, capacity behavior, and observed UI behavior are understandable and verified.
