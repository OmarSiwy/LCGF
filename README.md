# GUI framework benchmark results

Measured 2026-11-28 02:03 UTC at [`205b6b6b37`](https://github.com/OmarSiwy/LCGF/commit/205b6b6b3786602525b60ecd6b9f7e452063ead6). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46092755300)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.8.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 8.9 µs | 4.6 µs (microui) | 1.935 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 38.2 µs | 16.8 µs (microui) | 2.274 |
| Resize frame median | 10.3 µs | 24.3 µs (microui) | 0.424 |
| First frame | 0.397 ms | 0.376 ms (Nuklear) | 1.055 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.0 | 8.9 / 15.3 | 0.1 / 0.1 | 38.2 / 49.0 | 10.3 / 16.8 | 0.1 / 0.1 |
| Clay | 32.3 / 40.4 | 26.0 / 34.0 | 36.6 / 45.7 | 122.8 / 138.1 | 36.6 / 45.5 | 32.2 / 40.6 |
| Dear ImGui | 16.3 / 23.8 | 12.2 / 19.1 | 96.3 / 110.5 | 67.8 / 78.3 | 91.2 / 150.9 | 16.2 / 23.6 |
| egui | 201.7 / 350.9 | 243.0 / 269.9 | 115.0 / 133.8 | 285.4 / 313.4 | 281.9 / 354.5 | 0.0 / 0.0 |
| Iced | 24.8 / 33.2 | 123.8 / 187.4 | 22.0 / 30.1 | 165.9 / 192.9 | 145.0 / 260.6 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.0 | 833.5 / 954.0 | 1.2 / 2.1 | 3569.7 / 3660.9 | 2009.0 / 3890.8 | 0.3 / 0.3 |
| Slint | 25.1 / 318.4 | 1446.8 / 1512.7 | 15.2 / 22.4 | 5543.6 / 5671.5 | 2465.2 / 5069.4 | 0.2 / 0.2 |
| Qt Quick | 59.4 / 73.4 | 90.7 / 104.5 | 99.7 / 117.5 | 12806.6 / 17850.1 | 159.7 / 2056.6 | 2.7 / 3.0 |
| Nuklear | 8.9 / 15.5 | 6.1 / 7.5 | 64.2 / 75.8 | 27.8 / 36.2 | 64.3 / 79.6 | 8.9 / 11.6 |
| microui | 10.4 / 17.2 | 4.6 / 4.8 | 23.9 / 31.6 | 16.8 / 23.9 | 24.3 / 39.5 | 10.4 / 17.1 |
| GTK 4 | 41.0 / 58.8 | 2795.1 / 11128.5 | 33.0 / 47.7 | 1294.8 / 2702.7 | 2264.4 / 5345.9 | 2.6 / 2.8 |
| Qt Widgets | 1859.2 / 1967.3 | 551.8 / 596.0 | 1476.7 / 1584.6 | 8745.3 / 11347.5 | 5598.4 / 7406.8 | 1.4 / 1.6 |

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
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,904 / 15,904 | 13,720 / 13,720 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,792 / 68,792 | 67,760 / 67,760 | 70,360 / 70,360 | 939,248 / 939,248 | 77,680 / 97,044 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,908 / 46,356 | 51,672 / 55,532 | 42,792 / 50,532 | 44,640 / 46,848 | 44,996 / 44,996 | 42,836 / 46,384 |
| Qt Widgets | 36,772 / 36,772 | 39,644 / 39,644 | 38,752 / 38,752 | 59,084 / 59,084 | 47,356 / 55,592 | 36,808 / 36,808 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.397 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.406 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.130 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.922 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.267 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.237 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 30.568 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 77.264 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.376 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.417 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 81.811 | 42780 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 39.558 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.53 / 7.12 | 2.29 / 2.43 | 6.48 / 7.08 |
| Clay | 6.15 / 6.65 | 2.23 / 2.73 | 5.67 / 6.58 |
| Dear ImGui | 6.98 / 7.79 | 2.47 / 2.68 | 5.97 / 7.18 |
| egui | 6.26 / 7.46 | 2.05 / 2.63 | 5.44 / 6.15 |
| Iced | 6.45 / 6.85 | 2.13 / 2.94 | 6.13 / 6.62 |
| LVGL | 6.42 / 6.70 | 2.44 / 2.84 | 6.24 / 6.54 |
| Slint | 9.29 / 9.74 | 2.56 / 2.89 | 9.28 / 11.59 |
| Qt Quick | 13.01 / 13.42 | 6.60 / 6.70 | 17.68 / 19.10 |
| Nuklear | 6.15 / 6.64 | 2.18 / 2.60 | 5.93 / 6.30 |
| microui | 6.16 / 6.86 | 2.20 / 2.84 | 5.53 / 6.28 |
| GTK 4 | 35.42 / 36.09 | 11.21 / 12.85 | 28.00 / 29.85 |
| Qt Widgets | 13.78 / 15.08 | 6.43 / 6.68 | 17.22 / 17.78 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/205b6b6b3786602525b60ecd6b9f7e452063ead6/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/205b6b6b3786602525b60ecd6b9f7e452063ead6/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
