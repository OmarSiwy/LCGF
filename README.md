# GUI framework benchmark results

Measured 2026-11-28 03:29 UTC at [`6b720d28e0`](https://github.com/OmarSiwy/LCGF/commit/6b720d28e0a5873c15ef2d07d31c7413682af67e). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46099466367)

AMD EPYC 7763 64-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.8.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.3 µs | 1 µs (LVGL) | 0.300 |
| List frame median | 10.5 µs | 5.8 µs (microui) | 1.810 |
| Text frame median | 0.1 µs | 1.5 µs (LVGL) | 0.067 |
| Springs frame median | 38.5 µs | 20.9 µs (microui) | 1.842 |
| Resize frame median | 12.1 µs | 30.8 µs (microui) | 0.393 |
| First frame | 0.46 ms | 0.449 ms (Nuklear) | 1.025 |
| Idle resident memory | 400 KiB | 416 KiB (Nuklear) | 0.962 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.3 / 16.6 | 10.5 / 18.1 | 0.1 / 0.1 | 38.5 / 50.3 | 12.1 / 20.0 | 0.3 / 0.3 |
| Clay | 38.4 / 49.0 | 30.9 / 40.2 | 44.6 / 54.5 | 162.4 / 180.6 | 44.2 / 54.3 | 38.4 / 47.2 |
| Dear ImGui | 22.4 / 31.4 | 15.3 / 23.7 | 125.1 / 138.6 | 74.7 / 88.1 | 112.2 / 187.5 | 22.5 / 31.5 |
| egui | 262.7 / 441.4 | 307.8 / 366.9 | 149.1 / 180.8 | 375.7 / 423.4 | 376.8 / 478.0 | 0.0 / 0.0 |
| Iced | 30.2 / 41.5 | 157.7 / 243.4 | 26.9 / 37.3 | 212.2 / 247.3 | 186.7 / 377.4 | 0.0 / 0.0 |
| LVGL | 1.0 / 1.2 | 1104.2 / 1282.3 | 1.5 / 2.7 | 4239.4 / 4510.9 | 2643.8 / 5161.5 | 0.3 / 0.4 |
| Slint | 31.7 / 475.0 | 1830.6 / 1985.3 | 18.8 / 27.5 | 6742.2 / 7271.1 | 3092.0 / 6690.2 | 0.2 / 0.3 |
| Qt Quick | 77.0 / 100.5 | 143.4 / 168.9 | 158.3 / 187.3 | 15430.5 / 22744.5 | 240.3 / 2623.0 | 3.3 / 3.5 |
| Nuklear | 12.5 / 20.2 | 8.2 / 10.4 | 82.9 / 209.3 | 39.3 / 50.2 | 83.7 / 208.9 | 12.4 / 19.6 |
| microui | 13.5 / 21.1 | 5.8 / 6.9 | 30.3 / 38.0 | 20.9 / 28.4 | 30.8 / 50.4 | 13.5 / 21.3 |
| GTK 4 | 50.5 / 94.0 | 4501.4 / 15275.4 | 67.9 / 96.0 | 1756.9 / 4212.5 | 3356.9 / 7968.0 | 2.6 / 3.4 |
| Qt Widgets | 5357.9 / 5699.0 | 685.4 / 777.6 | 1656.2 / 1827.1 | 12493.8 / 19939.1 | 7512.6 / 9921.2 | 1.6 / 1.7 |

## Polls that produced a frame

Median count per 3,000 polls. Retained toolkits can reuse their previous output. The time table includes the polls they skipped.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 908 | 3000 | 2 | 3000 | 3000 | 2 |
| Clay | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| Dear ImGui | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| egui | 3000 | 3000 | 3000 | 3000 | 3000 | 3 |
| Iced | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |
| LVGL | 1 | 3000 | 1 | 1882 | 3000 | 1 |
| Slint | 751 | 3000 | 1 | 3000 | 3000 | 1 |
| Qt Quick | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Nuklear | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| microui | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| GTK 4 | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Qt Widgets | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |

## Resident memory by workload

Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. Linux reports its resident pages after 3,000 polls and the highest resident count since launch. Both columns are medians across runs and include resident shared pages.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 508 / 508 | 492 / 492 | 504 / 504 | 1,496 / 1,496 | 504 / 504 | 508 / 508 |
| Clay | 2,140 / 2,140 | 2,124 / 2,124 | 2,128 / 2,128 | 2,444 / 2,444 | 2,132 / 2,132 | 2,140 / 2,140 |
| Dear ImGui | 3,636 / 3,636 | 3,640 / 3,640 | 3,928 / 3,928 | 3,820 / 3,820 | 4,348 / 4,432 | 3,636 / 3,636 |
| egui | 7,188 / 7,508 | 7,284 / 7,284 | 8,080 / 8,100 | 6,032 / 6,032 | 9,208 / 9,208 | 7,424 / 7,508 |
| Iced | 5,744 / 5,744 | 5,668 / 5,668 | 8,316 / 8,316 | 4,688 / 4,688 | 10,120 / 10,120 | 5,732 / 5,732 |
| LVGL | 3,556 / 3,556 | 3,476 / 3,476 | 3,492 / 3,492 | 3,684 / 3,684 | 3,504 / 3,504 | 3,556 / 3,556 |
| Slint | 13,952 / 13,952 | 15,564 / 15,564 | 15,836 / 15,836 | 13,652 / 13,652 | 20,948 / 20,948 | 13,928 / 13,928 |
| Qt Quick | 68,736 / 68,736 | 67,692 / 67,692 | 70,308 / 70,308 | 939,188 / 939,188 | 77,612 / 96,084 | 66,848 / 66,848 |
| Nuklear | 2,648 / 2,648 | 2,636 / 2,636 | 2,648 / 2,648 | 2,664 / 2,664 | 2,648 / 2,648 | 2,648 / 2,648 |
| microui | 2,656 / 2,656 | 2,656 / 2,656 | 2,656 / 2,656 | 2,660 / 2,660 | 2,656 / 2,656 | 2,656 / 2,656 |
| GTK 4 | 42,848 / 46,320 | 51,608 / 55,392 | 42,724 / 50,468 | 44,596 / 46,784 | 44,884 / 44,884 | 42,752 / 46,300 |
| Qt Widgets | 36,716 / 36,716 | 39,588 / 39,588 | 38,700 / 38,700 | 59,028 / 59,028 | 47,808 / 56,136 | 36,756 / 36,756 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.460 | 400 | 400 | 0.0 | 68,407 | 33,736 | 0 |
| Clay | 0.485 | 424 | 424 | 0.0 | 99,530 | 100,936 | 2,457,760 |
| Dear ImGui | 1.296 | 3548 | 3548 | 0.0 | 757,415 | 61,104 | 3,377,608 |
| egui | 4.284 | 7088 | 7444 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 5.920 | 5712 | 5712 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 4.086 | 3448 | 3448 | 30.0 | 659,329 | 1,021,920 | 2,457,760 |
| Slint | 39.163 | 13924 | 13924 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 93.915 | 66840 | 66840 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.449 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.480 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 106.871 | 42740 | 46320 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 54.068 | 36776 | 36776 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 7.79 / 9.83 | 2.72 / 3.15 | 7.69 / 9.55 |
| Clay | 7.03 / 8.32 | 2.46 / 3.17 | 6.50 / 11.99 |
| Dear ImGui | 7.24 / 8.79 | 2.43 / 2.91 | 6.36 / 9.99 |
| egui | 7.66 / 8.61 | 2.60 / 2.80 | 6.93 / 9.81 |
| Iced | 7.60 / 9.31 | 2.64 / 2.89 | 7.83 / 10.97 |
| LVGL | 7.09 / 8.58 | 2.54 / 3.10 | 6.97 / 9.94 |
| Slint | 10.50 / 11.19 | 2.46 / 2.82 | 10.57 / 11.92 |
| Qt Quick | 14.83 / 15.81 | 7.64 / 8.08 | 23.00 / 25.61 |
| Nuklear | 6.38 / 7.71 | 2.46 / 2.93 | 6.01 / 7.27 |
| microui | 6.52 / 7.14 | 2.40 / 2.90 | 5.92 / 7.20 |
| GTK 4 | 39.99 / 40.62 | 19.04 / 21.58 | 34.29 / 36.88 |
| Qt Widgets | 15.86 / 16.70 | 7.70 / 8.23 | 23.81 / 25.80 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/6b720d28e0a5873c15ef2d07d31c7413682af67e/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/6b720d28e0a5873c15ef2d07d31c7413682af67e/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
