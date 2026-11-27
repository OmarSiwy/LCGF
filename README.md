# GUI framework benchmark results

Measured 2026-11-27 08:15 UTC at [`a4fde7a1f2`](https://github.com/OmarSiwy/LCGF/commit/a4fde7a1f2ea0f244ec60ed8ebb49cb86140761b). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/45958618508)

AMD EPYC 7763 64-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.8.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.3 µs | 1 µs (LVGL) | 0.300 |
| List frame median | 20 µs | 4.9 µs (microui) | 4.082 |
| Text frame median | 0.1 µs | 1.5 µs (LVGL) | 0.067 |
| Springs frame median | 127 µs | 17.4 µs (microui) | 7.293 |
| Resize frame median | 27.9 µs | 24.3 µs (microui) | 1.148 |
| First frame | 0.533 ms | 0.51 ms (Nuklear) | 1.044 |
| Idle resident memory | 468 KiB | 472 KiB (Nuklear) | 0.992 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.3 / 36.2 | 20.0 / 27.7 | 0.1 / 0.1 | 126.9 / 144.1 | 27.9 / 37.2 | 0.3 / 0.3 |
| Clay | 38.5 / 47.9 | 30.8 / 40.2 | 44.2 / 56.3 | 162.3 / 181.6 | 44.3 / 54.1 | 38.4 / 47.2 |
| Dear ImGui | 23.1 / 33.2 | 15.4 / 24.2 | 123.8 / 142.7 | 74.9 / 93.2 | 112.4 / 189.4 | 23.2 / 33.0 |
| egui | 264.0 / 438.3 | 309.8 / 348.8 | 149.0 / 176.7 | 374.7 / 414.9 | 373.4 / 463.7 | 0.0 / 0.0 |
| Iced | 29.9 / 39.9 | 160.8 / 240.4 | 26.8 / 35.4 | 211.9 / 240.7 | 187.8 / 325.1 | 0.0 / 0.0 |
| LVGL | 1.0 / 1.2 | 1127.4 / 1329.1 | 1.5 / 2.8 | 4305.1 / 4584.6 | 2663.6 / 5157.6 | 0.3 / 0.4 |
| Slint | 31.5 / 436.3 | 1790.9 / 1919.5 | 18.7 / 26.8 | 6341.3 / 6983.5 | 2973.3 / 6134.0 | 0.2 / 0.2 |
| Qt Quick | 76.2 / 97.6 | 114.1 / 138.0 | 128.1 / 152.8 | 15817.5 / 27851.8 | 212.9 / 2584.1 | 3.4 / 5.1 |
| Nuklear | 10.2 / 17.6 | 7.5 / 9.7 | 65.7 / 77.1 | 34.9 / 43.7 | 66.9 / 84.2 | 10.1 / 17.3 |
| microui | 10.6 / 18.0 | 4.9 / 5.7 | 23.9 / 31.7 | 17.4 / 25.2 | 24.3 / 36.6 | 10.7 / 18.1 |
| GTK 4 | 46.2 / 73.5 | 4427.0 / 14936.6 | 46.7 / 73.2 | 1746.8 / 3852.3 | 3356.0 / 7854.5 | 2.6 / 2.8 |
| Qt Widgets | 5282.2 / 5970.9 | 701.3 / 789.7 | 1634.1 / 2133.2 | 11896.0 / 16327.7 | 7413.9 / 9556.9 | 1.6 / 1.7 |

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
| Slint | 747 | 3000 | 1 | 3000 | 3000 | 1 |
| Qt Quick | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Nuklear | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| microui | 3000 | 3000 | 3000 | 3000 | 3000 | 3000 |
| GTK 4 | 3000 | 3000 | 3000 | 3000 | 3000 | 2 |
| Qt Widgets | 3000 | 3000 | 3000 | 3000 | 3000 | 1 |

## Resident memory by workload

Each cell shows end-of-scene RSS / peak RSS in KiB. Each run launches a fresh speed-build process. Linux reports its resident pages after 3,000 polls and the highest resident count since launch. Both columns are medians across runs and include resident shared pages.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 576 / 576 | 560 / 560 | 576 / 576 | 1,564 / 1,564 | 576 / 576 | 576 / 576 |
| Clay | 2,192 / 2,192 | 2,176 / 2,176 | 2,180 / 2,180 | 2,496 / 2,496 | 2,184 / 2,184 | 2,192 / 2,192 |
| Dear ImGui | 3,688 / 3,688 | 3,692 / 3,692 | 3,980 / 4,032 | 3,872 / 3,904 | 4,400 / 4,484 | 3,688 / 3,688 |
| egui | 7,240 / 7,508 | 7,332 / 7,332 | 8,128 / 8,128 | 6,080 / 6,080 | 9,256 / 9,256 | 7,476 / 7,508 |
| Iced | 5,792 / 5,792 | 5,716 / 5,716 | 8,360 / 8,360 | 4,736 / 4,736 | 10,168 / 10,168 | 5,780 / 5,780 |
| LVGL | 3,608 / 3,608 | 3,528 / 3,528 | 3,544 / 3,544 | 3,736 / 3,736 | 3,556 / 3,556 | 3,608 / 3,608 |
| Slint | 14,004 / 14,004 | 15,616 / 15,616 | 15,888 / 15,888 | 13,704 / 13,704 | 20,996 / 20,996 | 13,980 / 13,980 |
| Qt Quick | 68,796 / 68,796 | 67,760 / 67,760 | 70,360 / 70,360 | 939,252 / 939,252 | 77,444 / 93,920 | 66,912 / 66,912 |
| Nuklear | 2,744 / 2,744 | 2,732 / 2,732 | 2,744 / 2,744 | 2,764 / 2,764 | 2,744 / 2,744 | 2,744 / 2,744 |
| microui | 2,708 / 2,708 | 2,708 / 2,708 | 2,708 / 2,708 | 2,716 / 2,716 | 2,708 / 2,708 | 2,708 / 2,708 |
| GTK 4 | 42,900 / 46,448 | 51,724 / 55,684 | 42,780 / 50,596 | 44,656 / 46,848 | 44,888 / 44,888 | 42,824 / 46,448 |
| Qt Widgets | 36,760 / 36,760 | 39,624 / 39,624 | 38,740 / 38,740 | 59,076 / 59,076 | 46,516 / 54,448 | 36,796 / 36,796 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.533 | 468 | 468 | 0.0 | 73,495 | 36,840 | 0 |
| Clay | 0.611 | 476 | 476 | 0.0 | 99,530 | 100,936 | 2,457,760 |
| Dear ImGui | 1.398 | 3600 | 3600 | 0.0 | 757,415 | 61,104 | 3,377,608 |
| egui | 3.816 | 7140 | 7444 | 0.0 | 3,939,371 | 400 | 4,231,432 |
| Iced | 5.030 | 5760 | 5760 | 0.0 | 1,626,834 | 264 | 6,055,936 |
| LVGL | 4.246 | 3500 | 3500 | 30.0 | 659,329 | 1,021,920 | 2,457,760 |
| Slint | 36.550 | 13976 | 13976 | 0.0 | 8,016,515 | 2,312 | 6,752,256 |
| Qt Quick | 92.217 | 66896 | 66896 | 0.0 | 54,358 | 32,184 | 151,370,192 |
| Nuklear | 0.510 | 472 | 472 | 0.0 | 224,170 | 51,432 | 4,029,872 |
| microui | 0.548 | 488 | 488 | 0.0 | 29,671 | 303,080 | 4,029,872 |
| GTK 4 | 101.730 | 42772 | 46420 | 2.0 | 22,223 | 40,144 | 79,052,064 |
| Qt Widgets | 50.875 | 36828 | 36828 | 0.0 | 43,519 | 40,064 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 8.19 / 9.23 | 2.71 / 2.93 | 8.26 / 9.49 |
| Clay | 6.92 / 8.32 | 2.54 / 2.96 | 6.50 / 9.64 |
| Dear ImGui | 7.51 / 9.29 | 2.55 / 3.04 | 6.84 / 7.58 |
| egui | 7.37 / 8.56 | 2.60 / 3.04 | 6.84 / 7.55 |
| Iced | 7.47 / 7.86 | 2.56 / 3.06 | 7.09 / 8.32 |
| LVGL | 6.85 / 8.20 | 2.40 / 3.29 | 6.32 / 8.22 |
| Slint | 10.97 / 11.52 | 2.62 / 2.96 | 10.87 / 13.06 |
| Qt Quick | 15.70 / 16.08 | 7.88 / 8.21 | 26.08 / 27.87 |
| Nuklear | 6.60 / 8.26 | 2.41 / 3.01 | 6.22 / 6.76 |
| microui | 6.91 / 8.65 | 2.60 / 2.96 | 6.35 / 10.58 |
| GTK 4 | 40.15 / 41.65 | 18.15 / 21.23 | 34.59 / 38.54 |
| Qt Widgets | 16.38 / 18.04 | 7.59 / 8.09 | 25.65 / 28.73 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/a4fde7a1f2ea0f244ec60ed8ebb49cb86140761b/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/a4fde7a1f2ea0f244ec60ed8ebb49cb86140761b/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
