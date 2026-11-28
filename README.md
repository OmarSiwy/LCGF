# GUI framework benchmark results

Measured 2026-11-28 01:07 UTC at [`af978edd6a`](https://github.com/OmarSiwy/LCGF/commit/af978edd6a3b20c3a8b516fbbc8b6676d23595f4). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46088608282)

AMD EPYC 9V45 96-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 2.0.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.6 µs (LVGL) | 0.167 |
| List frame median | 5.9 µs | 3.5 µs (microui) | 1.686 |
| Text frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| Springs frame median | 22.4 µs | 11.4 µs (microui) | 1.965 |
| Resize frame median | 6.5 µs | 16.4 µs (microui) | 0.396 |
| First frame | 0.314 ms | 0.285 ms (Nuklear) | 1.103 |
| Idle resident memory | 404 KiB | 412 KiB (Nuklear) | 0.981 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 9.0 | 5.9 / 6.0 | 0.1 / 0.1 | 22.4 / 29.2 | 6.5 / 6.6 | 0.1 / 0.1 |
| Clay | 22.3 / 28.0 | 18.1 / 23.7 | 27.3 / 33.0 | 86.6 / 95.0 | 27.2 / 32.9 | 22.2 / 27.9 |
| Dear ImGui | 12.1 / 17.7 | 8.4 / 11.7 | 62.3 / 69.4 | 43.4 / 49.8 | 63.7 / 99.6 | 12.2 / 18.0 |
| egui | 161.9 / 282.7 | 198.2 / 218.9 | 102.9 / 118.5 | 255.2 / 276.1 | 223.1 / 264.2 | 0.0 / 0.0 |
| Iced | 19.3 / 25.4 | 92.1 / 141.7 | 16.6 / 22.5 | 121.2 / 138.9 | 105.3 / 184.4 | 0.0 / 0.0 |
| LVGL | 0.6 / 0.8 | 628.9 / 733.2 | 0.9 / 1.6 | 2368.8 / 2519.9 | 1420.8 / 2903.7 | 0.2 / 0.2 |
| Slint | 36.3 / 271.9 | 1119.6 / 1199.1 | 25.6 / 31.3 | 3653.1 / 3921.7 | 1854.1 / 3648.1 | 0.2 / 0.2 |
| Qt Quick | 45.8 / 55.0 | 62.3 / 74.8 | 69.3 / 82.9 | 9108.7 / 14156.7 | 118.8 / 2026.6 | 2.4 / 2.5 |
| Nuklear | 6.7 / 7.7 | 4.6 / 4.9 | 44.9 / 52.3 | 21.0 / 27.0 | 45.5 / 59.5 | 6.5 / 8.4 |
| microui | 6.9 / 9.7 | 3.5 / 3.6 | 16.1 / 21.7 | 11.4 / 16.8 | 16.4 / 26.0 | 6.9 / 7.4 |
| GTK 4 | 28.2 / 38.8 | 1957.9 / 9124.1 | 31.4 / 44.1 | 988.7 / 1997.3 | 1780.3 / 4027.2 | 2.0 / 2.1 |
| Qt Widgets | 1345.4 / 1441.4 | 484.2 / 504.8 | 1504.1 / 1586.0 | 6791.4 / 8570.8 | 4547.2 / 6285.9 | 1.3 / 1.3 |

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
| Slint | 697 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,808 / 5,808 | 5,732 / 5,732 | 8,380 / 8,380 | 4,752 / 4,752 | 10,184 / 10,184 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,904 / 15,904 | 13,716 / 13,716 | 21,008 / 21,008 | 13,992 / 13,992 |
| Qt Quick | 68,796 / 68,796 | 67,760 / 67,760 | 70,372 / 70,372 | 939,248 / 939,248 | 77,680 / 93,920 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,912 / 46,356 | 52,168 / 55,912 | 42,688 / 50,372 | 44,628 / 46,848 | 44,876 / 44,876 | 42,816 / 46,364 |
| Qt Widgets | 36,776 / 36,776 | 39,644 / 39,644 | 38,756 / 38,756 | 59,084 / 59,084 | 47,088 / 54,844 | 36,808 / 36,808 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.314 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.320 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 0.925 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.434 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.540 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.380 | 3528 | 3528 | 30.0 | 669,321 | 1,020,080 | 2,457,760 |
| Slint | 22.352 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 61.504 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.285 | 412 | 412 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.317 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 69.311 | 42776 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 32.403 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 4.73 / 6.10 | 1.61 / 1.76 | 4.42 / 5.91 |
| Clay | 4.57 / 4.94 | 1.52 / 1.85 | 4.30 / 4.43 |
| Dear ImGui | 5.08 / 5.43 | 1.58 / 1.87 | 4.45 / 4.54 |
| egui | 5.16 / 5.53 | 1.65 / 1.93 | 4.47 / 4.53 |
| Iced | 4.88 / 5.18 | 1.62 / 1.87 | 4.74 / 4.89 |
| LVGL | 4.04 / 4.91 | 1.57 / 1.84 | 4.21 / 4.58 |
| Slint | 6.51 / 6.72 | 1.86 / 2.02 | 6.13 / 6.44 |
| Qt Quick | 10.42 / 10.72 | 5.86 / 6.06 | 12.41 / 13.31 |
| Nuklear | 4.52 / 4.97 | 1.54 / 1.86 | 4.21 / 4.35 |
| microui | 3.72 / 4.79 | 1.49 / 1.81 | 3.36 / 4.36 |
| GTK 4 | 32.67 / 33.86 | 17.51 / 18.93 | 22.26 / 23.89 |
| Qt Widgets | 10.86 / 11.34 | 5.82 / 6.06 | 12.65 / 13.69 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/af978edd6a3b20c3a8b516fbbc8b6676d23595f4/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/af978edd6a3b20c3a8b516fbbc8b6676d23595f4/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
