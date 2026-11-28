# GUI framework benchmark results

Measured 2026-11-28 02:57 UTC at [`87b2a9d93f`](https://github.com/OmarSiwy/LCGF/commit/87b2a9d93f180d858a11aa7e69283d8d6c63f566). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46097648377)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 2.0.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.8 µs (LVGL) | 0.125 |
| List frame median | 8.9 µs | 4.6 µs (microui) | 1.935 |
| Text frame median | 0.1 µs | 1.2 µs (LVGL) | 0.083 |
| Springs frame median | 38.2 µs | 16.8 µs (microui) | 2.274 |
| Resize frame median | 10.2 µs | 24.5 µs (microui) | 0.416 |
| First frame | 0.399 ms | 0.383 ms (Nuklear) | 1.041 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 14.1 | 8.9 / 14.6 | 0.1 / 0.1 | 38.2 / 47.8 | 10.2 / 16.8 | 0.1 / 0.1 |
| Clay | 32.3 / 40.2 | 26.1 / 33.8 | 36.6 / 44.5 | 122.7 / 138.0 | 36.6 / 46.0 | 32.2 / 40.7 |
| Dear ImGui | 16.2 / 24.0 | 12.2 / 19.1 | 96.4 / 109.3 | 67.7 / 78.4 | 93.7 / 150.7 | 16.2 / 23.7 |
| egui | 202.7 / 349.1 | 243.1 / 269.3 | 115.1 / 133.2 | 285.4 / 310.5 | 282.6 / 351.4 | 0.0 / 0.0 |
| Iced | 24.7 / 32.4 | 123.8 / 183.8 | 21.9 / 29.5 | 166.4 / 183.9 | 145.7 / 260.5 | 0.0 / 0.0 |
| LVGL | 0.8 / 1.0 | 835.3 / 1098.7 | 1.2 / 2.1 | 3573.8 / 3669.0 | 2008.5 / 3871.9 | 0.3 / 0.3 |
| Slint | 24.9 / 320.5 | 1446.4 / 1502.3 | 15.2 / 22.3 | 5571.4 / 5681.2 | 2470.8 / 5072.9 | 0.2 / 0.2 |
| Qt Quick | 59.4 / 73.5 | 91.0 / 105.6 | 99.9 / 114.9 | 12408.4 / 17038.7 | 163.5 / 2143.1 | 2.7 / 3.0 |
| Nuklear | 8.9 / 14.0 | 6.1 / 8.2 | 64.2 / 73.5 | 27.8 / 35.3 | 64.4 / 79.4 | 8.9 / 15.1 |
| microui | 10.4 / 17.3 | 4.6 / 4.8 | 24.0 / 31.6 | 16.8 / 23.9 | 24.5 / 39.6 | 10.4 / 17.1 |
| GTK 4 | 33.3 / 56.0 | 2799.7 / 11326.1 | 41.1 / 59.1 | 1285.1 / 2765.5 | 2266.9 / 5330.8 | 2.5 / 2.8 |
| Qt Widgets | 1859.4 / 1966.2 | 531.5 / 583.8 | 1473.5 / 1557.5 | 8758.0 / 10835.2 | 5587.0 / 7472.6 | 1.4 / 1.6 |

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
| Slint | 693 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,804 / 5,804 | 5,732 / 5,732 | 8,376 / 8,376 | 4,752 / 4,752 | 10,160 / 10,160 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,020 / 14,020 | 15,628 / 15,628 | 15,900 / 15,900 | 13,716 / 13,716 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,800 / 68,800 | 67,760 / 67,760 | 70,372 / 70,372 | 939,248 / 939,248 | 77,452 / 97,032 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,928 / 46,384 | 51,676 / 55,536 | 42,684 / 50,364 | 44,644 / 46,848 | 44,960 / 44,960 | 42,836 / 46,384 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,752 / 38,752 | 59,084 / 59,084 | 46,216 / 54,956 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.399 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.406 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.105 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.932 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.283 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.229 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 29.465 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 78.040 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.383 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.404 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 83.386 | 42812 | 46384 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 39.310 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 6.72 / 7.03 | 2.66 / 2.78 | 6.31 / 7.57 |
| Clay | 6.24 / 6.59 | 2.43 / 2.75 | 5.41 / 5.82 |
| Dear ImGui | 7.27 / 7.46 | 2.51 / 2.84 | 5.90 / 6.25 |
| egui | 7.24 / 7.46 | 2.49 / 2.68 | 6.08 / 6.47 |
| Iced | 6.65 / 6.81 | 2.48 / 2.76 | 5.94 / 6.33 |
| LVGL | 5.61 / 6.32 | 2.39 / 2.89 | 5.01 / 5.85 |
| Slint | 9.23 / 9.39 | 2.63 / 2.98 | 10.58 / 11.07 |
| Qt Quick | 13.01 / 13.08 | 6.69 / 6.82 | 16.21 / 16.63 |
| Nuklear | 6.16 / 6.48 | 2.48 / 2.60 | 5.57 / 5.96 |
| microui | 5.03 / 6.41 | 2.36 / 2.75 | 4.50 / 5.53 |
| GTK 4 | 35.41 / 36.44 | 11.27 / 13.55 | 28.07 / 31.92 |
| Qt Widgets | 13.57 / 13.80 | 6.82 / 6.93 | 15.48 / 15.88 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/87b2a9d93f180d858a11aa7e69283d8d6c63f566/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/87b2a9d93f180d858a11aa7e69283d8d6c63f566/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
