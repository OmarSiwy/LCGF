# GUI framework benchmark results

Measured 2026-11-18 01:42 UTC at [`b6c1319e9b`](https://github.com/OmarSiwy/LCGF/commit/b6c1319e9b6ff35a2fa148767f4e4aab05831626). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/44213626846)

Intel(R) Xeon(R) 6975P-C, Linux 7.0.0-1016-aws x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.6 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.7 µs (LVGL) | 0.143 |
| List frame median | 8.9 µs | 4.2 µs (microui) | 2.119 |
| Text frame median | 0.1 µs | 1 µs (LVGL) | 0.100 |
| Springs frame median | 46.4 µs | 15.5 µs (microui) | 2.994 |
| Resize frame median | 12.5 µs | 23 µs (microui) | 0.543 |
| First frame | 0.262 ms | 0.23 ms (Nuklear) | 1.140 |
| Idle resident memory | 400 KiB | 412 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.1 | 8.9 / 15.9 | 0.1 / 0.1 | 46.4 / 56.3 | 12.5 / 20.1 | 0.1 / 0.1 |
| Clay | 25.8 / 34.3 | 21.7 / 29.8 | 31.8 / 40.4 | 115.6 / 126.5 | 31.8 / 40.1 | 25.9 / 34.0 |
| Dear ImGui | 13.8 / 22.4 | 9.4 / 17.5 | 95.8 / 108.0 | 49.6 / 58.5 | 94.8 / 144.8 | 13.8 / 22.3 |
| egui | 206.3 / 280.7 | 230.8 / 250.5 | 119.6 / 136.3 | 288.0 / 306.0 | 272.9 / 337.7 | 0.0 / 0.0 |
| Iced | 23.0 / 32.8 | 112.1 / 163.9 | 19.2 / 28.1 | 156.3 / 169.4 | 157.2 / 259.6 | 0.0 / 0.0 |
| LVGL | 0.7 / 0.9 | 768.8 / 868.9 | 1.0 / 1.8 | 3071.0 / 3132.1 | 1848.0 / 3369.7 | 0.3 / 0.3 |
| Slint | 43.9 / 345.4 | 1621.8 / 1661.6 | 30.3 / 38.4 | 5568.8 / 5647.7 | 2406.1 / 4876.4 | 0.2 / 0.2 |
| Qt Quick | 152.6 / 179.0 | 293.6 / 313.0 | 300.0 / 322.4 | 11702.3 / 15883.6 | 388.5 / 1782.9 | 2.4 / 3.2 |
| Nuklear | 8.0 / 13.8 | 5.8 / 9.9 | 56.0 / 66.5 | 27.2 / 34.8 | 56.5 / 70.3 | 7.8 / 13.4 |
| microui | 9.3 / 16.6 | 4.2 / 6.0 | 22.5 / 30.7 | 15.5 / 23.3 | 23.0 / 37.1 | 9.3 / 16.9 |
| GTK 4 | 35.7 / 51.6 | 2308.2 / 9647.6 | 35.7 / 50.2 | 1205.8 / 3447.1 | 2200.8 / 5326.9 | 1.2 / 1.3 |
| Qt Widgets | 4135.0 / 4219.1 | 644.2 / 673.9 | 1249.5 / 1299.5 | 7270.3 / 8617.5 | 5628.1 / 7046.5 | 1.2 / 1.3 |

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
| GTK 4 | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |
| Qt Widgets | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |

## Resident memory by workload

Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. Linux reports its resident pages after 3,000 polls and the highest resident count since launch. Both columns are medians across runs and include resident shared pages.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 500 / 500 | 492 / 492 | 504 / 504 | 1,496 / 1,496 | 504 / 504 | 500 / 500 |
| Clay | 2,140 / 2,140 | 2,124 / 2,124 | 2,128 / 2,128 | 2,444 / 2,444 | 2,132 / 2,132 | 2,140 / 2,140 |
| Dear ImGui | 3,856 / 3,856 | 3,860 / 3,860 | 4,148 / 4,148 | 4,040 / 4,124 | 4,568 / 4,656 | 3,856 / 3,856 |
| egui | 7,252 / 7,572 | 7,348 / 7,348 | 8,144 / 8,164 | 6,096 / 6,096 | 9,272 / 9,272 | 7,488 / 7,572 |
| Iced | 5,808 / 5,808 | 5,728 / 5,728 | 8,388 / 8,388 | 4,752 / 4,752 | 10,216 / 10,216 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,020 / 14,020 | 15,632 / 15,632 | 15,900 / 15,900 | 13,720 / 13,720 | 21,016 / 21,016 | 13,996 / 13,996 |
| Qt Quick | 68,796 / 68,796 | 67,756 / 67,756 | 70,372 / 70,372 | 939,252 / 939,252 | 76,404 / 93,912 | 66,908 / 66,908 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,928 / 46,308 | 52,208 / 55,960 | 42,736 / 50,412 | 44,628 / 46,912 | 44,976 / 44,976 | 42,808 / 46,356 |
| Qt Widgets | 36,772 / 36,772 | 39,644 / 39,644 | 38,752 / 38,752 | 59,084 / 59,084 | 47,136 / 55,544 | 36,808 / 36,808 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.262 | 400 | 400 | 0.0 | 65,258 | 32,792 | 0 |
| Clay | 0.262 | 424 | 424 | 0.0 | 99,573 | 100,864 | 2,457,760 |
| Dear ImGui | 0.954 | 3772 | 3772 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.456 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 2.761 | 5772 | 5772 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.900 | 3528 | 3528 | 30.0 | 669,357 | 1,020,048 | 2,457,760 |
| Slint | 22.150 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 55.778 | 66896 | 66896 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.230 | 412 | 412 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.267 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 63.472 | 42780 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 30.585 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.57 / 7.22 | 1.98 / 2.35 | 6.95 / 7.56 |
| Clay | 5.07 / 5.43 | 1.64 / 1.92 | 5.21 / 5.64 |
| Dear ImGui | 5.39 / 5.88 | 1.76 / 2.04 | 5.50 / 6.13 |
| egui | 5.29 / 5.64 | 1.67 / 1.99 | 5.38 / 5.75 |
| Iced | 5.82 / 6.04 | 1.70 / 1.93 | 5.83 / 6.35 |
| LVGL | 4.37 / 5.24 | 1.66 / 1.94 | 5.11 / 5.70 |
| Slint | 8.01 / 8.70 | 1.76 / 2.12 | 7.81 / 9.16 |
| Qt Quick | 8.11 / 9.43 | 3.64 / 4.27 | 8.78 / 9.59 |
| Nuklear | 4.50 / 5.46 | 1.67 / 1.90 | 5.08 / 5.78 |
| microui | 4.80 / 5.30 | 1.67 / 1.92 | 5.10 / 5.80 |
| GTK 4 | 33.26 / 33.95 | 15.47 / 18.51 | 22.57 / 23.95 |
| Qt Widgets | 8.83 / 9.75 | 3.54 / 3.94 | 8.76 / 9.16 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/b6c1319e9b6ff35a2fa148767f4e4aab05831626/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/b6c1319e9b6ff35a2fa148767f4e4aab05831626/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
