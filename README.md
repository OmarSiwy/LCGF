# GUI framework benchmark results

Measured 2026-11-27 23:08 UTC at [`644d4791ac`](https://github.com/OmarSiwy/LCGF/commit/644d4791ac9642ae0a3d50ecf8d5b0705033d216). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46077917995)

AMD EPYC 9V45 96-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.6 to 2.0.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.6 µs (LVGL) | 0.167 |
| List frame median | 5.9 µs | 3.5 µs (microui) | 1.686 |
| Text frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| Springs frame median | 22.3 µs | 11.5 µs (microui) | 1.939 |
| Resize frame median | 6.4 µs | 16.7 µs (microui) | 0.383 |
| First frame | 0.317 ms | 0.293 ms (Nuklear) | 1.084 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 9.0 | 5.9 / 6.0 | 0.1 / 0.1 | 22.3 / 29.3 | 6.4 / 6.5 | 0.1 / 0.1 |
| Clay | 22.2 / 28.0 | 18.0 / 23.6 | 27.1 / 34.1 | 86.8 / 97.2 | 27.1 / 33.2 | 22.1 / 27.7 |
| Dear ImGui | 12.2 / 17.8 | 8.7 / 13.8 | 61.9 / 112.7 | 43.3 / 54.8 | 62.8 / 98.8 | 12.1 / 17.7 |
| egui | 162.6 / 288.0 | 185.0 / 205.9 | 97.7 / 115.9 | 241.5 / 263.7 | 215.5 / 259.1 | 0.0 / 0.0 |
| Iced | 19.2 / 25.9 | 88.0 / 134.9 | 15.8 / 21.3 | 117.8 / 130.6 | 105.9 / 186.5 | 0.0 / 0.0 |
| LVGL | 0.6 / 0.7 | 614.6 / 735.7 | 0.9 / 1.6 | 2365.8 / 2537.1 | 1424.6 / 2899.7 | 0.2 / 0.2 |
| Slint | 36.2 / 269.5 | 1087.9 / 1182.2 | 25.6 / 31.5 | 3583.0 / 4060.4 | 1787.4 / 3537.1 | 0.2 / 0.2 |
| Qt Quick | 47.6 / 57.7 | 62.2 / 75.0 | 71.5 / 86.5 | 9044.3 / 15526.1 | 117.3 / 1869.9 | 2.1 / 2.2 |
| Nuklear | 6.7 / 7.5 | 4.7 / 5.0 | 46.3 / 53.9 | 21.2 / 26.9 | 45.3 / 58.5 | 6.6 / 6.9 |
| microui | 6.9 / 11.6 | 3.5 / 3.6 | 16.1 / 22.4 | 11.5 / 17.2 | 16.7 / 26.6 | 6.9 / 11.5 |
| GTK 4 | 26.7 / 39.0 | 1879.8 / 9668.5 | 29.6 / 41.2 | 909.9 / 1847.4 | 1665.5 / 3957.3 | 1.8 / 1.8 |
| Qt Widgets | 1256.9 / 1417.1 | 455.3 / 489.6 | 1390.7 / 1497.3 | 6618.4 / 8893.4 | 4343.2 / 6994.2 | 1.2 / 1.2 |

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
| Slint | 700 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Slint | 14,020 / 14,020 | 15,628 / 15,628 | 15,900 / 15,900 | 13,720 / 13,720 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,796 / 68,796 | 67,760 / 67,760 | 70,372 / 70,372 | 939,244 / 939,244 | 77,748 / 93,912 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,936 / 46,356 | 52,028 / 55,964 | 42,684 / 50,364 | 44,624 / 46,912 | 44,872 / 44,872 | 42,816 / 46,364 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 46,724 / 54,844 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.317 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.321 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 0.921 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.355 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.541 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.418 | 3528 | 3528 | 30.0 | 669,321 | 1,020,080 | 2,457,760 |
| Slint | 22.901 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 59.543 | 66896 | 66896 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.293 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.334 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 66.462 | 42776 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 34.685 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 5.47 / 6.29 | 1.69 / 1.76 | 5.13 / 5.34 |
| Clay | 3.80 / 5.06 | 1.63 / 1.85 | 3.55 / 4.34 |
| Dear ImGui | 4.42 / 5.93 | 1.60 / 1.93 | 3.48 / 4.81 |
| egui | 4.45 / 6.19 | 1.59 / 1.92 | 3.50 / 4.98 |
| Iced | 4.91 / 5.50 | 1.71 / 1.96 | 4.29 / 5.04 |
| LVGL | 3.93 / 5.03 | 1.65 / 1.87 | 3.50 / 4.34 |
| Slint | 6.51 / 6.83 | 1.89 / 1.96 | 6.07 / 6.49 |
| Qt Quick | 10.38 / 10.92 | 5.92 / 6.09 | 12.22 / 12.62 |
| Nuklear | 3.83 / 4.94 | 1.57 / 1.85 | 3.49 / 4.80 |
| microui | 3.71 / 4.93 | 1.56 / 1.84 | 3.47 / 4.36 |
| GTK 4 | 32.68 / 33.49 | 17.67 / 18.73 | 22.43 / 23.13 |
| Qt Widgets | 11.18 / 11.50 | 5.96 / 6.24 | 12.59 / 13.20 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/644d4791ac9642ae0a3d50ecf8d5b0705033d216/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/644d4791ac9642ae0a3d50ecf8d5b0705033d216/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
