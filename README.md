# GUI framework benchmark results

Measured 2026-11-27 22:01 UTC at [`596c14b948`](https://github.com/OmarSiwy/LCGF/commit/596c14b948ab4a9aefc3884fdeda2387c940f814). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46069206387)

AMD EPYC 9V74 80-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.6 to 1.5.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.3 µs | 1 µs (LVGL) | 0.300 |
| List frame median | 10.3 µs | 4.9 µs (microui) | 2.102 |
| Text frame median | 0.1 µs | 1.5 µs (LVGL) | 0.067 |
| Springs frame median | 38.1 µs | 19.4 µs (microui) | 1.964 |
| Resize frame median | 12 µs | 24.5 µs (microui) | 0.490 |
| First frame | 0.56 ms | 0.526 ms (Nuklear) | 1.065 |
| Idle resident memory | 448 KiB | 472 KiB (Nuklear) | 0.949 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.3 / 16.1 | 10.3 / 18.6 | 0.1 / 0.1 | 38.1 / 50.5 | 12.0 / 20.6 | 0.3 / 0.3 |
| Clay | 41.7 / 52.2 | 33.4 / 43.5 | 47.1 / 58.4 | 159.4 / 178.3 | 47.0 / 58.8 | 41.4 / 52.5 |
| Dear ImGui | 21.4 / 30.6 | 16.5 / 25.4 | 115.0 / 133.5 | 87.0 / 101.6 | 109.0 / 177.7 | 21.3 / 30.9 |
| egui | 257.7 / 453.9 | 310.9 / 347.3 | 148.1 / 172.7 | 371.0 / 401.9 | 363.3 / 481.6 | 0.0 / 0.0 |
| Iced | 29.1 / 39.9 | 159.8 / 238.7 | 28.0 / 38.1 | 213.6 / 242.5 | 187.8 / 339.2 | 0.0 / 0.0 |
| LVGL | 1.0 / 1.3 | 1094.6 / 1268.4 | 1.5 / 2.7 | 4427.9 / 4564.8 | 2533.6 / 5156.3 | 0.4 / 0.4 |
| Slint | 32.4 / 443.6 | 1854.2 / 1928.8 | 19.5 / 28.4 | 7206.6 / 7435.8 | 3164.9 / 6517.5 | 0.2 / 0.3 |
| Qt Quick | 76.9 / 95.7 | 115.1 / 134.4 | 127.2 / 151.9 | 16158.4 / 22096.5 | 206.5 / 2639.9 | 3.5 / 3.8 |
| Nuklear | 9.7 / 17.9 | 7.6 / 11.3 | 66.8 / 79.1 | 39.6 / 49.3 | 68.4 / 86.0 | 9.6 / 17.9 |
| microui | 10.3 / 18.7 | 4.9 / 6.7 | 24.0 / 33.8 | 19.4 / 28.1 | 24.5 / 36.8 | 10.3 / 18.8 |
| GTK 4 | 41.3 / 62.1 | 3715.0 / 13439.3 | 41.1 / 60.7 | 1667.2 / 3468.1 | 2971.1 / 6939.6 | 3.3 / 3.7 |
| Qt Widgets | 2351.7 / 2539.8 | 603.2 / 668.4 | 1456.1 / 1562.3 | 10797.5 / 13345.5 | 6840.7 / 8828.4 | 1.8 / 2.2 |

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
| LCGF | 556 / 556 | 540 / 540 | 552 / 552 | 1,544 / 1,544 | 552 / 552 | 556 / 556 |
| Clay | 2,192 / 2,192 | 2,176 / 2,176 | 2,180 / 2,180 | 2,496 / 2,496 | 2,184 / 2,184 | 2,192 / 2,192 |
| Dear ImGui | 3,688 / 3,688 | 3,692 / 3,692 | 3,980 / 4,032 | 3,872 / 3,904 | 4,400 / 4,484 | 3,688 / 3,688 |
| egui | 7,240 / 7,508 | 7,332 / 7,332 | 8,128 / 8,128 | 6,080 / 6,080 | 9,256 / 9,256 | 7,476 / 7,508 |
| Iced | 5,792 / 5,792 | 5,716 / 5,716 | 8,352 / 8,352 | 4,736 / 4,736 | 10,168 / 10,168 | 5,780 / 5,780 |
| LVGL | 3,608 / 3,608 | 3,528 / 3,528 | 3,544 / 3,544 | 3,736 / 3,736 | 3,556 / 3,556 | 3,608 / 3,608 |
| Slint | 14,004 / 14,004 | 15,612 / 15,612 | 15,884 / 15,884 | 13,704 / 13,704 | 20,996 / 20,996 | 13,980 / 13,980 |
| Qt Quick | 68,792 / 68,792 | 67,752 / 67,752 | 70,368 / 70,368 | 939,248 / 939,248 | 76,396 / 93,908 | 66,912 / 66,912 |
| Nuklear | 2,744 / 2,744 | 2,732 / 2,732 | 2,744 / 2,744 | 2,764 / 2,764 | 2,744 / 2,744 | 2,744 / 2,744 |
| microui | 2,708 / 2,708 | 2,708 / 2,708 | 2,708 / 2,708 | 2,716 / 2,716 | 2,708 / 2,708 | 2,708 / 2,708 |
| GTK 4 | 42,908 / 46,428 | 51,728 / 55,688 | 42,780 / 50,596 | 44,644 / 46,848 | 44,912 / 44,912 | 42,824 / 46,448 |
| Qt Widgets | 36,764 / 36,764 | 39,624 / 39,624 | 38,736 / 38,736 | 59,076 / 59,076 | 47,188 / 53,952 | 36,796 / 36,796 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.560 | 448 | 448 | 0.0 | 68,407 | 33,736 | 0 |
| Clay | 0.572 | 476 | 476 | 0.0 | 99,530 | 100,936 | 2,457,760 |
| Dear ImGui | 1.508 | 3600 | 3600 | 0.0 | 757,415 | 61,104 | 3,377,608 |
| egui | 3.847 | 7140 | 7444 | 0.0 | 3,939,371 | 400 | 4,231,432 |
| Iced | 5.546 | 5760 | 5760 | 0.0 | 1,626,834 | 264 | 6,055,936 |
| LVGL | 4.141 | 3500 | 3500 | 30.0 | 659,329 | 1,021,920 | 2,457,760 |
| Slint | 37.163 | 13976 | 13976 | 0.0 | 8,016,515 | 2,312 | 6,752,256 |
| Qt Quick | 96.783 | 66896 | 66896 | 0.0 | 54,358 | 32,184 | 151,370,192 |
| Nuklear | 0.526 | 472 | 472 | 0.0 | 224,170 | 51,432 | 4,029,872 |
| microui | 0.558 | 488 | 488 | 0.0 | 29,671 | 303,080 | 4,029,872 |
| GTK 4 | 103.944 | 42796 | 46448 | 2.0 | 22,223 | 40,144 | 79,052,064 |
| Qt Widgets | 49.986 | 36824 | 36824 | 0.0 | 43,519 | 40,064 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 7.22 / 9.40 | 2.77 / 2.90 | 6.59 / 7.17 |
| Clay | 6.43 / 6.76 | 2.38 / 2.79 | 5.33 / 6.36 |
| Dear ImGui | 7.27 / 7.86 | 2.46 / 2.75 | 5.73 / 6.21 |
| egui | 6.88 / 7.80 | 2.39 / 3.16 | 5.78 / 6.04 |
| Iced | 6.87 / 7.24 | 2.43 / 2.99 | 5.87 / 6.03 |
| LVGL | 6.52 / 6.85 | 2.43 / 2.78 | 5.32 / 5.60 |
| Slint | 10.14 / 10.80 | 2.58 / 2.76 | 9.70 / 13.31 |
| Qt Quick | 15.16 / 15.55 | 7.60 / 7.83 | 23.39 / 24.01 |
| Nuklear | 6.44 / 6.60 | 2.48 / 2.87 | 5.26 / 5.62 |
| microui | 6.54 / 6.74 | 2.51 / 2.88 | 5.26 / 5.62 |
| GTK 4 | 39.37 / 39.87 | 19.51 / 20.49 | 33.32 / 34.48 |
| Qt Widgets | 15.58 / 16.03 | 7.80 / 8.01 | 21.93 / 22.50 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/596c14b948ab4a9aefc3884fdeda2387c940f814/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/596c14b948ab4a9aefc3884fdeda2387c940f814/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
