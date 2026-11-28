# GUI framework benchmark results

Measured 2026-11-28 15:15 UTC at [`cacfa42845`](https://github.com/OmarSiwy/LCGF/commit/cacfa428453ed53427565bd9aa913f5a68319e04). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46155894226)

INTEL(R) XEON(R) PLATINUM 8573C, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.8.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 7.6 µs | 5 µs (microui) | 1.520 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 36.6 µs | 17.3 µs (microui) | 2.116 |
| Resize frame median | 9.3 µs | 27.2 µs (microui) | 0.342 |
| First frame | 0.296 ms | 0.28 ms (Nuklear) | 1.059 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 11.9 | 7.6 / 13.5 | 0.1 / 0.1 | 36.6 / 42.5 | 9.3 / 15.0 | 0.1 / 0.1 |
| Clay | 28.9 / 35.2 | 24.1 / 30.9 | 35.1 / 41.4 | 122.2 / 137.5 | 35.0 / 41.0 | 29.0 / 34.6 |
| Dear ImGui | 16.2 / 24.5 | 11.5 / 16.8 | 96.6 / 110.2 | 55.7 / 63.7 | 92.6 / 147.6 | 16.4 / 22.3 |
| egui | 233.5 / 332.4 | 258.4 / 292.7 | 136.1 / 151.1 | 339.2 / 369.7 | 300.4 / 363.6 | 0.0 / 0.0 |
| Iced | 24.9 / 32.5 | 125.7 / 184.0 | 21.3 / 27.6 | 166.4 / 178.2 | 159.6 / 281.5 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.0 | 876.5 / 1003.3 | 1.2 / 2.2 | 3564.5 / 3701.2 | 2072.6 / 4069.3 | 0.3 / 0.3 |
| Slint | 50.3 / 391.4 | 1715.4 / 1796.0 | 34.6 / 40.5 | 6111.2 / 6420.1 | 2579.5 / 5159.8 | 0.2 / 0.2 |
| Qt Quick | 146.5 / 170.6 | 274.6 / 293.7 | 282.3 / 301.6 | 13005.5 / 17102.8 | 389.6 / 1873.9 | 2.3 / 2.5 |
| Nuklear | 8.9 / 14.1 | 6.3 / 11.4 | 60.6 / 68.7 | 29.6 / 35.4 | 61.2 / 75.5 | 8.8 / 11.1 |
| microui | 10.8 / 15.8 | 5.0 / 5.2 | 26.7 / 33.2 | 17.3 / 22.7 | 27.2 / 42.9 | 10.8 / 16.2 |
| GTK 4 | 45.2 / 69.1 | 2535.4 / 9341.4 | 32.5 / 54.6 | 1412.6 / 3046.4 | 2363.7 / 5794.2 | 1.3 / 1.4 |
| Qt Widgets | 4542.4 / 4805.0 | 698.2 / 754.9 | 1365.6 / 1573.7 | 8026.7 / 9436.1 | 6081.0 / 7639.5 | 1.2 / 1.3 |

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
| Slint | 784 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Slint | 14,012 / 14,012 | 15,628 / 15,628 | 15,900 / 15,900 | 13,720 / 13,720 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,796 / 68,796 | 67,752 / 67,752 | 70,368 / 70,368 | 939,248 / 939,248 | 76,412 / 93,928 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,940 / 46,356 | 52,168 / 55,920 | 42,688 / 50,364 | 44,644 / 46,848 | 44,900 / 44,900 | 42,808 / 46,356 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 47,152 / 54,972 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.296 | 404 | 404 | 0.0 | 69,191 | 32,952 | 0 |
| Clay | 0.329 | 424 | 424 | 0.0 | 99,573 | 100,864 | 2,457,760 |
| Dear ImGui | 1.041 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.686 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.046 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.260 | 3528 | 3528 | 30.0 | 669,357 | 1,020,048 | 2,457,760 |
| Slint | 25.465 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 63.063 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.280 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.331 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 71.183 | 42780 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 34.632 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 5.77 / 6.81 | 1.74 / 2.02 | 5.86 / 6.51 |
| Clay | 5.09 / 6.48 | 1.69 / 1.91 | 5.04 / 6.66 |
| Dear ImGui | 5.78 / 7.07 | 1.75 / 1.92 | 5.56 / 6.65 |
| egui | 5.14 / 6.60 | 1.70 / 1.85 | 5.26 / 6.61 |
| Iced | 5.47 / 7.25 | 1.73 / 1.99 | 6.24 / 7.17 |
| LVGL | 6.00 / 6.59 | 1.73 / 1.88 | 6.25 / 6.76 |
| Slint | 8.91 / 9.22 | 1.82 / 2.05 | 8.66 / 10.99 |
| Qt Quick | 8.16 / 8.75 | 3.46 / 3.60 | 8.81 / 9.04 |
| Nuklear | 6.38 / 6.60 | 1.75 / 1.92 | 6.24 / 6.65 |
| microui | 6.34 / 6.52 | 1.75 / 1.90 | 6.32 / 6.47 |
| GTK 4 | 31.37 / 32.77 | 16.32 / 19.75 | 22.21 / 24.43 |
| Qt Widgets | 8.86 / 9.34 | 3.67 / 3.73 | 9.01 / 9.44 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/cacfa428453ed53427565bd9aa913f5a68319e04/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/cacfa428453ed53427565bd9aa913f5a68319e04/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
