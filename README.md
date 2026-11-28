# GUI framework benchmark results

Measured 2026-11-28 04:49 UTC at [`d72575fd13`](https://github.com/OmarSiwy/LCGF/commit/d72575fd13f2e5a4fc4c4298ee6d492541bf486f). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46106327995)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 8.9 µs | 4.7 µs (microui) | 1.894 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 38.3 µs | 16.9 µs (microui) | 2.266 |
| Resize frame median | 10.4 µs | 24.3 µs (microui) | 0.428 |
| First frame | 0.399 ms | 0.385 ms (Nuklear) | 1.037 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.1 | 8.9 / 15.2 | 0.1 / 0.1 | 38.3 / 49.7 | 10.4 / 17.1 | 0.1 / 0.1 |
| Clay | 32.3 / 41.0 | 26.0 / 34.0 | 36.0 / 45.6 | 122.7 / 137.6 | 36.6 / 45.3 | 32.2 / 41.2 |
| Dear ImGui | 16.3 / 23.9 | 12.2 / 19.4 | 96.3 / 121.2 | 67.9 / 80.7 | 91.3 / 147.1 | 16.2 / 23.7 |
| egui | 202.5 / 355.1 | 244.1 / 271.5 | 115.9 / 135.5 | 287.9 / 313.4 | 283.7 / 345.1 | 0.0 / 0.0 |
| Iced | 24.8 / 33.3 | 124.1 / 182.4 | 21.7 / 29.6 | 166.3 / 186.5 | 146.2 / 272.4 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.0 | 843.2 / 973.0 | 1.2 / 2.1 | 3573.4 / 3702.1 | 2015.6 / 3890.7 | 0.3 / 0.3 |
| Slint | 25.1 / 334.6 | 1452.5 / 1757.0 | 15.3 / 22.1 | 5551.4 / 5783.4 | 2470.9 / 5089.0 | 0.2 / 0.2 |
| Qt Quick | 59.5 / 75.5 | 91.6 / 106.9 | 99.5 / 118.2 | 12471.3 / 16637.6 | 165.0 / 2231.4 | 2.7 / 3.0 |
| Nuklear | 8.9 / 14.8 | 6.1 / 9.3 | 64.2 / 74.7 | 27.7 / 36.6 | 64.3 / 79.6 | 8.9 / 15.2 |
| microui | 10.3 / 17.1 | 4.7 / 4.9 | 23.9 / 31.7 | 16.9 / 23.8 | 24.3 / 39.2 | 10.3 / 17.1 |
| GTK 4 | 32.7 / 48.2 | 2773.2 / 10873.4 | 32.3 / 47.3 | 1284.9 / 2736.1 | 2269.5 / 5354.7 | 2.6 / 2.8 |
| Qt Widgets | 1867.3 / 1989.1 | 534.1 / 581.2 | 1477.0 / 1554.2 | 8978.7 / 10930.8 | 5591.4 / 7500.8 | 1.4 / 1.6 |

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
| Slint | 688 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,900 / 15,900 | 13,716 / 13,716 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,796 / 68,796 | 67,752 / 67,752 | 70,372 / 70,372 | 939,252 / 939,252 | 77,756 / 93,924 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,916 / 46,356 | 51,744 / 55,712 | 42,688 / 50,428 | 44,644 / 46,848 | 44,980 / 44,980 | 42,808 / 46,352 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 46,892 / 55,540 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.399 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.405 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.179 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.901 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.242 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.241 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 29.640 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 78.041 | 66896 | 66896 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.385 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.424 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 82.681 | 42784 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 40.578 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.08 / 6.93 | 2.52 / 2.69 | 5.99 / 7.45 |
| Clay | 6.36 / 6.86 | 2.57 / 2.72 | 5.75 / 6.51 |
| Dear ImGui | 7.31 / 7.59 | 2.62 / 2.75 | 6.30 / 7.11 |
| egui | 6.00 / 7.50 | 2.58 / 2.71 | 5.62 / 6.83 |
| Iced | 6.50 / 7.19 | 2.54 / 2.92 | 6.21 / 6.70 |
| LVGL | 6.25 / 6.78 | 2.56 / 2.77 | 5.74 / 6.20 |
| Slint | 8.49 / 9.49 | 2.52 / 3.05 | 9.14 / 11.84 |
| Qt Quick | 12.96 / 13.52 | 6.67 / 6.83 | 17.49 / 18.62 |
| Nuklear | 5.44 / 6.35 | 2.50 / 2.69 | 5.20 / 5.73 |
| microui | 5.67 / 6.92 | 2.55 / 2.71 | 5.60 / 6.77 |
| GTK 4 | 35.84 / 41.99 | 11.46 / 14.08 | 29.57 / 33.09 |
| Qt Widgets | 13.76 / 14.10 | 6.56 / 6.85 | 16.90 / 18.21 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/d72575fd13f2e5a4fc4c4298ee6d492541bf486f/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/d72575fd13f2e5a4fc4c4298ee6d492541bf486f/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
