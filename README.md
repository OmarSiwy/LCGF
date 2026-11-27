# GUI framework benchmark results

Measured 2026-11-27 22:35 UTC at [`7ee7af5fc6`](https://github.com/OmarSiwy/LCGF/commit/7ee7af5fc696cba2e800e54de771c6feb920f33f). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46073607359)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.9.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 8.9 µs | 4.7 µs (microui) | 1.894 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 38.2 µs | 16.8 µs (microui) | 2.274 |
| Resize frame median | 10.3 µs | 24.3 µs (microui) | 0.424 |
| First frame | 0.388 ms | 0.374 ms (Nuklear) | 1.037 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.1 | 8.9 / 15.2 | 0.1 / 0.1 | 38.2 / 47.4 | 10.3 / 16.9 | 0.1 / 0.1 |
| Clay | 32.4 / 40.3 | 26.1 / 33.8 | 36.6 / 45.2 | 122.7 / 137.7 | 36.6 / 45.1 | 32.2 / 40.9 |
| Dear ImGui | 16.2 / 23.6 | 12.3 / 19.0 | 96.3 / 107.9 | 67.8 / 77.9 | 91.8 / 149.8 | 16.2 / 23.5 |
| egui | 203.1 / 352.2 | 244.2 / 271.5 | 115.6 / 131.8 | 287.2 / 324.5 | 282.5 / 379.4 | 0.0 / 0.0 |
| Iced | 23.8 / 32.6 | 123.3 / 184.0 | 22.0 / 30.4 | 165.8 / 189.8 | 145.3 / 261.5 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.0 | 832.6 / 957.8 | 1.2 / 2.2 | 3574.1 / 3682.7 | 2013.6 / 3886.2 | 0.3 / 0.3 |
| Slint | 25.3 / 314.9 | 1445.4 / 1533.8 | 15.2 / 22.0 | 5431.1 / 5838.9 | 2476.3 / 5140.5 | 0.2 / 0.2 |
| Qt Quick | 59.7 / 73.7 | 91.7 / 112.6 | 99.9 / 119.0 | 14009.6 / 19680.5 | 177.2 / 2501.1 | 2.7 / 3.0 |
| Nuklear | 8.9 / 13.7 | 6.1 / 8.0 | 64.2 / 75.5 | 27.8 / 35.0 | 64.3 / 78.1 | 8.9 / 11.5 |
| microui | 10.3 / 16.8 | 4.7 / 4.8 | 23.8 / 31.9 | 16.8 / 23.9 | 24.3 / 39.2 | 10.3 / 17.2 |
| GTK 4 | 33.0 / 47.6 | 3197.6 / 13131.5 | 41.0 / 60.0 | 1287.9 / 3277.6 | 2310.3 / 5750.3 | 2.6 / 2.9 |
| Qt Widgets | 1862.3 / 2300.8 | 554.6 / 620.5 | 1490.9 / 1814.5 | 9720.0 / 12681.3 | 5612.3 / 8179.8 | 1.4 / 1.5 |

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
| Slint | 689 | 3000 | 1 | 3000 | 3000 | 1 |
| Qt Quick | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Nuklear | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| microui | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| GTK 4 | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Qt Widgets | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |

## Resident memory by workload

Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. Linux reports its resident pages after 3,000 polls and the highest resident count since launch. Both columns are medians across runs and include resident shared pages.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 512 / 512 | 492 / 492 | 508 / 508 | 1,496 / 1,496 | 508 / 508 | 512 / 512 |
| Clay | 2,140 / 2,140 | 2,124 / 2,124 | 2,128 / 2,128 | 2,444 / 2,444 | 2,132 / 2,132 | 2,140 / 2,140 |
| Dear ImGui | 3,644 / 3,644 | 3,648 / 3,648 | 3,936 / 3,936 | 3,828 / 3,912 | 4,356 / 4,444 | 3,644 / 3,644 |
| egui | 7,252 / 7,572 | 7,348 / 7,348 | 8,144 / 8,164 | 6,096 / 6,096 | 9,272 / 9,272 | 7,488 / 7,572 |
| Iced | 5,808 / 5,808 | 5,728 / 5,728 | 8,376 / 8,376 | 4,752 / 4,752 | 10,160 / 10,160 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,020 / 14,020 | 15,632 / 15,632 | 15,900 / 15,900 | 13,716 / 13,716 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,800 / 68,800 | 67,756 / 67,756 | 70,380 / 70,380 | 939,252 / 939,252 | 77,752 / 93,916 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,928 / 46,356 | 51,816 / 55,712 | 42,792 / 50,532 | 44,648 / 46,848 | 44,904 / 44,904 | 42,832 / 46,384 |
| Qt Widgets | 36,776 / 36,776 | 39,640 / 39,640 | 38,756 / 38,756 | 59,084 / 59,084 | 46,444 / 53,996 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.388 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.409 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.099 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.982 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.381 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.371 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 31.549 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 82.563 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.374 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.398 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 87.379 | 42788 | 46364 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 39.466 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.81 / 7.12 | 2.39 / 2.55 | 6.91 / 7.88 |
| Clay | 6.33 / 6.89 | 2.57 / 2.82 | 5.69 / 6.31 |
| Dear ImGui | 7.28 / 7.77 | 2.61 / 2.79 | 6.42 / 6.87 |
| egui | 7.31 / 8.04 | 2.62 / 3.11 | 6.39 / 6.65 |
| Iced | 6.50 / 6.86 | 2.56 / 2.97 | 6.14 / 7.36 |
| LVGL | 6.01 / 7.82 | 2.53 / 2.90 | 5.50 / 6.10 |
| Slint | 9.10 / 9.59 | 2.54 / 2.74 | 9.82 / 11.48 |
| Qt Quick | 12.91 / 13.60 | 6.69 / 8.18 | 16.62 / 17.59 |
| Nuklear | 5.91 / 6.56 | 2.54 / 2.62 | 4.85 / 6.06 |
| microui | 5.78 / 6.74 | 2.55 / 2.66 | 5.05 / 6.25 |
| GTK 4 | 36.32 / 36.77 | 9.71 / 12.26 | 29.76 / 33.57 |
| Qt Widgets | 13.58 / 14.51 | 6.62 / 6.82 | 16.17 / 19.14 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/7ee7af5fc696cba2e800e54de771c6feb920f33f/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/7ee7af5fc696cba2e800e54de771c6feb920f33f/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
