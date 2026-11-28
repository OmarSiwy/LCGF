# GUI framework benchmark results

Measured 2026-11-28 01:39 UTC at [`af30b2f1f4`](https://github.com/OmarSiwy/LCGF/commit/af30b2f1f420c9014b530a8372b35dfc7bef22a4). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46091801664)

AMD EPYC 9V45 96-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 2.1.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.6 µs (LVGL) | 0.167 |
| List frame median | 6.1 µs | 3.4 µs (microui) | 1.794 |
| Text frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| Springs frame median | 22.6 µs | 11.3 µs (microui) | 2.000 |
| Resize frame median | 6.5 µs | 16.6 µs (microui) | 0.392 |
| First frame | 0.317 ms | 0.291 ms (Nuklear) | 1.091 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 9.1 | 6.1 / 8.9 | 0.1 / 0.1 | 22.6 / 29.4 | 6.5 / 8.1 | 0.1 / 0.1 |
| Clay | 22.4 / 28.2 | 18.1 / 23.7 | 27.2 / 32.9 | 86.4 / 94.7 | 27.2 / 32.8 | 22.3 / 27.9 |
| Dear ImGui | 12.5 / 18.1 | 8.4 / 13.4 | 62.3 / 72.8 | 43.6 / 50.2 | 63.2 / 99.1 | 12.6 / 18.3 |
| egui | 164.7 / 295.2 | 192.0 / 208.4 | 102.3 / 114.2 | 254.5 / 279.2 | 243.0 / 289.1 | 0.0 / 0.0 |
| Iced | 20.3 / 27.1 | 96.7 / 145.7 | 17.3 / 23.5 | 129.8 / 144.3 | 116.4 / 201.6 | 0.0 / 0.0 |
| LVGL | 0.6 / 0.7 | 608.5 / 728.8 | 0.9 / 1.6 | 2359.8 / 2512.5 | 1412.7 / 2897.8 | 0.2 / 0.2 |
| Slint | 40.3 / 296.1 | 1212.4 / 1260.8 | 27.9 / 34.1 | 3980.5 / 4113.2 | 1982.8 / 3912.8 | 0.2 / 0.2 |
| Qt Quick | 47.8 / 57.0 | 75.0 / 85.4 | 82.3 / 93.2 | 9005.2 / 14224.7 | 126.2 / 1896.1 | 2.2 / 2.2 |
| Nuklear | 6.7 / 10.4 | 4.6 / 5.1 | 46.1 / 52.7 | 21.0 / 26.5 | 46.5 / 60.7 | 6.6 / 7.7 |
| microui | 6.9 / 8.2 | 3.4 / 3.6 | 16.0 / 21.8 | 11.3 / 16.8 | 16.6 / 27.4 | 6.9 / 8.7 |
| GTK 4 | 26.0 / 36.4 | 1831.5 / 8643.8 | 25.8 / 35.4 | 910.3 / 1857.9 | 1644.7 / 3910.5 | 1.8 / 1.9 |
| Qt Widgets | 1245.3 / 1324.2 | 460.8 / 500.2 | 1396.6 / 1510.8 | 6326.8 / 7844.1 | 4305.2 / 5971.5 | 1.2 / 1.2 |

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
| Slint | 722 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,804 / 5,804 | 5,732 / 5,732 | 8,380 / 8,380 | 4,752 / 4,752 | 10,164 / 10,164 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,900 / 15,900 | 13,716 / 13,716 | 21,008 / 21,008 | 13,992 / 13,992 |
| Qt Quick | 68,792 / 68,792 | 67,752 / 67,752 | 70,376 / 70,376 | 939,244 / 939,244 | 77,352 / 93,912 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,940 / 46,320 | 51,948 / 55,780 | 42,748 / 50,372 | 44,616 / 46,848 | 44,852 / 44,852 | 42,808 / 46,356 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,752 / 38,752 | 59,084 / 59,084 | 47,992 / 55,732 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.317 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.324 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 0.931 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.615 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.948 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.392 | 3528 | 3528 | 30.0 | 669,321 | 1,020,080 | 2,457,760 |
| Slint | 24.631 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 58.254 | 66896 | 66896 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.291 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.323 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 62.810 | 42776 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 30.336 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 5.16 / 5.74 | 1.69 / 1.90 | 5.19 / 6.02 |
| Clay | 4.59 / 5.03 | 1.50 / 1.62 | 4.30 / 4.58 |
| Dear ImGui | 4.25 / 5.34 | 1.62 / 1.88 | 3.43 / 4.90 |
| egui | 4.93 / 5.47 | 1.55 / 1.86 | 4.42 / 4.78 |
| Iced | 4.24 / 5.22 | 1.52 / 1.60 | 3.63 / 4.90 |
| LVGL | 3.77 / 4.54 | 1.54 / 1.66 | 3.55 / 4.86 |
| Slint | 5.76 / 6.64 | 1.51 / 1.95 | 5.15 / 6.41 |
| Qt Quick | 10.40 / 10.79 | 5.84 / 6.05 | 12.41 / 12.77 |
| Nuklear | 3.83 / 4.93 | 1.56 / 1.89 | 3.54 / 4.89 |
| microui | 3.85 / 4.77 | 1.53 / 1.84 | 3.72 / 4.50 |
| GTK 4 | 32.74 / 33.49 | 17.06 / 18.28 | 22.32 / 23.76 |
| Qt Widgets | 10.98 / 11.17 | 5.88 / 5.95 | 12.79 / 13.32 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/af30b2f1f420c9014b530a8372b35dfc7bef22a4/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/af30b2f1f420c9014b530a8372b35dfc7bef22a4/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
