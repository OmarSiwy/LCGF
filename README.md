# GUI framework benchmark results

Measured 2026-11-28 08:48 UTC at [`a60ef64f9d`](https://github.com/OmarSiwy/LCGF/commit/a60ef64f9df8e909fa66d5c62d5d677cf5d69e61). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46123803707)

AMD EPYC 7763 64-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.3 µs | 1 µs (LVGL) | 0.300 |
| List frame median | 10.5 µs | 5.8 µs (microui) | 1.810 |
| Text frame median | 0.1 µs | 1.5 µs (LVGL) | 0.067 |
| Springs frame median | 38.8 µs | 20.9 µs (microui) | 1.856 |
| Resize frame median | 12.1 µs | 30.8 µs (microui) | 0.393 |
| First frame | 0.475 ms | 0.47 ms (Nuklear) | 1.011 |
| Idle resident memory | 400 KiB | 416 KiB (Nuklear) | 0.962 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.3 / 16.7 | 10.5 / 18.4 | 0.1 / 0.1 | 38.8 / 51.9 | 12.1 / 19.9 | 0.3 / 0.3 |
| Clay | 38.6 / 50.3 | 30.9 / 39.6 | 44.4 / 54.7 | 163.2 / 183.7 | 44.2 / 55.3 | 38.3 / 48.7 |
| Dear ImGui | 23.1 / 32.5 | 15.5 / 23.8 | 129.7 / 153.6 | 75.4 / 87.6 | 114.6 / 195.9 | 23.1 / 32.7 |
| egui | 264.2 / 434.9 | 308.6 / 364.0 | 149.2 / 180.3 | 371.9 / 417.6 | 374.1 / 465.7 | 0.0 / 0.0 |
| Iced | 29.9 / 39.6 | 159.6 / 242.9 | 26.9 / 35.7 | 211.9 / 238.5 | 190.2 / 332.2 | 0.0 / 0.0 |
| LVGL | 1.0 / 1.2 | 1119.0 / 1319.4 | 1.5 / 2.7 | 4275.7 / 4547.2 | 2632.9 / 5168.1 | 0.3 / 0.4 |
| Slint | 31.5 / 442.3 | 1791.9 / 1988.8 | 18.6 / 27.0 | 6394.1 / 7085.7 | 2961.1 / 6156.8 | 0.2 / 0.3 |
| Qt Quick | 90.4 / 113.8 | 146.7 / 174.6 | 156.2 / 185.7 | 15760.0 / 25601.8 | 241.5 / 2587.7 | 3.3 / 3.5 |
| Nuklear | 12.5 / 20.3 | 8.2 / 15.1 | 82.9 / 214.8 | 39.3 / 47.8 | 83.7 / 214.9 | 12.4 / 19.8 |
| microui | 13.5 / 21.1 | 5.8 / 7.1 | 30.4 / 38.4 | 20.9 / 28.8 | 30.8 / 50.3 | 13.5 / 21.0 |
| GTK 4 | 67.2 / 93.9 | 12848.3 / 17709.9 | 47.7 / 75.2 | 1756.2 / 3766.2 | 3249.3 / 7541.2 | 2.6 / 2.7 |
| Qt Widgets | 5254.6 / 5619.6 | 704.3 / 791.1 | 1647.2 / 1788.2 | 11939.7 / 14908.6 | 7378.1 / 9878.3 | 1.6 / 1.6 |

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
| Slint | 742 | 3000 | 1 | 3000 | 3000 | 1 |
| Qt Quick | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Nuklear | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| microui | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| GTK 4 | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Qt Widgets | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |

## Resident memory by workload

Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. Linux reports its resident pages after 3,000 polls and the highest resident count since launch. Both columns are medians across runs and include resident shared pages.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 508 / 508 | 492 / 492 | 504 / 504 | 1,496 / 1,496 | 504 / 504 | 508 / 508 |
| Clay | 2,140 / 2,140 | 2,124 / 2,124 | 2,128 / 2,128 | 2,444 / 2,444 | 2,132 / 2,132 | 2,140 / 2,140 |
| Dear ImGui | 3,636 / 3,636 | 3,640 / 3,640 | 3,928 / 3,928 | 3,820 / 3,820 | 4,348 / 4,432 | 3,636 / 3,636 |
| egui | 7,188 / 7,508 | 7,284 / 7,284 | 8,080 / 8,100 | 6,032 / 6,032 | 9,208 / 9,208 | 7,424 / 7,508 |
| Iced | 5,744 / 5,744 | 5,668 / 5,668 | 8,312 / 8,312 | 4,688 / 4,688 | 10,120 / 10,120 | 5,732 / 5,732 |
| LVGL | 3,556 / 3,556 | 3,476 / 3,476 | 3,492 / 3,492 | 3,684 / 3,684 | 3,504 / 3,504 | 3,556 / 3,556 |
| Slint | 13,952 / 13,952 | 15,564 / 15,564 | 15,836 / 15,836 | 13,652 / 13,652 | 20,948 / 20,948 | 13,924 / 13,924 |
| Qt Quick | 68,728 / 68,728 | 67,696 / 67,696 | 70,308 / 70,308 | 939,192 / 939,192 | 77,688 / 93,852 | 66,852 / 66,852 |
| Nuklear | 2,648 / 2,648 | 2,636 / 2,636 | 2,648 / 2,648 | 2,664 / 2,664 | 2,648 / 2,648 | 2,648 / 2,648 |
| microui | 2,656 / 2,656 | 2,656 / 2,656 | 2,656 / 2,656 | 2,660 / 2,660 | 2,656 / 2,656 | 2,656 / 2,656 |
| GTK 4 | 42,828 / 46,292 | 51,608 / 55,392 | 42,724 / 50,468 | 44,596 / 46,848 | 44,860 / 44,860 | 42,772 / 46,320 |
| Qt Widgets | 36,716 / 36,716 | 39,588 / 39,588 | 38,696 / 38,696 | 59,028 / 59,028 | 46,444 / 55,184 | 36,756 / 36,756 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.475 | 400 | 400 | 0.0 | 68,476 | 33,664 | 0 |
| Clay | 0.501 | 424 | 424 | 0.0 | 99,530 | 100,936 | 2,457,760 |
| Dear ImGui | 1.310 | 3548 | 3548 | 0.0 | 757,415 | 61,104 | 3,377,608 |
| egui | 3.700 | 7088 | 7444 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 5.085 | 5712 | 5712 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 4.065 | 3448 | 3448 | 30.0 | 659,329 | 1,021,920 | 2,457,760 |
| Slint | 37.141 | 13928 | 13928 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 95.094 | 66836 | 66836 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.470 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.495 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 101.855 | 42744 | 46320 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 52.880 | 36776 | 36776 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 7.15 / 7.76 | 2.66 / 2.80 | 7.11 / 7.72 |
| Clay | 5.94 / 7.00 | 2.59 / 2.99 | 5.42 / 6.49 |
| Dear ImGui | 7.32 / 7.62 | 2.55 / 3.00 | 6.59 / 6.91 |
| egui | 7.48 / 7.91 | 2.56 / 2.67 | 6.69 / 6.93 |
| Iced | 7.70 / 8.14 | 2.55 / 3.11 | 7.48 / 8.21 |
| LVGL | 6.70 / 7.25 | 2.60 / 3.19 | 6.13 / 6.74 |
| Slint | 10.53 / 11.13 | 2.63 / 2.74 | 10.88 / 12.45 |
| Qt Quick | 15.29 / 15.58 | 7.60 / 7.92 | 24.08 / 26.80 |
| Nuklear | 6.85 / 7.09 | 2.67 / 3.02 | 6.31 / 7.19 |
| microui | 6.80 / 7.24 | 2.66 / 3.02 | 6.21 / 6.78 |
| GTK 4 | 40.49 / 41.23 | 18.66 / 21.27 | 36.08 / 37.21 |
| Qt Widgets | 16.15 / 18.50 | 7.78 / 8.43 | 24.21 / 30.66 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/a60ef64f9df8e909fa66d5c62d5d677cf5d69e61/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/a60ef64f9df8e909fa66d5c62d5d677cf5d69e61/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
