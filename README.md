# GUI framework benchmark results

Measured 2026-11-28 00:52 UTC at [`5773d30dfb`](https://github.com/OmarSiwy/LCGF/commit/5773d30dfb61b1e0991fa0c0a2629de8d6b23753). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46087814387)

AMD EPYC 9V45 96-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 2.0.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.6 µs (LVGL) | 0.167 |
| List frame median | 5.9 µs | 3.4 µs (microui) | 1.735 |
| Text frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| Springs frame median | 22.4 µs | 11.4 µs (microui) | 1.965 |
| Resize frame median | 6.5 µs | 16.7 µs (microui) | 0.389 |
| First frame | 0.307 ms | 0.296 ms (Nuklear) | 1.038 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 9.3 | 5.9 / 7.3 | 0.1 / 0.1 | 22.4 / 29.5 | 6.5 / 8.1 | 0.1 / 0.1 |
| Clay | 22.3 / 28.0 | 18.1 / 23.9 | 27.1 / 32.9 | 86.8 / 95.0 | 27.2 / 33.0 | 22.3 / 28.4 |
| Dear ImGui | 12.1 / 17.8 | 8.4 / 12.3 | 62.3 / 69.6 | 43.5 / 51.5 | 60.1 / 95.1 | 12.2 / 18.0 |
| egui | 160.5 / 280.5 | 188.3 / 204.4 | 97.7 / 109.3 | 241.7 / 255.5 | 215.5 / 270.0 | 0.0 / 0.0 |
| Iced | 19.0 / 24.8 | 86.8 / 130.0 | 15.9 / 21.6 | 118.7 / 127.3 | 106.4 / 183.5 | 0.0 / 0.0 |
| LVGL | 0.6 / 0.7 | 616.3 / 718.2 | 0.9 / 1.6 | 2365.5 / 2497.0 | 1415.7 / 2913.5 | 0.2 / 0.2 |
| Slint | 36.4 / 263.8 | 1088.2 / 1158.1 | 25.2 / 30.7 | 3618.9 / 3887.5 | 1791.2 / 3556.9 | 0.2 / 0.2 |
| Qt Quick | 48.2 / 57.4 | 74.8 / 83.7 | 76.3 / 91.3 | 9419.1 / 15164.9 | 124.6 / 1883.5 | 2.2 / 2.2 |
| Nuklear | 6.7 / 8.1 | 4.7 / 5.0 | 45.1 / 52.3 | 21.0 / 26.5 | 45.4 / 58.6 | 6.6 / 7.8 |
| microui | 6.9 / 9.9 | 3.4 / 3.6 | 16.0 / 21.5 | 11.4 / 16.8 | 16.7 / 26.6 | 6.9 / 8.5 |
| GTK 4 | 26.4 / 37.1 | 1882.8 / 9620.5 | 26.5 / 39.5 | 909.7 / 2107.8 | 1651.3 / 3900.0 | 1.8 / 1.8 |
| Qt Widgets | 1253.6 / 1348.2 | 460.6 / 486.0 | 1397.6 / 1487.8 | 6371.6 / 8001.0 | 4303.8 / 6070.8 | 1.2 / 1.2 |

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
| Slint | 705 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,808 / 5,808 | 5,732 / 5,732 | 8,380 / 8,380 | 4,752 / 4,752 | 10,184 / 10,184 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,624 / 15,624 | 15,900 / 15,900 | 13,716 / 13,716 | 21,012 / 21,012 | 13,988 / 13,988 |
| Qt Quick | 68,792 / 68,792 | 67,752 / 67,752 | 70,372 / 70,372 | 939,248 / 939,248 | 76,460 / 93,912 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,936 / 46,384 | 52,160 / 55,908 | 42,684 / 50,364 | 44,612 / 46,912 | 44,904 / 44,904 | 42,804 / 46,356 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 46,796 / 54,972 | 36,808 / 36,808 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.307 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.311 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 0.920 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.379 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.506 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.405 | 3528 | 3528 | 30.0 | 669,321 | 1,020,080 | 2,457,760 |
| Slint | 22.062 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 60.625 | 66896 | 66896 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.296 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.325 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 63.308 | 42776 | 46352 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 29.168 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 5.39 / 6.12 | 1.69 / 1.76 | 5.29 / 5.47 |
| Clay | 4.00 / 4.97 | 1.55 / 1.81 | 3.50 / 4.37 |
| Dear ImGui | 4.37 / 5.80 | 1.67 / 1.96 | 3.72 / 4.64 |
| egui | 5.23 / 5.85 | 1.83 / 1.95 | 4.48 / 5.06 |
| Iced | 4.90 / 5.21 | 1.53 / 1.96 | 4.74 / 4.93 |
| LVGL | 4.08 / 4.71 | 1.54 / 1.96 | 3.66 / 4.69 |
| Slint | 6.38 / 6.85 | 1.84 / 1.94 | 6.09 / 6.37 |
| Qt Quick | 10.41 / 10.72 | 5.82 / 6.02 | 12.36 / 12.63 |
| Nuklear | 4.63 / 5.19 | 1.53 / 1.86 | 4.28 / 4.33 |
| microui | 4.63 / 4.93 | 1.52 / 1.87 | 4.26 / 4.66 |
| GTK 4 | 32.98 / 33.78 | 18.09 / 19.14 | 23.02 / 23.71 |
| Qt Widgets | 10.90 / 11.35 | 5.80 / 5.99 | 12.56 / 12.98 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/5773d30dfb61b1e0991fa0c0a2629de8d6b23753/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/5773d30dfb61b1e0991fa0c0a2629de8d6b23753/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
