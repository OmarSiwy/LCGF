# GUI framework benchmark results

Measured 2026-11-28 01:13 UTC at [`7c9930530e`](https://github.com/OmarSiwy/LCGF/commit/7c9930530e50f21ff14d232a7aef2cad8d171e29). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46089031643)

Intel(R) Xeon(R) 6975P-C, Linux 7.0.0-1018-aws x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.7 µs (LVGL) | 0.143 |
| List frame median | 7 µs | 4.2 µs (microui) | 1.667 |
| Text frame median | 0.1 µs | 1 µs (LVGL) | 0.100 |
| Springs frame median | 33 µs | 15.5 µs (microui) | 2.129 |
| Resize frame median | 8.5 µs | 23 µs (microui) | 0.370 |
| First frame | 0.273 ms | 0.26 ms (Nuklear) | 1.050 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 11.0 | 7.0 / 11.1 | 0.1 / 0.1 | 33.0 / 42.2 | 8.5 / 15.7 | 0.1 / 0.1 |
| Clay | 25.8 / 35.1 | 21.8 / 30.9 | 31.9 / 40.7 | 118.0 / 129.9 | 32.0 / 41.0 | 25.3 / 33.9 |
| Dear ImGui | 13.7 / 23.1 | 9.4 / 17.9 | 95.4 / 108.8 | 50.8 / 61.3 | 95.2 / 145.6 | 14.0 / 23.0 |
| egui | 207.9 / 280.2 | 232.1 / 251.2 | 119.7 / 136.2 | 284.8 / 302.0 | 271.8 / 334.9 | 0.0 / 0.0 |
| Iced | 23.0 / 32.6 | 110.7 / 162.7 | 19.1 / 27.8 | 155.6 / 167.9 | 154.7 / 258.2 | 0.0 / 0.0 |
| LVGL | 0.7 / 0.9 | 783.6 / 887.1 | 1.0 / 1.7 | 3082.9 / 3184.8 | 1865.5 / 3394.0 | 0.3 / 0.3 |
| Slint | 43.8 / 351.9 | 1617.2 / 1658.8 | 30.4 / 38.4 | 5572.8 / 5665.1 | 2394.1 / 4839.3 | 0.2 / 0.2 |
| Qt Quick | 153.4 / 179.0 | 293.9 / 314.4 | 300.3 / 323.6 | 11861.5 / 16323.7 | 386.5 / 1889.5 | 2.4 / 3.2 |
| Nuklear | 8.0 / 13.8 | 5.8 / 10.1 | 56.1 / 68.0 | 27.2 / 36.0 | 56.3 / 71.1 | 7.8 / 13.5 |
| microui | 9.3 / 17.0 | 4.2 / 6.0 | 22.4 / 30.9 | 15.5 / 24.1 | 23.0 / 37.0 | 9.3 / 17.0 |
| GTK 4 | 19.2 / 50.8 | 2328.7 / 10123.6 | 37.1 / 53.4 | 1208.5 / 3570.6 | 2226.7 / 5343.5 | 1.2 / 1.4 |
| Qt Widgets | 4155.3 / 4252.1 | 646.3 / 683.7 | 1261.9 / 1316.6 | 7278.0 / 8721.5 | 5665.7 / 7111.6 | 1.2 / 1.3 |

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
| Slint | 754 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,808 / 5,808 | 5,728 / 5,728 | 8,380 / 8,380 | 4,752 / 4,752 | 10,148 / 10,148 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,020 / 14,020 | 15,632 / 15,632 | 15,900 / 15,900 | 13,720 / 13,720 | 21,012 / 21,012 | 13,996 / 13,996 |
| Qt Quick | 68,800 / 68,800 | 67,756 / 67,756 | 70,368 / 70,368 | 939,252 / 939,252 | 76,412 / 93,916 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 43,008 / 46,356 | 52,188 / 55,960 | 42,736 / 50,412 | 44,632 / 46,912 | 44,940 / 44,940 | 42,836 / 46,384 |
| Qt Widgets | 36,776 / 36,776 | 39,640 / 39,640 | 38,752 / 38,752 | 59,084 / 59,084 | 46,784 / 55,524 | 36,808 / 36,808 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.273 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.271 | 424 | 424 | 0.0 | 99,573 | 100,864 | 2,457,760 |
| Dear ImGui | 0.993 | 3772 | 3772 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.414 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 2.716 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.951 | 3528 | 3528 | 30.0 | 669,357 | 1,020,048 | 2,457,760 |
| Slint | 22.336 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 60.418 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.260 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.287 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 66.327 | 42808 | 46384 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 32.118 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.13 / 6.67 | 1.70 / 1.96 | 7.09 / 8.20 |
| Clay | 4.24 / 5.08 | 1.56 / 1.81 | 4.54 / 5.26 |
| Dear ImGui | 4.46 / 5.34 | 1.58 / 2.21 | 4.93 / 5.56 |
| egui | 4.51 / 5.41 | 1.75 / 2.13 | 4.97 / 5.47 |
| Iced | 5.53 / 5.93 | 1.65 / 1.90 | 5.59 / 6.08 |
| LVGL | 4.21 / 5.12 | 1.70 / 2.07 | 4.73 / 5.49 |
| Slint | 6.75 / 7.62 | 1.51 / 1.85 | 6.84 / 7.53 |
| Qt Quick | 8.29 / 8.60 | 3.39 / 3.81 | 8.89 / 9.25 |
| Nuklear | 4.30 / 5.39 | 1.61 / 1.98 | 4.78 / 5.28 |
| microui | 4.98 / 5.20 | 1.57 / 1.98 | 5.03 / 5.50 |
| GTK 4 | 32.26 / 33.22 | 18.29 / 20.45 | 22.69 / 23.38 |
| Qt Widgets | 9.02 / 9.34 | 3.41 / 3.85 | 8.97 / 9.34 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/7c9930530e50f21ff14d232a7aef2cad8d171e29/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/7c9930530e50f21ff14d232a7aef2cad8d171e29/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
