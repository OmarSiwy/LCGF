# GUI framework benchmark results

Measured 2026-11-18 02:17 UTC at [`50d6397cf9`](https://github.com/OmarSiwy/LCGF/commit/50d6397cf991e29fd0fa1044e0e5f2bbf16d7ee4). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/44216460768)

AMD EPYC 7763 64-Core Processor, Linux 7.0.0-1019-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.9.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 1 µs (LVGL) | 0.100 |
| List frame median | 13.3 µs | 5.8 µs (microui) | 2.293 |
| Text frame median | 0.1 µs | 1.5 µs (LVGL) | 0.067 |
| Springs frame median | 67.6 µs | 20.9 µs (microui) | 3.234 |
| Resize frame median | 19 µs | 30.7 µs (microui) | 0.619 |
| First frame | 0.476 ms | 0.459 ms (Nuklear) | 1.037 |
| Idle resident memory | 408 KiB | 416 KiB (Nuklear) | 0.981 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 19.3 | 13.3 / 20.8 | 0.1 / 0.1 | 67.6 / 80.8 | 19.0 / 27.0 | 0.1 / 0.1 |
| Clay | 38.5 / 47.8 | 30.8 / 39.1 | 44.4 / 53.4 | 162.1 / 179.8 | 44.6 / 53.7 | 38.4 / 47.6 |
| Dear ImGui | 22.9 / 31.6 | 15.4 / 23.4 | 125.9 / 150.1 | 74.9 / 87.1 | 117.8 / 196.8 | 23.0 / 33.6 |
| egui | 264.1 / 433.0 | 309.4 / 345.1 | 149.9 / 177.9 | 373.7 / 407.7 | 374.5 / 460.6 | 0.0 / 0.0 |
| Iced | 30.8 / 40.1 | 157.8 / 242.2 | 26.8 / 35.6 | 212.4 / 236.8 | 189.5 / 339.9 | 0.0 / 0.0 |
| LVGL | 1.0 / 1.3 | 1132.5 / 1317.5 | 1.5 / 2.7 | 4244.9 / 4520.2 | 2624.9 / 5111.4 | 0.3 / 0.4 |
| Slint | 31.5 / 443.5 | 1779.5 / 1899.0 | 18.8 / 27.0 | 6852.0 / 7071.4 | 2958.9 / 6125.7 | 0.2 / 0.3 |
| Qt Quick | 91.4 / 114.0 | 148.2 / 175.3 | 164.2 / 189.8 | 15363.2 / 22462.9 | 236.1 / 2422.9 | 3.4 / 3.6 |
| Nuklear | 12.5 / 20.1 | 8.3 / 14.2 | 82.9 / 209.3 | 40.9 / 49.0 | 83.7 / 157.7 | 12.4 / 19.5 |
| microui | 13.5 / 21.0 | 5.8 / 6.0 | 30.2 / 38.0 | 20.9 / 28.4 | 30.7 / 50.1 | 13.5 / 20.9 |
| GTK 4 | 46.8 / 84.1 | 4369.3 / 14740.3 | 52.8 / 94.3 | 1744.8 / 3740.2 | 3263.1 / 7384.9 | 2.6 / 2.8 |
| Qt Widgets | 5285.6 / 5655.0 | 706.1 / 780.7 | 1640.7 / 1805.3 | 11940.8 / 15077.5 | 7416.4 / 9947.2 | 1.6 / 1.7 |

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
| Slint | 753 | 3000 | 1 | 3000 | 3000 | 1 |
| Qt Quick | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Nuklear | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| microui | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| GTK 4 | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Qt Widgets | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |

## Resident memory by workload

Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. Linux reports its resident pages after 3,000 polls and the highest resident count since launch. Both columns are medians across runs and include resident shared pages.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 504 / 504 | 504 / 504 | 512 / 512 | 1,496 / 1,496 | 512 / 512 | 504 / 504 |
| Clay | 2,140 / 2,140 | 2,124 / 2,124 | 2,128 / 2,128 | 2,444 / 2,444 | 2,132 / 2,132 | 2,140 / 2,140 |
| Dear ImGui | 3,636 / 3,636 | 3,640 / 3,640 | 3,928 / 3,928 | 3,820 / 3,820 | 4,348 / 4,432 | 3,636 / 3,636 |
| egui | 7,188 / 7,508 | 7,284 / 7,284 | 8,080 / 8,100 | 6,032 / 6,032 | 9,208 / 9,208 | 7,424 / 7,508 |
| Iced | 5,744 / 5,744 | 5,668 / 5,668 | 8,316 / 8,316 | 4,688 / 4,688 | 10,096 / 10,096 | 5,732 / 5,732 |
| LVGL | 3,556 / 3,556 | 3,476 / 3,476 | 3,492 / 3,492 | 3,684 / 3,684 | 3,504 / 3,504 | 3,556 / 3,556 |
| Slint | 13,952 / 13,952 | 15,564 / 15,564 | 15,836 / 15,836 | 13,656 / 13,656 | 20,944 / 20,944 | 13,928 / 13,928 |
| Qt Quick | 68,732 / 68,732 | 67,692 / 67,692 | 70,304 / 70,304 | 939,192 / 939,192 | 76,464 / 93,856 | 66,848 / 66,848 |
| Nuklear | 2,648 / 2,648 | 2,636 / 2,636 | 2,648 / 2,648 | 2,664 / 2,664 | 2,648 / 2,648 | 2,648 / 2,648 |
| microui | 2,656 / 2,656 | 2,656 / 2,656 | 2,656 / 2,656 | 2,660 / 2,660 | 2,656 / 2,656 | 2,656 / 2,656 |
| GTK 4 | 42,848 / 46,320 | 51,580 / 55,392 | 42,724 / 50,468 | 44,600 / 46,848 | 44,888 / 44,888 | 42,772 / 46,320 |
| Qt Widgets | 36,720 / 36,720 | 39,584 / 39,584 | 38,696 / 38,696 | 59,028 / 59,028 | 46,408 / 54,192 | 36,752 / 36,752 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.476 | 408 | 408 | 0.0 | 64,528 | 33,520 | 0 |
| Clay | 0.495 | 424 | 424 | 0.0 | 99,530 | 100,936 | 2,457,760 |
| Dear ImGui | 1.320 | 3548 | 3548 | 0.0 | 757,415 | 61,104 | 3,377,608 |
| egui | 3.761 | 7088 | 7444 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 5.038 | 5712 | 5712 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 4.077 | 3448 | 3448 | 30.0 | 659,329 | 1,021,920 | 2,457,760 |
| Slint | 37.705 | 13932 | 13932 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 92.305 | 66836 | 66836 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.459 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.507 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 100.648 | 42716 | 46292 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 51.823 | 36776 | 36776 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 8.34 / 9.05 | 2.92 / 3.31 | 7.89 / 8.38 |
| Clay | 6.60 / 6.92 | 2.43 / 2.85 | 6.09 / 6.57 |
| Dear ImGui | 7.08 / 7.33 | 2.40 / 2.58 | 6.43 / 6.89 |
| egui | 6.64 / 7.31 | 2.33 / 2.50 | 5.49 / 6.41 |
| Iced | 7.35 / 7.73 | 2.41 / 2.93 | 6.71 / 7.31 |
| LVGL | 6.57 / 7.56 | 2.36 / 2.86 | 5.95 / 6.55 |
| Slint | 10.44 / 10.70 | 2.46 / 2.69 | 10.24 / 12.44 |
| Qt Quick | 14.79 / 15.10 | 7.26 / 7.48 | 22.64 / 23.19 |
| Nuklear | 6.53 / 6.92 | 2.25 / 2.80 | 5.41 / 6.25 |
| microui | 6.07 / 8.08 | 2.44 / 2.80 | 5.20 / 6.59 |
| GTK 4 | 40.07 / 40.95 | 18.01 / 21.54 | 34.46 / 35.39 |
| Qt Widgets | 15.69 / 16.56 | 7.34 / 7.56 | 23.05 / 24.46 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/50d6397cf991e29fd0fa1044e0e5f2bbf16d7ee4/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/50d6397cf991e29fd0fa1044e0e5f2bbf16d7ee4/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
