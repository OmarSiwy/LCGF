# GUI framework benchmark results

Measured 2026-11-28 04:20 UTC at [`e27d95a05c`](https://github.com/OmarSiwy/LCGF/commit/e27d95a05c476ab6d1aa2a22f4717746c1037865). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46104821342)

AMD EPYC 9V45 96-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.6 µs (LVGL) | 0.167 |
| List frame median | 6.1 µs | 3.6 µs (microui) | 1.694 |
| Text frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| Springs frame median | 22.7 µs | 12 µs (microui) | 1.892 |
| Resize frame median | 6.6 µs | 17.3 µs (microui) | 0.382 |
| First frame | 0.342 ms | 0.312 ms (Nuklear) | 1.095 |
| Idle resident memory | 404 KiB | 412 KiB (Nuklear) | 0.981 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 9.3 | 6.1 / 7.8 | 0.1 / 0.1 | 22.7 / 30.0 | 6.6 / 7.2 | 0.1 / 0.1 |
| Clay | 23.3 / 29.8 | 18.9 / 24.9 | 28.5 / 34.6 | 91.0 / 100.0 | 28.8 / 34.8 | 23.4 / 29.5 |
| Dear ImGui | 12.9 / 19.0 | 8.9 / 14.5 | 64.1 / 73.0 | 44.4 / 55.9 | 63.3 / 100.2 | 13.1 / 19.1 |
| egui | 172.1 / 298.6 | 198.8 / 215.7 | 106.5 / 120.4 | 260.7 / 278.0 | 230.9 / 277.5 | 0.0 / 0.0 |
| Iced | 20.4 / 27.4 | 94.0 / 141.9 | 17.3 / 23.5 | 128.5 / 146.6 | 112.1 / 206.4 | 0.0 / 0.0 |
| LVGL | 0.6 / 0.8 | 630.3 / 733.1 | 0.9 / 1.6 | 2375.6 / 3466.6 | 1434.7 / 2990.4 | 0.2 / 0.2 |
| Slint | 39.6 / 291.8 | 1167.2 / 1552.4 | 26.7 / 32.6 | 3813.2 / 5058.4 | 1829.5 / 3631.3 | 0.2 / 0.2 |
| Qt Quick | 47.7 / 177.8 | 64.8 / 80.7 | 70.7 / 86.6 | 9336.3 / 15642.3 | 115.7 / 1973.8 | 2.3 / 2.3 |
| Nuklear | 7.0 / 7.9 | 4.9 / 5.2 | 47.4 / 54.4 | 21.9 / 27.8 | 47.7 / 61.8 | 6.9 / 7.2 |
| microui | 7.1 / 7.6 | 3.6 / 3.7 | 16.8 / 22.8 | 12.0 / 17.7 | 17.3 / 27.5 | 7.4 / 10.6 |
| GTK 4 | 30.7 / 43.0 | 1956.8 / 9917.2 | 31.3 / 43.7 | 969.0 / 1986.8 | 1743.7 / 4194.8 | 1.9 / 2.0 |
| Qt Widgets | 1314.5 / 1403.8 | 491.0 / 515.0 | 1487.8 / 1540.0 | 7260.4 / 8972.6 | 4574.7 / 6705.5 | 1.3 / 1.4 |

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
| Slint | 721 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,808 / 5,808 | 5,728 / 5,728 | 8,380 / 8,380 | 4,752 / 4,752 | 10,160 / 10,160 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,904 / 15,904 | 13,716 / 13,716 | 21,012 / 21,012 | 13,988 / 13,988 |
| Qt Quick | 68,796 / 68,796 | 67,752 / 67,752 | 70,372 / 70,372 | 939,248 / 939,248 | 77,076 / 93,920 | 66,920 / 66,920 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,912 / 46,356 | 52,160 / 55,908 | 42,700 / 50,376 | 44,628 / 46,912 | 44,856 / 44,856 | 42,816 / 46,352 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 46,660 / 54,428 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.342 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.330 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 0.980 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.571 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.044 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.554 | 3528 | 3528 | 30.0 | 669,321 | 1,020,080 | 2,457,760 |
| Slint | 22.608 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 61.172 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.312 | 412 | 412 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.346 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 67.851 | 42776 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 33.668 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 5.72 / 6.65 | 1.89 / 1.97 | 5.57 / 6.67 |
| Clay | 4.79 / 5.74 | 1.65 / 1.96 | 4.46 / 6.03 |
| Dear ImGui | 5.39 / 5.87 | 1.85 / 1.97 | 4.57 / 5.36 |
| egui | 5.45 / 5.76 | 1.64 / 1.98 | 4.74 / 5.42 |
| Iced | 4.52 / 5.47 | 1.60 / 1.96 | 5.02 / 5.54 |
| LVGL | 4.31 / 5.15 | 1.64 / 1.90 | 4.15 / 5.25 |
| Slint | 6.60 / 7.01 | 1.89 / 2.00 | 6.46 / 6.62 |
| Qt Quick | 11.06 / 13.93 | 6.20 / 6.61 | 13.54 / 14.57 |
| Nuklear | 4.26 / 5.22 | 1.64 / 1.90 | 4.34 / 4.91 |
| microui | 4.66 / 5.24 | 1.61 / 1.94 | 4.36 / 4.96 |
| GTK 4 | 33.62 / 34.44 | 16.92 / 17.82 | 24.70 / 26.92 |
| Qt Widgets | 11.63 / 12.11 | 6.23 / 6.39 | 13.83 / 14.65 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/e27d95a05c476ab6d1aa2a22f4717746c1037865/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/e27d95a05c476ab6d1aa2a22f4717746c1037865/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
