# GUI framework benchmark results

Measured 2026-11-28 00:23 UTC at [`71cae28e80`](https://github.com/OmarSiwy/LCGF/commit/71cae28e806e6f1a58cddf300313a11d16205dd9). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46084493691)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.6 to 1.9.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 8.9 µs | 4.7 µs (microui) | 1.894 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 38.3 µs | 16.9 µs (microui) | 2.266 |
| Resize frame median | 10.2 µs | 24.3 µs (microui) | 0.420 |
| First frame | 0.407 ms | 0.375 ms (Nuklear) | 1.085 |
| Idle resident memory | 404 KiB | 412 KiB (Nuklear) | 0.981 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.3 | 8.9 / 14.4 | 0.1 / 0.1 | 38.3 / 48.8 | 10.2 / 16.6 | 0.1 / 0.1 |
| Clay | 32.3 / 40.5 | 26.0 / 34.5 | 36.6 / 45.7 | 122.4 / 140.4 | 36.6 / 45.4 | 32.3 / 40.6 |
| Dear ImGui | 16.2 / 24.3 | 12.3 / 18.9 | 96.3 / 109.3 | 68.2 / 78.3 | 91.4 / 147.1 | 16.2 / 23.4 |
| egui | 202.9 / 354.1 | 243.3 / 276.4 | 115.3 / 131.6 | 285.7 / 309.4 | 282.1 / 350.8 | 0.0 / 0.0 |
| Iced | 24.9 / 33.0 | 123.1 / 182.8 | 21.8 / 29.7 | 166.3 / 185.0 | 145.3 / 262.3 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.2 | 832.9 / 954.8 | 1.2 / 2.1 | 3572.1 / 3672.4 | 2012.8 / 3880.7 | 0.3 / 0.3 |
| Slint | 25.2 / 320.4 | 1442.7 / 1502.0 | 15.2 / 22.9 | 5595.0 / 5767.8 | 2464.5 / 5075.3 | 0.2 / 0.2 |
| Qt Quick | 59.3 / 75.6 | 90.6 / 106.1 | 100.1 / 116.1 | 12491.7 / 17401.0 | 160.6 / 2194.0 | 2.7 / 3.0 |
| Nuklear | 8.9 / 15.6 | 6.1 / 6.9 | 64.1 / 74.2 | 27.7 / 35.3 | 64.4 / 79.1 | 8.9 / 15.0 |
| microui | 10.3 / 17.2 | 4.7 / 4.8 | 23.8 / 31.4 | 16.9 / 24.3 | 24.3 / 39.1 | 10.3 / 16.7 |
| GTK 4 | 41.2 / 57.5 | 2842.7 / 11533.6 | 32.8 / 48.6 | 1282.4 / 2774.5 | 2271.9 / 5427.3 | 2.6 / 2.8 |
| Qt Widgets | 1856.9 / 1966.5 | 552.4 / 594.8 | 1473.0 / 1559.0 | 8900.7 / 10951.8 | 5571.3 / 7467.2 | 1.4 / 1.5 |

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
| Slint | 695 | 3000 | 1 | 3000 | 3000 | 1 |
| Qt Quick | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Nuklear | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| microui | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| GTK 4 | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |
| Qt Widgets | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |

## Resident memory by workload

Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. Linux reports its resident pages after 3,000 polls and the highest resident count since launch. Both columns are medians across runs and include resident shared pages.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 512 / 512 | 492 / 492 | 508 / 508 | 1,496 / 1,496 | 508 / 508 | 512 / 512 |
| Clay | 2,140 / 2,140 | 2,124 / 2,124 | 2,128 / 2,128 | 2,444 / 2,444 | 2,132 / 2,132 | 2,140 / 2,140 |
| Dear ImGui | 3,644 / 3,644 | 3,648 / 3,648 | 3,936 / 3,936 | 3,828 / 3,912 | 4,356 / 4,444 | 3,644 / 3,644 |
| egui | 7,252 / 7,572 | 7,348 / 7,348 | 8,144 / 8,164 | 6,096 / 6,096 | 9,272 / 9,272 | 7,488 / 7,572 |
| Iced | 5,808 / 5,808 | 5,732 / 5,732 | 8,372 / 8,372 | 4,752 / 4,752 | 10,184 / 10,184 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,900 / 15,900 | 13,720 / 13,720 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,796 / 68,796 | 67,756 / 67,756 | 70,376 / 70,376 | 939,252 / 939,252 | 76,416 / 93,924 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,924 / 46,384 | 51,744 / 55,712 | 42,792 / 50,532 | 44,644 / 46,848 | 44,980 / 44,980 | 42,836 / 46,384 |
| Qt Widgets | 36,772 / 36,772 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 46,596 / 54,912 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.407 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.404 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.132 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.945 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.260 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.212 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 29.964 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 79.193 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.375 | 412 | 412 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.406 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 83.217 | 42788 | 46364 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 40.932 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.10 / 7.26 | 2.35 / 2.68 | 5.96 / 7.46 |
| Clay | 5.99 / 7.64 | 2.41 / 2.87 | 5.31 / 5.79 |
| Dear ImGui | 7.10 / 7.44 | 2.47 / 2.70 | 5.70 / 5.98 |
| egui | 6.89 / 7.51 | 2.44 / 2.74 | 5.67 / 6.59 |
| Iced | 6.35 / 6.71 | 2.42 / 2.57 | 5.78 / 6.10 |
| LVGL | 5.57 / 6.49 | 2.40 / 2.59 | 5.39 / 5.75 |
| Slint | 8.35 / 9.26 | 2.46 / 2.83 | 8.69 / 10.39 |
| Qt Quick | 12.86 / 13.17 | 6.64 / 6.83 | 16.21 / 17.30 |
| Nuklear | 6.08 / 6.31 | 2.40 / 2.76 | 5.31 / 5.86 |
| microui | 6.15 / 6.32 | 2.39 / 2.60 | 5.16 / 5.71 |
| GTK 4 | 35.72 / 36.22 | 11.72 / 13.28 | 27.95 / 30.33 |
| Qt Widgets | 13.35 / 13.73 | 6.67 / 6.92 | 15.40 / 16.27 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/71cae28e806e6f1a58cddf300313a11d16205dd9/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/71cae28e806e6f1a58cddf300313a11d16205dd9/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
