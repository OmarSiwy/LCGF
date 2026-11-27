# GUI framework benchmark results

Measured 2026-11-27 23:00 UTC at [`e97e7648f2`](https://github.com/OmarSiwy/LCGF/commit/e97e7648f2735e3e336254faa7bbf50b13d44169). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46074702802)

AMD EPYC 7763 64-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.3 µs | 1 µs (LVGL) | 0.300 |
| List frame median | 10.5 µs | 5.8 µs (microui) | 1.810 |
| Text frame median | 0.1 µs | 1.5 µs (LVGL) | 0.067 |
| Springs frame median | 38.7 µs | 20.9 µs (microui) | 1.852 |
| Resize frame median | 12.1 µs | 30.8 µs (microui) | 0.393 |
| First frame | 0.492 ms | 0.456 ms (Nuklear) | 1.078 |
| Idle resident memory | 400 KiB | 416 KiB (Nuklear) | 0.962 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.3 / 16.4 | 10.5 / 18.6 | 0.1 / 0.1 | 38.7 / 50.3 | 12.1 / 20.4 | 0.3 / 0.3 |
| Clay | 38.8 / 47.8 | 30.9 / 40.6 | 44.2 / 54.2 | 163.1 / 187.0 | 44.2 / 53.4 | 38.4 / 47.1 |
| Dear ImGui | 23.0 / 32.4 | 15.4 / 23.6 | 125.7 / 141.4 | 75.3 / 87.4 | 116.2 / 196.5 | 23.1 / 32.6 |
| egui | 260.7 / 435.0 | 309.5 / 360.8 | 149.0 / 174.7 | 371.2 / 416.3 | 374.0 / 464.8 | 0.0 / 0.0 |
| Iced | 30.2 / 40.1 | 157.4 / 239.6 | 26.9 / 36.3 | 212.3 / 375.8 | 187.1 / 322.3 | 0.0 / 0.0 |
| LVGL | 1.0 / 1.2 | 1124.3 / 1310.2 | 1.5 / 2.7 | 4249.6 / 4517.7 | 2628.3 / 5124.6 | 0.3 / 0.4 |
| Slint | 31.5 / 430.9 | 1757.8 / 1863.1 | 18.8 / 27.1 | 6436.8 / 6911.7 | 2938.3 / 6038.1 | 0.2 / 0.3 |
| Qt Quick | 88.9 / 109.2 | 142.4 / 169.9 | 153.7 / 183.6 | 15101.9 / 26062.9 | 235.4 / 2449.6 | 3.4 / 3.6 |
| Nuklear | 12.5 / 20.2 | 8.2 / 9.0 | 82.9 / 209.5 | 39.3 / 47.0 | 83.7 / 204.7 | 12.4 / 20.5 |
| microui | 13.5 / 21.4 | 5.8 / 6.0 | 30.3 / 38.4 | 20.9 / 28.6 | 30.8 / 50.1 | 13.5 / 21.2 |
| GTK 4 | 47.2 / 88.0 | 4228.1 / 14500.3 | 46.8 / 84.3 | 1746.5 / 3808.5 | 3245.7 / 7440.8 | 2.6 / 2.7 |
| Qt Widgets | 5248.7 / 5571.4 | 698.6 / 768.4 | 1636.9 / 1764.6 | 11471.2 / 15680.3 | 7343.1 / 9579.5 | 1.6 / 1.7 |

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
| Slint | 748 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Slint | 13,956 / 13,956 | 15,564 / 15,564 | 15,840 / 15,840 | 13,656 / 13,656 | 20,948 / 20,948 | 13,928 / 13,928 |
| Qt Quick | 68,724 / 68,724 | 67,696 / 67,696 | 70,308 / 70,308 | 939,188 / 939,188 | 77,624 / 93,856 | 66,852 / 66,852 |
| Nuklear | 2,648 / 2,648 | 2,636 / 2,636 | 2,648 / 2,648 | 2,664 / 2,664 | 2,648 / 2,648 | 2,648 / 2,648 |
| microui | 2,656 / 2,656 | 2,656 / 2,656 | 2,656 / 2,656 | 2,660 / 2,660 | 2,656 / 2,656 | 2,656 / 2,656 |
| GTK 4 | 42,848 / 46,320 | 51,608 / 55,392 | 42,728 / 50,468 | 44,600 / 46,784 | 44,904 / 44,904 | 42,772 / 46,320 |
| Qt Widgets | 36,720 / 36,720 | 39,584 / 39,584 | 38,696 / 38,696 | 59,028 / 59,028 | 46,736 / 55,480 | 36,756 / 36,756 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.492 | 400 | 400 | 0.0 | 68,407 | 33,736 | 0 |
| Clay | 0.483 | 424 | 424 | 0.0 | 99,530 | 100,936 | 2,457,760 |
| Dear ImGui | 1.328 | 3548 | 3548 | 0.0 | 757,415 | 61,104 | 3,377,608 |
| egui | 3.709 | 7088 | 7444 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 4.977 | 5712 | 5712 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 4.055 | 3448 | 3448 | 30.0 | 659,329 | 1,021,920 | 2,457,760 |
| Slint | 37.859 | 13932 | 13932 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 93.544 | 66840 | 66840 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.456 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.487 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 102.443 | 42716 | 46292 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 53.423 | 36776 | 36776 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 7.57 / 8.31 | 2.51 / 2.63 | 7.36 / 8.54 |
| Clay | 5.67 / 6.61 | 2.15 / 2.54 | 5.12 / 5.84 |
| Dear ImGui | 6.75 / 7.10 | 2.34 / 2.49 | 5.92 / 6.75 |
| egui | 6.80 / 7.34 | 2.31 / 2.44 | 6.01 / 6.22 |
| Iced | 7.15 / 7.49 | 2.26 / 2.85 | 6.35 / 6.77 |
| LVGL | 6.38 / 6.74 | 2.27 / 2.71 | 5.73 / 6.22 |
| Slint | 10.26 / 10.41 | 2.42 / 2.57 | 9.42 / 11.12 |
| Qt Quick | 14.32 / 15.01 | 7.28 / 7.53 | 21.03 / 23.27 |
| Nuklear | 6.26 / 6.56 | 2.21 / 2.82 | 5.67 / 6.11 |
| microui | 6.22 / 6.52 | 2.25 / 2.70 | 5.59 / 5.96 |
| GTK 4 | 39.14 / 40.20 | 10.77 / 21.39 | 33.73 / 38.23 |
| Qt Widgets | 15.01 / 15.56 | 7.37 / 7.62 | 21.08 / 21.82 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/e97e7648f2735e3e336254faa7bbf50b13d44169/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/e97e7648f2735e3e336254faa7bbf50b13d44169/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
