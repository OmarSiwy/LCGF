# GUI framework benchmark results

Measured 2026-11-27 22:16 UTC at [`5abf1b7f83`](https://github.com/OmarSiwy/LCGF/commit/5abf1b7f832c0be65c2d571ccfe327fe8053847e). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46071729704)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 9 µs | 3.8 µs (microui) | 2.368 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 38.3 µs | 15.1 µs (microui) | 2.536 |
| Resize frame median | 10.3 µs | 19.1 µs (microui) | 0.539 |
| First frame | 0.434 ms | 0.409 ms (Nuklear) | 1.061 |
| Idle resident memory | 452 KiB | 472 KiB (Nuklear) | 0.958 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.3 | 9.0 / 13.7 | 0.1 / 0.1 | 38.3 / 49.7 | 10.3 / 17.1 | 0.1 / 0.1 |
| Clay | 32.4 / 40.8 | 26.1 / 34.0 | 36.7 / 45.1 | 122.8 / 136.2 | 36.6 / 45.7 | 32.4 / 40.9 |
| Dear ImGui | 16.3 / 23.6 | 12.4 / 19.5 | 96.5 / 109.2 | 67.9 / 79.8 | 91.5 / 147.3 | 16.3 / 23.7 |
| egui | 201.9 / 357.5 | 242.4 / 272.9 | 115.2 / 133.1 | 287.6 / 316.2 | 282.4 / 350.5 | 0.0 / 0.0 |
| Iced | 24.8 / 33.1 | 123.8 / 184.2 | 21.7 / 29.9 | 166.5 / 186.5 | 144.8 / 265.1 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.0 | 834.2 / 960.3 | 1.2 / 2.2 | 3574.2 / 3660.4 | 2001.0 / 3877.2 | 0.3 / 0.3 |
| Slint | 25.0 / 336.4 | 1447.8 / 1557.5 | 15.2 / 22.3 | 5566.9 / 6000.5 | 2475.6 / 5116.8 | 0.2 / 0.2 |
| Qt Quick | 59.7 / 74.3 | 91.0 / 105.5 | 99.6 / 116.8 | 13348.8 / 18207.0 | 161.7 / 2276.2 | 2.7 / 3.1 |
| Nuklear | 7.5 / 12.2 | 5.9 / 6.5 | 51.9 / 62.2 | 30.8 / 39.4 | 53.0 / 66.2 | 7.5 / 9.1 |
| microui | 8.0 / 11.8 | 3.8 / 4.5 | 18.7 / 26.1 | 15.1 / 22.0 | 19.1 / 28.8 | 7.9 / 10.0 |
| GTK 4 | 33.3 / 52.1 | 2937.5 / 12032.0 | 33.2 / 47.1 | 1283.8 / 3019.7 | 2303.5 / 5614.3 | 2.6 / 2.9 |
| Qt Widgets | 1874.0 / 1986.1 | 559.3 / 598.7 | 1480.8 / 1563.2 | 9608.4 / 11637.7 | 5607.1 / 7551.0 | 1.4 / 1.5 |

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
| Slint | 686 | 3000 | 1 | 3000 | 3000 | 1 |
| Qt Quick | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Nuklear | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| microui | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| GTK 4 | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |
| Qt Widgets | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |

## Resident memory by workload

Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. Linux reports its resident pages after 3,000 polls and the highest resident count since launch. Both columns are medians across runs and include resident shared pages.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 560 / 560 | 540 / 540 | 556 / 556 | 1,544 / 1,544 | 556 / 556 | 560 / 560 |
| Clay | 2,192 / 2,192 | 2,176 / 2,176 | 2,180 / 2,180 | 2,496 / 2,496 | 2,184 / 2,184 | 2,192 / 2,192 |
| Dear ImGui | 3,696 / 3,696 | 3,700 / 3,700 | 3,988 / 4,040 | 3,880 / 3,912 | 4,408 / 4,496 | 3,696 / 3,696 |
| egui | 7,304 / 7,572 | 7,396 / 7,396 | 8,192 / 8,192 | 6,144 / 6,144 | 9,320 / 9,320 | 7,540 / 7,572 |
| Iced | 5,856 / 5,856 | 5,780 / 5,780 | 8,428 / 8,428 | 4,804 / 4,804 | 10,232 / 10,232 | 5,844 / 5,844 |
| LVGL | 3,688 / 3,688 | 3,672 / 3,672 | 3,688 / 3,688 | 3,880 / 3,880 | 3,700 / 3,700 | 3,688 / 3,688 |
| Slint | 14,068 / 14,068 | 15,676 / 15,676 | 15,952 / 15,952 | 13,768 / 13,768 | 21,060 / 21,060 | 14,040 / 14,040 |
| Qt Quick | 68,860 / 68,860 | 67,820 / 67,820 | 70,424 / 70,424 | 939,320 / 939,320 | 76,460 / 93,988 | 66,980 / 66,980 |
| Nuklear | 2,808 / 2,808 | 2,796 / 2,796 | 2,808 / 2,808 | 2,828 / 2,828 | 2,808 / 2,808 | 2,808 / 2,808 |
| microui | 2,772 / 2,772 | 2,772 / 2,772 | 2,772 / 2,772 | 2,780 / 2,780 | 2,772 / 2,772 | 2,772 / 2,772 |
| GTK 4 | 42,976 / 46,384 | 51,920 / 55,884 | 42,844 / 50,660 | 44,696 / 46,848 | 45,020 / 45,020 | 42,868 / 46,484 |
| Qt Widgets | 36,824 / 36,824 | 39,688 / 39,688 | 38,800 / 38,800 | 59,140 / 59,140 | 47,964 / 54,376 | 36,860 / 36,860 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.434 | 452 | 452 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.445 | 476 | 476 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.146 | 3612 | 3612 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 3.005 | 7204 | 7508 | 0.0 | 3,939,371 | 400 | 4,231,432 |
| Iced | 4.382 | 5824 | 5824 | 0.0 | 1,626,834 | 264 | 6,055,936 |
| LVGL | 3.336 | 3580 | 3580 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 30.994 | 14044 | 14044 | 0.0 | 8,016,515 | 2,312 | 6,752,256 |
| Qt Quick | 82.328 | 66960 | 66960 | 0.0 | 54,358 | 32,184 | 151,370,192 |
| Nuklear | 0.409 | 472 | 472 | 0.0 | 224,170 | 51,432 | 4,029,872 |
| microui | 0.432 | 488 | 488 | 0.0 | 29,671 | 303,080 | 4,029,872 |
| GTK 4 | 84.838 | 42860 | 46512 | 2.0 | 22,223 | 40,144 | 79,052,064 |
| Qt Widgets | 41.999 | 36892 | 36892 | 0.0 | 43,519 | 40,064 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.39 / 6.92 | 2.37 / 2.56 | 6.31 / 7.91 |
| Clay | 5.95 / 6.25 | 2.50 / 2.74 | 5.25 / 6.06 |
| Dear ImGui | 6.54 / 7.17 | 2.54 / 2.88 | 5.75 / 6.44 |
| egui | 6.02 / 7.50 | 2.54 / 3.07 | 5.40 / 6.54 |
| Iced | 5.80 / 6.73 | 2.45 / 2.91 | 5.61 / 6.61 |
| LVGL | 5.73 / 6.53 | 2.46 / 2.89 | 5.39 / 6.28 |
| Slint | 8.64 / 9.86 | 2.50 / 3.10 | 10.02 / 11.30 |
| Qt Quick | 12.72 / 13.11 | 6.60 / 6.87 | 16.69 / 17.85 |
| Nuklear | 5.68 / 7.38 | 2.40 / 2.83 | 5.27 / 6.43 |
| microui | 5.85 / 6.38 | 2.36 / 2.85 | 5.38 / 7.14 |
| GTK 4 | 35.22 / 36.27 | 10.55 / 12.85 | 27.55 / 29.86 |
| Qt Widgets | 13.46 / 14.02 | 6.64 / 6.91 | 16.20 / 18.09 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/5abf1b7f832c0be65c2d571ccfe327fe8053847e/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/5abf1b7f832c0be65c2d571ccfe327fe8053847e/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
