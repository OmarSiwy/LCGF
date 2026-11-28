# GUI framework benchmark results

Measured 2026-11-28 01:38 UTC at [`5e30337b0d`](https://github.com/OmarSiwy/LCGF/commit/5e30337b0d1c567b943c41a09302782cc336766d). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46090751957)

Intel(R) Xeon(R) 6975P-C, Linux 7.0.0-1018-aws x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.6 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.7 µs (LVGL) | 0.143 |
| List frame median | 6.9 µs | 4.3 µs (microui) | 1.605 |
| Text frame median | 0.1 µs | 1 µs (LVGL) | 0.100 |
| Springs frame median | 33.1 µs | 15.8 µs (microui) | 2.095 |
| Resize frame median | 8.6 µs | 23.4 µs (microui) | 0.368 |
| First frame | 0.284 ms | 0.254 ms (Nuklear) | 1.118 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 11.8 | 6.9 / 10.0 | 0.1 / 0.1 | 33.1 / 41.7 | 8.6 / 14.8 | 0.1 / 0.1 |
| Clay | 26.1 / 34.9 | 21.8 / 30.4 | 32.1 / 41.0 | 116.2 / 129.2 | 32.2 / 40.9 | 25.7 / 34.3 |
| Dear ImGui | 13.8 / 22.6 | 9.5 / 17.5 | 95.7 / 109.0 | 50.5 / 60.2 | 94.9 / 145.6 | 13.8 / 22.3 |
| egui | 206.7 / 283.0 | 231.8 / 252.8 | 120.4 / 137.2 | 287.6 / 306.5 | 272.4 / 336.4 | 0.0 / 0.0 |
| Iced | 23.0 / 32.9 | 110.8 / 165.3 | 19.2 / 28.2 | 155.5 / 170.2 | 152.1 / 253.8 | 0.0 / 0.0 |
| LVGL | 0.7 / 0.9 | 775.5 / 879.1 | 1.0 / 1.8 | 3085.7 / 3158.8 | 1849.0 / 3379.1 | 0.3 / 0.3 |
| Slint | 43.9 / 346.5 | 1608.5 / 1656.2 | 30.3 / 38.7 | 5583.5 / 5686.4 | 2390.7 / 4861.9 | 0.2 / 0.2 |
| Qt Quick | 152.9 / 175.7 | 292.1 / 307.5 | 299.0 / 313.1 | 11747.3 / 16049.4 | 388.4 / 1979.0 | 2.3 / 3.2 |
| Nuklear | 8.1 / 13.7 | 5.8 / 9.2 | 56.1 / 66.7 | 27.2 / 35.7 | 56.5 / 71.5 | 7.9 / 13.5 |
| microui | 9.5 / 17.2 | 4.3 / 6.3 | 22.7 / 31.1 | 15.8 / 23.7 | 23.4 / 37.7 | 9.5 / 17.0 |
| GTK 4 | 35.7 / 52.2 | 2323.6 / 9994.6 | 17.9 / 33.6 | 1208.1 / 2734.7 | 2220.9 / 5375.0 | 1.2 / 1.2 |
| Qt Widgets | 4149.7 / 4259.2 | 641.2 / 673.8 | 1253.6 / 1310.7 | 7719.4 / 9508.0 | 5679.9 / 7099.6 | 1.2 / 1.4 |

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
| Slint | 750 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Dear ImGui | 3,856 / 3,856 | 3,860 / 3,860 | 4,148 / 4,148 | 4,040 / 4,124 | 4,568 / 4,656 | 3,856 / 3,856 |
| egui | 7,252 / 7,572 | 7,348 / 7,348 | 8,144 / 8,164 | 6,096 / 6,096 | 9,272 / 9,272 | 7,488 / 7,572 |
| Iced | 5,808 / 5,808 | 5,732 / 5,732 | 8,380 / 8,380 | 4,752 / 4,752 | 10,156 / 10,156 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,020 / 14,020 | 15,628 / 15,628 | 15,900 / 15,900 | 13,720 / 13,720 | 21,012 / 21,012 | 13,996 / 13,996 |
| Qt Quick | 68,800 / 68,800 | 67,752 / 67,752 | 70,368 / 70,368 | 939,248 / 939,248 | 76,460 / 93,916 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 43,000 / 46,364 | 52,212 / 55,960 | 42,920 / 50,532 | 44,628 / 46,912 | 44,912 / 44,912 | 42,836 / 46,340 |
| Qt Widgets | 36,776 / 36,776 | 39,640 / 39,640 | 38,752 / 38,752 | 59,084 / 59,084 | 48,908 / 56,192 | 36,808 / 36,808 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.284 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.265 | 424 | 424 | 0.0 | 99,573 | 100,864 | 2,457,760 |
| Dear ImGui | 0.972 | 3772 | 3772 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.443 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 2.723 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.928 | 3528 | 3528 | 30.0 | 669,357 | 1,020,048 | 2,457,760 |
| Slint | 23.257 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 65.038 | 66896 | 66896 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.254 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.278 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 69.764 | 42780 | 46352 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 33.592 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.46 / 8.65 | 1.82 / 2.54 | 7.87 / 8.48 |
| Clay | 4.41 / 5.65 | 1.75 / 1.92 | 5.05 / 5.72 |
| Dear ImGui | 4.62 / 5.89 | 1.73 / 2.08 | 5.05 / 5.81 |
| egui | 5.36 / 6.11 | 1.75 / 2.16 | 5.46 / 5.99 |
| Iced | 5.81 / 6.44 | 1.73 / 2.08 | 5.96 / 6.45 |
| LVGL | 4.50 / 5.57 | 1.70 / 1.98 | 4.91 / 5.71 |
| Slint | 8.26 / 9.44 | 1.57 / 2.12 | 8.48 / 10.04 |
| Qt Quick | 8.69 / 10.05 | 3.70 / 4.47 | 9.68 / 10.30 |
| Nuklear | 4.67 / 6.36 | 1.74 / 1.89 | 5.35 / 6.46 |
| microui | 4.62 / 6.43 | 1.69 / 2.12 | 5.30 / 6.24 |
| GTK 4 | 33.81 / 34.54 | 15.35 / 16.81 | 23.55 / 25.19 |
| Qt Widgets | 9.58 / 9.89 | 3.71 / 4.25 | 9.41 / 9.89 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/5e30337b0d1c567b943c41a09302782cc336766d/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/5e30337b0d1c567b943c41a09302782cc336766d/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
