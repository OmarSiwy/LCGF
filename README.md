# GUI framework benchmark results

Measured 2026-11-27 23:25 UTC at [`367ce9a403`](https://github.com/OmarSiwy/LCGF/commit/367ce9a40342c8483c78ea07ee85bd76b543e73f). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46079081079)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 9 µs | 4.6 µs (microui) | 1.957 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 38.3 µs | 16.8 µs (microui) | 2.280 |
| Resize frame median | 10.3 µs | 24.2 µs (microui) | 0.426 |
| First frame | 0.405 ms | 0.38 ms (Nuklear) | 1.065 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.0 | 9.0 / 14.5 | 0.1 / 0.1 | 38.3 / 49.5 | 10.3 / 16.9 | 0.1 / 0.1 |
| Clay | 32.5 / 41.4 | 26.2 / 34.1 | 36.6 / 45.5 | 122.8 / 138.5 | 36.5 / 45.0 | 32.2 / 40.3 |
| Dear ImGui | 16.2 / 23.6 | 12.3 / 19.8 | 96.3 / 109.5 | 67.8 / 81.9 | 91.7 / 150.8 | 16.2 / 23.9 |
| egui | 202.1 / 352.8 | 243.5 / 276.2 | 115.4 / 134.9 | 285.8 / 310.5 | 282.7 / 345.7 | 0.0 / 0.0 |
| Iced | 24.2 / 32.8 | 123.7 / 185.5 | 22.0 / 30.2 | 166.5 / 187.4 | 145.8 / 262.6 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.0 | 838.8 / 979.4 | 1.2 / 2.1 | 3575.4 / 3669.9 | 2013.3 / 3875.2 | 0.3 / 0.3 |
| Slint | 25.0 / 335.2 | 1447.1 / 1505.7 | 15.1 / 22.1 | 5585.3 / 5867.1 | 2465.8 / 5077.2 | 0.2 / 0.2 |
| Qt Quick | 59.1 / 75.7 | 91.3 / 109.9 | 99.9 / 116.9 | 12555.0 / 18166.0 | 165.6 / 2266.1 | 2.7 / 3.0 |
| Nuklear | 8.9 / 15.5 | 6.1 / 6.6 | 64.1 / 73.1 | 27.9 / 35.6 | 64.3 / 79.5 | 8.9 / 15.2 |
| microui | 10.3 / 17.2 | 4.6 / 4.9 | 23.9 / 31.3 | 16.8 / 24.3 | 24.2 / 39.2 | 10.3 / 16.8 |
| GTK 4 | 33.4 / 49.0 | 2906.2 / 11869.8 | 33.9 / 60.8 | 1294.0 / 2854.4 | 2288.2 / 5506.8 | 2.5 / 2.7 |
| Qt Widgets | 1867.3 / 1985.3 | 533.0 / 582.8 | 1482.0 / 1588.7 | 9067.4 / 11160.0 | 5591.8 / 7446.4 | 1.4 / 1.5 |

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
| Slint | 690 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,804 / 5,804 | 5,732 / 5,732 | 8,372 / 8,372 | 4,752 / 4,752 | 10,180 / 10,180 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,900 / 15,900 | 13,716 / 13,716 | 21,008 / 21,008 | 13,992 / 13,992 |
| Qt Quick | 68,792 / 68,792 | 67,756 / 67,756 | 70,364 / 70,364 | 939,252 / 939,252 | 77,068 / 93,916 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,928 / 46,356 | 51,676 / 55,636 | 42,788 / 50,532 | 44,644 / 46,848 | 44,996 / 44,996 | 42,832 / 46,384 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 47,068 / 54,536 | 36,808 / 36,808 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.405 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.401 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.096 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.964 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.330 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.248 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 30.258 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 79.098 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.380 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.423 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 84.064 | 42808 | 46384 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 41.073 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.25 / 6.99 | 2.56 / 2.73 | 6.21 / 6.61 |
| Clay | 6.25 / 6.67 | 2.52 / 2.95 | 5.44 / 6.22 |
| Dear ImGui | 7.14 / 8.03 | 2.58 / 3.00 | 5.82 / 7.08 |
| egui | 6.72 / 7.45 | 2.57 / 2.79 | 5.81 / 6.38 |
| Iced | 6.68 / 7.04 | 2.53 / 2.86 | 5.86 / 6.79 |
| LVGL | 6.20 / 6.75 | 2.59 / 3.03 | 5.43 / 6.63 |
| Slint | 8.75 / 9.49 | 2.59 / 3.02 | 10.04 / 11.19 |
| Qt Quick | 13.06 / 13.51 | 6.65 / 6.91 | 16.93 / 18.01 |
| Nuklear | 5.53 / 6.59 | 2.52 / 2.95 | 5.22 / 5.67 |
| microui | 5.62 / 6.74 | 2.47 / 2.68 | 4.94 / 6.15 |
| GTK 4 | 35.94 / 36.89 | 11.13 / 12.48 | 29.04 / 38.54 |
| Qt Widgets | 13.33 / 13.99 | 6.63 / 6.86 | 15.71 / 17.33 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/367ce9a40342c8483c78ea07ee85bd76b543e73f/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/367ce9a40342c8483c78ea07ee85bd76b543e73f/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
