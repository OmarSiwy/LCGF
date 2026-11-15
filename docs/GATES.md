# Gates

What "lighter and faster than everything else" means here. Each gate has a definition, the lane that measures it, and where the prototype stands today.
Kind says whether the last column is a measurement or a target that nothing has measured yet. A release is ready when the gates hold, not when the commit list is empty.

| Gate | Definition | Measured by | Where we are | Kind |
|---|---|---|---|---|
| Frame CPU time | No slower than the fastest comparison framework on each benchmark scene, same machine. | bench-scenes and vs-* lanes | Prototype today: about 0.34 ms for 3,961 nodes on one 2.1 GHz VM core. | Target |
| One-node change in 4,000 nodes | At most 5% of the full layout and paint time. | layout-incremental benchmark, damage tests | Prototype today: full layout every frame. | Target |
| Memory of a static UI (comptime front end) | Only state, dynamic rects and a dirty mask in RAM; structure and style in read-only data. | ct-columns size report | Probe today: 104 bytes of RAM for an 8-node UI. | Measured in probe |
| Memory of a dynamic UI (runtime front end) | At most the prototype's bytes per node, then lower with each measured change. | optimise lane | Prototype today: about 0.65 KB per node of capacity. | Measured in prototype |
| Resident memory of an empty window | No more than the lightest comparison framework; a software back end must exist. | tools-bench probes | Reference: reports of 100 MB against 10 MB for wgpu against a thin back end. | Target |
| Binary size | A budget per example, set after the first measurement; growth above 2% fails CI. | tools-bench size report | Not measured yet. | Target |
| Embedded footprint | Label-and-button demo within LVGL's documented minimum flash class. | embedded budget tests | Reference: LVGL documents 64 kB flash as its minimum. | Target |
| Idle | Zero frames and zero wakeups while nothing changes. | scheduler idle test, idle scene | Prototype today: needsFrame is false and wake is infinite when idle. | Measured in prototype |
| Time to first frame | No slower than the lightest comparison framework. | gates lane | Not measured yet. | Target |
| Branches in hot loops | Per-row loops contain loop-control jumps only. | tools-census | Prototype today: true for every pass checked. | Measured in prototype |
| Portability | Tests pass at 4, 8 and 16 lanes; cross-compiles for five targets. | ci lane | Prototype today: passes at 2, 4, 8 and 16 lanes (16 and 2 forced by hand: the std width query returns 8 even with AVX-512) and cross-compiles for five targets. | Measured in prototype |
| Accessibility | A screen reader announces every widget in the example on Windows, macOS and Linux. | a11y-bridge smoke tests | Prototype today: role and value columns only. | Target |
| Text | Unicode segmentation, line breaking and bidi conformance files pass. | unicode lane | Prototype today: fixed-advance font only. | Target |
| Compile time (comptime front end) | A budget per spec size, set after the first measurement. | ct-budget lane | Not measured yet. | Target |
| API quality | Every public function passes the nine-question checklist of the API design guide. | release lane review | Applied to the prototype by hand. | Target |
