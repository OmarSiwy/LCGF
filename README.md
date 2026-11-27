# GUI framework benchmark results

Measured 2026-11-27 22:42 UTC at [`b729391c32`](https://github.com/OmarSiwy/LCGF/commit/b729391c324a52773aded40a141eec7617809411). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46074066253)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 2.0.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 9 µs | 4.6 µs (microui) | 1.957 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 38.3 µs | 16.9 µs (microui) | 2.266 |
| Resize frame median | 10.3 µs | 24.2 µs (microui) | 0.426 |
| First frame | 0.403 ms | 0.378 ms (Nuklear) | 1.068 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.3 | 9.0 / 12.4 | 0.1 / 0.1 | 38.3 / 47.9 | 10.3 / 16.6 | 0.1 / 0.1 |
| Clay | 32.5 / 41.0 | 26.2 / 33.6 | 36.7 / 44.9 | 123.4 / 135.2 | 36.6 / 45.2 | 32.2 / 40.6 |
| Dear ImGui | 16.2 / 23.4 | 12.2 / 19.0 | 96.3 / 115.3 | 67.8 / 80.4 | 91.4 / 146.9 | 16.1 / 23.4 |
| egui | 203.0 / 365.4 | 243.6 / 270.8 | 115.1 / 134.4 | 285.8 / 315.4 | 282.3 / 346.7 | 0.0 / 0.0 |
| Iced | 23.9 / 32.0 | 123.1 / 184.0 | 21.9 / 29.5 | 165.9 / 184.7 | 145.8 / 284.6 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.0 | 834.4 / 964.2 | 1.2 / 2.1 | 3571.3 / 3667.4 | 2013.3 / 3880.4 | 0.3 / 0.3 |
| Slint | 24.9 / 323.8 | 1446.2 / 1507.9 | 15.2 / 22.0 | 5561.3 / 5948.9 | 2476.8 / 5200.7 | 0.2 / 0.2 |
| Qt Quick | 58.8 / 72.3 | 91.6 / 106.1 | 100.2 / 114.8 | 13955.2 / 18854.5 | 165.3 / 2409.3 | 2.7 / 3.0 |
| Nuklear | 8.9 / 13.6 | 6.1 / 7.7 | 64.2 / 75.6 | 27.7 / 36.0 | 64.2 / 79.9 | 8.9 / 15.3 |
| microui | 10.3 / 17.0 | 4.6 / 5.5 | 23.8 / 31.1 | 16.9 / 23.6 | 24.2 / 39.1 | 10.3 / 16.9 |
| GTK 4 | 32.7 / 47.7 | 3063.2 / 12276.3 | 32.6 / 47.8 | 1286.4 / 3108.7 | 2299.7 / 5628.7 | 2.5 / 2.7 |
| Qt Widgets | 1867.1 / 1989.4 | 552.9 / 597.1 | 1488.8 / 1559.6 | 9721.0 / 11545.7 | 5620.1 / 7972.6 | 1.4 / 1.5 |

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
| Slint | 696 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,804 / 5,804 | 5,728 / 5,728 | 8,372 / 8,372 | 4,752 / 4,752 | 10,184 / 10,184 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,020 / 14,020 | 15,628 / 15,628 | 15,900 / 15,900 | 13,720 / 13,720 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,800 / 68,800 | 67,756 / 67,756 | 70,376 / 70,376 | 939,244 / 939,244 | 75,932 / 93,924 | 66,920 / 66,920 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,928 / 46,364 | 51,936 / 55,840 | 42,696 / 50,372 | 44,652 / 46,848 | 44,984 / 44,984 | 42,816 / 46,364 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,752 / 38,752 | 59,084 / 59,084 | 46,112 / 53,912 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.403 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.399 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.113 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 3.127 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.599 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.286 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 31.035 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 80.294 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.378 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.412 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 84.637 | 42808 | 46384 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 41.709 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.82 / 7.13 | 2.40 / 2.74 | 6.88 / 8.25 |
| Clay | 6.38 / 6.68 | 2.63 / 2.86 | 6.10 / 6.49 |
| Dear ImGui | 7.23 / 7.69 | 2.58 / 2.80 | 6.57 / 7.22 |
| egui | 7.48 / 7.78 | 2.65 / 3.06 | 6.52 / 7.08 |
| Iced | 6.35 / 7.37 | 2.60 / 2.96 | 5.96 / 7.19 |
| LVGL | 5.78 / 6.62 | 2.55 / 2.86 | 5.53 / 6.33 |
| Slint | 9.16 / 9.75 | 2.72 / 3.07 | 9.46 / 11.93 |
| Qt Quick | 13.18 / 13.44 | 6.63 / 6.82 | 18.34 / 18.96 |
| Nuklear | 6.14 / 6.55 | 2.57 / 2.90 | 5.96 / 6.40 |
| microui | 6.48 / 7.77 | 2.59 / 2.90 | 6.24 / 7.17 |
| GTK 4 | 36.11 / 36.66 | 11.43 / 13.16 | 30.04 / 31.39 |
| Qt Widgets | 13.92 / 14.19 | 6.51 / 6.69 | 17.48 / 19.13 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/b729391c324a52773aded40a141eec7617809411/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/b729391c324a52773aded40a141eec7617809411/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
