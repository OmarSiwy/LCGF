# GUI framework benchmark results

Measured 2026-11-28 02:14 UTC at [`02049e52a4`](https://github.com/OmarSiwy/LCGF/commit/02049e52a455b5c55022f88ebf2716c861f573dd). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46094390799)

AMD EPYC 9V45 96-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.9.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.6 µs (LVGL) | 0.167 |
| List frame median | 6.2 µs | 3.6 µs (microui) | 1.722 |
| Text frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| Springs frame median | 23.5 µs | 11.3 µs (microui) | 2.080 |
| Resize frame median | 6.8 µs | 17.1 µs (microui) | 0.398 |
| First frame | 0.31 ms | 0.291 ms (Nuklear) | 1.063 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 9.6 | 6.2 / 7.1 | 0.1 / 0.1 | 23.5 / 30.7 | 6.8 / 8.2 | 0.1 / 0.1 |
| Clay | 22.3 / 28.3 | 18.1 / 23.7 | 27.1 / 32.8 | 86.5 / 94.1 | 27.2 / 32.9 | 22.2 / 28.0 |
| Dear ImGui | 12.9 / 18.7 | 8.7 / 12.8 | 62.9 / 73.6 | 43.6 / 51.2 | 61.3 / 97.3 | 12.7 / 18.2 |
| egui | 171.7 / 303.9 | 201.2 / 222.1 | 106.5 / 129.3 | 264.5 / 286.3 | 231.9 / 280.8 | 0.0 / 0.0 |
| Iced | 19.3 / 25.3 | 91.2 / 139.2 | 16.6 / 22.4 | 123.9 / 146.6 | 106.5 / 186.1 | 0.0 / 0.0 |
| LVGL | 0.6 / 0.8 | 632.8 / 787.3 | 0.9 / 1.6 | 2375.1 / 2634.4 | 1522.0 / 3116.9 | 0.2 / 0.2 |
| Slint | 37.1 / 275.3 | 1123.1 / 1201.4 | 25.3 / 31.1 | 3734.3 / 4100.4 | 1841.3 / 3737.0 | 0.2 / 0.2 |
| Qt Quick | 50.3 / 59.0 | 66.0 / 78.2 | 74.3 / 87.0 | 9458.4 / 15009.6 | 110.3 / 1955.6 | 2.1 / 2.2 |
| Nuklear | 6.9 / 10.3 | 4.9 / 5.5 | 47.6 / 101.8 | 22.3 / 28.2 | 47.0 / 61.8 | 6.6 / 9.6 |
| microui | 7.2 / 11.2 | 3.6 / 3.7 | 16.3 / 21.8 | 11.3 / 16.7 | 17.1 / 26.8 | 7.1 / 7.7 |
| GTK 4 | 25.9 / 36.8 | 1913.5 / 9604.4 | 29.4 / 41.4 | 912.4 / 1974.6 | 1686.9 / 3983.3 | 1.9 / 2.0 |
| Qt Widgets | 1321.2 / 1663.6 | 489.7 / 624.1 | 1460.3 / 1864.7 | 7244.0 / 10451.5 | 4472.6 / 6511.6 | 1.2 / 1.3 |

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
| Slint | 706 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,808 / 5,808 | 5,732 / 5,732 | 8,376 / 8,376 | 4,752 / 4,752 | 10,160 / 10,160 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,900 / 15,900 | 13,720 / 13,720 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,788 / 68,788 | 67,756 / 67,756 | 70,368 / 70,368 | 939,248 / 939,248 | 77,460 / 93,920 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,920 / 46,356 | 52,160 / 55,908 | 42,692 / 50,372 | 44,612 / 46,912 | 44,856 / 44,856 | 42,804 / 46,352 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,752 / 38,752 | 59,084 / 59,084 | 47,116 / 54,684 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.310 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.345 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 0.974 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.373 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.735 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.578 | 3528 | 3528 | 30.0 | 669,321 | 1,020,080 | 2,457,760 |
| Slint | 23.724 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 60.497 | 66896 | 66896 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.291 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.320 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 72.992 | 42780 | 46352 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 32.957 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 5.64 / 6.40 | 1.72 / 1.93 | 5.28 / 6.38 |
| Clay | 4.47 / 5.94 | 1.68 / 1.86 | 3.94 / 4.59 |
| Dear ImGui | 4.32 / 5.64 | 1.62 / 1.95 | 3.77 / 4.73 |
| egui | 5.09 / 5.77 | 1.89 / 2.02 | 4.63 / 5.86 |
| Iced | 5.30 / 5.65 | 1.88 / 1.96 | 4.98 / 5.57 |
| LVGL | 4.90 / 11.85 | 1.87 / 2.15 | 4.44 / 18.29 |
| Slint | 6.67 / 7.61 | 1.96 / 2.18 | 6.53 / 7.25 |
| Qt Quick | 10.72 / 11.33 | 6.02 / 6.34 | 13.20 / 13.99 |
| Nuklear | 4.39 / 6.26 | 1.71 / 1.96 | 4.10 / 5.18 |
| microui | 4.12 / 5.13 | 1.70 / 1.95 | 3.95 / 4.89 |
| GTK 4 | 33.36 / 35.36 | 16.47 / 18.57 | 24.33 / 27.08 |
| Qt Widgets | 11.74 / 12.28 | 6.19 / 6.41 | 13.95 / 14.94 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/02049e52a455b5c55022f88ebf2716c861f573dd/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/02049e52a455b5c55022f88ebf2716c861f573dd/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
