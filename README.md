# GUI framework benchmark results

Measured 2026-11-28 05:20 UTC at [`f59fbb1dcf`](https://github.com/OmarSiwy/LCGF/commit/f59fbb1dcf71b5764c469df42efb5b74279581d4). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46109214740)

Intel(R) Xeon(R) 6973P-C, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.8.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.7 µs (LVGL) | 0.143 |
| List frame median | 7 µs | 3.8 µs (microui) | 1.842 |
| Text frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| Springs frame median | 33.2 µs | 14.4 µs (microui) | 2.306 |
| Resize frame median | 8.7 µs | 21.4 µs (microui) | 0.407 |
| First frame | 0.286 ms | 0.258 ms (Nuklear) | 1.108 |
| Idle resident memory | 404 KiB | 412 KiB (Nuklear) | 0.981 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 13.0 | 7.0 / 11.4 | 0.1 / 0.1 | 33.2 / 43.2 | 8.7 / 16.4 | 0.1 / 0.1 |
| Clay | 25.1 / 33.3 | 20.5 / 28.9 | 30.1 / 38.2 | 117.2 / 140.7 | 30.2 / 41.3 | 24.4 / 33.4 |
| Dear ImGui | 13.1 / 21.3 | 8.8 / 15.6 | 90.2 / 104.2 | 51.2 / 69.9 | 89.0 / 135.3 | 13.2 / 20.7 |
| egui | 193.1 / 273.2 | 217.5 / 252.0 | 113.5 / 146.8 | 296.9 / 411.3 | 254.4 / 318.7 | 0.0 / 0.0 |
| Iced | 21.4 / 30.9 | 102.6 / 152.0 | 18.0 / 25.9 | 141.4 / 153.4 | 152.6 / 252.0 | 0.0 / 0.0 |
| LVGL | 0.7 / 0.9 | 769.2 / 915.4 | 0.9 / 1.6 | 2855.6 / 3360.6 | 1736.7 / 3189.6 | 0.2 / 0.3 |
| Slint | 40.9 / 332.2 | 1555.7 / 1779.2 | 28.4 / 36.0 | 5289.0 / 6042.5 | 2339.9 / 4931.1 | 0.2 / 0.2 |
| Qt Quick | 154.9 / 190.1 | 295.6 / 320.0 | 302.3 / 330.8 | 11228.8 / 16591.8 | 392.8 / 1989.8 | 2.2 / 2.7 |
| Nuklear | 7.5 / 12.2 | 5.3 / 9.4 | 52.3 / 64.5 | 25.4 / 33.4 | 52.9 / 68.2 | 7.4 / 14.3 |
| microui | 8.8 / 14.0 | 3.8 / 5.4 | 20.7 / 28.6 | 14.4 / 21.2 | 21.4 / 35.1 | 10.2 / 17.8 |
| GTK 4 | 35.6 / 58.5 | 2284.9 / 10023.8 | 44.4 / 59.4 | 1150.8 / 3009.8 | 2093.1 / 4989.5 | 1.3 / 1.4 |
| Qt Widgets | 3911.9 / 4547.1 | 632.8 / 892.8 | 1175.0 / 1326.1 | 7183.6 / 9460.6 | 5321.1 / 7587.4 | 1.1 / 1.1 |

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
| Slint | 744 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Dear ImGui | 3,652 / 3,652 | 3,656 / 3,656 | 3,944 / 3,944 | 3,836 / 3,920 | 4,364 / 4,452 | 3,652 / 3,652 |
| egui | 7,252 / 7,572 | 7,348 / 7,348 | 8,144 / 8,164 | 6,096 / 6,096 | 9,272 / 9,272 | 7,488 / 7,572 |
| Iced | 5,808 / 5,808 | 5,732 / 5,732 | 8,376 / 8,376 | 4,752 / 4,752 | 10,184 / 10,184 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,900 / 15,900 | 13,716 / 13,716 | 21,008 / 21,008 | 13,992 / 13,992 |
| Qt Quick | 68,800 / 68,800 | 67,756 / 67,756 | 70,376 / 70,376 | 939,252 / 939,252 | 77,688 / 93,924 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,904 / 46,352 | 52,164 / 55,912 | 42,696 / 50,372 | 44,636 / 46,848 | 44,888 / 44,888 | 42,808 / 46,304 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 47,140 / 55,860 | 36,808 / 36,808 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.286 | 404 | 404 | 0.0 | 69,157 | 32,984 | 0 |
| Clay | 0.308 | 424 | 424 | 0.0 | 99,573 | 100,864 | 2,457,760 |
| Dear ImGui | 0.976 | 3568 | 3568 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.377 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.054 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.803 | 3528 | 3528 | 30.0 | 669,357 | 1,020,048 | 2,457,760 |
| Slint | 23.846 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 64.933 | 66892 | 66892 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.258 | 412 | 412 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.298 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 68.988 | 42792 | 46368 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 34.600 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 9.67 / 11.47 | 2.72 / 3.23 | 10.87 / 11.78 |
| Clay | 7.51 / 10.01 | 2.10 / 2.63 | 8.65 / 11.83 |
| Dear ImGui | 8.02 / 9.46 | 2.04 / 2.40 | 8.07 / 10.79 |
| egui | 8.71 / 9.79 | 2.01 / 2.26 | 8.25 / 10.96 |
| Iced | 8.55 / 11.21 | 2.20 / 2.66 | 9.51 / 13.30 |
| LVGL | 8.37 / 9.91 | 2.17 / 2.53 | 10.02 / 11.76 |
| Slint | 11.95 / 14.16 | 2.31 / 2.85 | 11.54 / 17.36 |
| Qt Quick | 10.50 / 11.28 | 4.63 / 5.41 | 10.80 / 11.58 |
| Nuklear | 6.89 / 8.79 | 2.05 / 2.43 | 8.47 / 10.50 |
| microui | 7.43 / 9.79 | 2.06 / 2.21 | 9.28 / 11.37 |
| GTK 4 | 35.87 / 37.48 | 11.30 / 15.26 | 28.07 / 31.28 |
| Qt Widgets | 11.12 / 12.36 | 4.46 / 5.03 | 10.71 / 11.71 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/f59fbb1dcf71b5764c469df42efb5b74279581d4/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/f59fbb1dcf71b5764c469df42efb5b74279581d4/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
