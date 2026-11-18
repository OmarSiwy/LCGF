# Gates

These are the original release criteria and the evidence available when the prototype was measured. The table preserves the status at that point. For the gates applied to the production framework and current measurements, use the benchmark documentation and CI results. [Production gates](../bench/gates/README.md) · [CI results](https://github.com/OmarSiwy/LCGF/blob/benchmark-results/README.md) · [Archived prototype](https://github.com/OmarSiwy/LCGF/tree/b6c1319/prototype)

| Gate | Definition | Measured by | At the original measurement | Kind |
|---|---|---|---|---|
| Frame CPU time | No slower than the fastest comparison framework on each benchmark scene, same machine. | bench-scenes and vs-* lanes | Prototype: about 0.34 ms for 3,961 nodes on one 2.1 GHz VM core. | Target |
| One-node change in 4,000 nodes | At most 5% of the full layout and paint time. | layout-incremental benchmark, damage tests | Prototype: full layout every frame. | Target |
| Memory of a static UI (comptime front end) | Only state, dynamic rects and a dirty mask in RAM; structure and style in read-only data. | ct-columns size report | Probe: 104 bytes of RAM for an 8-node UI. | Measured in probe |
| Memory of a dynamic UI (runtime front end) | At most the prototype's bytes per node, then lower with each measured change. | optimise lane | Prototype: about 0.65 KB per node of capacity. | Measured in prototype |
| Resident memory of an empty window | No more than the lightest comparison framework; a software back end must exist. | tools-bench probes | Reference: reports of 100 MB against 10 MB for wgpu against a thin back end. | Target |
| Binary size | A budget per example, set after the first measurement; growth above 2% fails CI. | tools-bench size report | Not measured yet. | Target |
| Embedded footprint | Label-and-button demo within LVGL's documented minimum flash class. | embedded budget tests | Reference: LVGL documents 64 kB flash as its minimum. | Target |
| Idle | Zero frames and zero wakeups while nothing changes. | scheduler idle test, idle scene | Prototype: needsFrame is false and wake is infinite when idle. | Measured in prototype |
| Time to first frame | No slower than the lightest comparison framework. | gates lane | Not measured yet. | Target |
| Branches in hot loops | Per-row loops contain loop-control jumps only. | tools-census | Prototype: true for every pass checked. | Measured in prototype |
| Portability | Tests pass at 4, 8 and 16 lanes; cross-compiles for five targets. | ci lane | Prototype: passes at 2, 4, 8 and 16 lanes (16 and 2 forced by hand: the std width query returns 8 even with AVX-512) and cross-compiles for five targets. | Measured in prototype |
| Accessibility | A screen reader announces every widget in the example on Windows, macOS and Linux. | a11y-bridge smoke tests | Prototype: role and value columns only. | Target |
| Text | Unicode segmentation, line breaking and bidi conformance files pass. | unicode lane | Prototype: fixed-advance font only. | Target |
| Compile time (comptime front end) | A budget per spec size, set after the first measurement. | ct-budget lane | Not measured yet. | Target |
| API quality | Every public function passes the nine-question checklist of the API design guide. | release lane review | Applied to the prototype by hand. | Target |
