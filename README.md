# GUI framework benchmark results

Measured 2026-11-27 22:32 UTC at [`8a089b59d0`](https://github.com/OmarSiwy/LCGF/commit/8a089b59d06448549b53ddfc08c89500ddc150a2). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46072316409)

AMD EPYC 7763 64-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.3 µs | 1 µs (LVGL) | 0.300 |
| List frame median | 10.4 µs | 4.9 µs (microui) | 2.122 |
| Text frame median | 0.1 µs | 1.5 µs (LVGL) | 0.067 |
| Springs frame median | 38.4 µs | 17.4 µs (microui) | 2.207 |
| Resize frame median | 12.1 µs | 24.2 µs (microui) | 0.500 |
| First frame | 0.521 ms | 0.498 ms (Nuklear) | 1.047 |
| Idle resident memory | 448 KiB | 472 KiB (Nuklear) | 0.949 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.3 / 16.6 | 10.4 / 18.2 | 0.1 / 0.1 | 38.4 / 51.1 | 12.1 / 20.1 | 0.3 / 0.3 |
| Clay | 38.7 / 47.9 | 31.0 / 41.4 | 44.4 / 54.8 | 162.0 / 183.3 | 44.4 / 54.6 | 38.4 / 47.1 |
| Dear ImGui | 22.5 / 31.5 | 15.5 / 23.8 | 125.4 / 144.6 | 74.9 / 88.1 | 117.1 / 196.6 | 22.5 / 31.5 |
| egui | 261.2 / 438.2 | 311.3 / 374.6 | 148.0 / 177.8 | 373.2 / 414.4 | 371.1 / 460.5 | 0.0 / 0.0 |
| Iced | 29.6 / 39.5 | 158.2 / 245.4 | 26.7 / 35.4 | 211.7 / 259.1 | 186.9 / 326.1 | 0.0 / 0.0 |
| LVGL | 1.0 / 1.2 | 1109.8 / 1287.6 | 1.5 / 2.7 | 4408.5 / 4543.8 | 2645.1 / 5146.0 | 0.3 / 0.4 |
| Slint | 31.9 / 432.7 | 1781.1 / 1880.3 | 19.0 / 27.2 | 6328.6 / 7041.4 | 2961.9 / 6088.2 | 0.2 / 0.3 |
| Qt Quick | 76.0 / 102.7 | 114.5 / 138.5 | 128.5 / 151.8 | 16438.0 / 26367.8 | 206.7 / 2410.3 | 3.3 / 3.5 |
| Nuklear | 10.2 / 17.4 | 7.5 / 8.3 | 65.7 / 79.7 | 34.9 / 45.2 | 66.9 / 83.3 | 10.1 / 17.4 |
| microui | 10.6 / 17.9 | 4.9 / 5.0 | 23.9 / 31.6 | 17.4 / 24.8 | 24.2 / 36.5 | 10.7 / 18.0 |
| GTK 4 | 46.3 / 72.1 | 4186.6 / 14629.6 | 65.6 / 93.7 | 1746.8 / 3751.9 | 3256.1 / 7380.5 | 2.6 / 2.8 |
| Qt Widgets | 5299.4 / 5957.3 | 682.7 / 776.6 | 1629.0 / 1792.4 | 11903.7 / 14955.7 | 7451.5 / 9851.8 | 1.6 / 1.7 |

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
| LCGF | 556 / 556 | 540 / 540 | 552 / 552 | 1,544 / 1,544 | 552 / 552 | 556 / 556 |
| Clay | 2,192 / 2,192 | 2,176 / 2,176 | 2,180 / 2,180 | 2,496 / 2,496 | 2,184 / 2,184 | 2,192 / 2,192 |
| Dear ImGui | 3,688 / 3,688 | 3,692 / 3,692 | 3,980 / 4,032 | 3,872 / 3,904 | 4,400 / 4,484 | 3,688 / 3,688 |
| egui | 7,240 / 7,508 | 7,332 / 7,332 | 8,128 / 8,128 | 6,080 / 6,080 | 9,256 / 9,256 | 7,476 / 7,508 |
| Iced | 5,792 / 5,792 | 5,716 / 5,716 | 8,360 / 8,360 | 4,740 / 4,740 | 10,168 / 10,168 | 5,780 / 5,780 |
| LVGL | 3,608 / 3,608 | 3,528 / 3,528 | 3,544 / 3,544 | 3,736 / 3,736 | 3,556 / 3,556 | 3,608 / 3,608 |
| Slint | 14,000 / 14,000 | 15,616 / 15,616 | 15,888 / 15,888 | 13,704 / 13,704 | 20,996 / 20,996 | 13,980 / 13,980 |
| Qt Quick | 68,796 / 68,796 | 67,752 / 67,752 | 70,364 / 70,364 | 939,244 / 939,244 | 77,068 / 93,924 | 66,916 / 66,916 |
| Nuklear | 2,744 / 2,744 | 2,732 / 2,732 | 2,744 / 2,744 | 2,764 / 2,764 | 2,744 / 2,744 | 2,744 / 2,744 |
| microui | 2,708 / 2,708 | 2,708 / 2,708 | 2,708 / 2,708 | 2,716 / 2,716 | 2,708 / 2,708 | 2,708 / 2,708 |
| GTK 4 | 42,904 / 46,448 | 51,660 / 55,444 | 42,716 / 50,596 | 44,648 / 46,848 | 44,856 / 44,856 | 42,796 / 46,420 |
| Qt Widgets | 36,756 / 36,756 | 39,624 / 39,624 | 38,736 / 38,736 | 59,072 / 59,072 | 46,708 / 55,328 | 36,796 / 36,796 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.521 | 448 | 448 | 0.0 | 68,407 | 33,736 | 0 |
| Clay | 0.538 | 476 | 476 | 0.0 | 99,530 | 100,936 | 2,457,760 |
| Dear ImGui | 1.334 | 3600 | 3600 | 0.0 | 757,415 | 61,104 | 3,377,608 |
| egui | 3.913 | 7140 | 7444 | 0.0 | 3,939,371 | 400 | 4,231,432 |
| Iced | 4.974 | 5760 | 5760 | 0.0 | 1,626,834 | 264 | 6,055,936 |
| LVGL | 4.163 | 3500 | 3500 | 30.0 | 659,329 | 1,021,920 | 2,457,760 |
| Slint | 37.091 | 13980 | 13980 | 0.0 | 8,016,515 | 2,312 | 6,752,256 |
| Qt Quick | 132.617 | 66896 | 66896 | 0.0 | 54,358 | 32,184 | 151,370,192 |
| Nuklear | 0.498 | 472 | 472 | 0.0 | 224,170 | 51,432 | 4,029,872 |
| microui | 0.528 | 488 | 488 | 0.0 | 29,671 | 303,080 | 4,029,872 |
| GTK 4 | 102.339 | 42796 | 46448 | 2.0 | 22,223 | 40,144 | 79,052,064 |
| Qt Widgets | 52.969 | 36828 | 36828 | 0.0 | 43,519 | 40,064 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 7.69 / 8.23 | 2.77 / 2.97 | 6.99 / 7.59 |
| Clay | 6.40 / 7.28 | 2.29 / 2.94 | 5.55 / 6.39 |
| Dear ImGui | 7.07 / 7.69 | 2.48 / 2.68 | 5.77 / 7.23 |
| egui | 7.26 / 7.78 | 2.53 / 2.84 | 5.67 / 7.34 |
| Iced | 7.42 / 7.90 | 2.42 / 3.22 | 6.41 / 7.51 |
| LVGL | 6.55 / 7.28 | 2.36 / 3.04 | 5.59 / 6.79 |
| Slint | 10.63 / 11.59 | 2.60 / 2.82 | 11.09 / 14.08 |
| Qt Quick | 15.03 / 15.38 | 7.53 / 7.98 | 22.85 / 24.82 |
| Nuklear | 5.93 / 6.73 | 2.27 / 2.67 | 5.25 / 6.12 |
| microui | 6.18 / 7.64 | 2.44 / 2.94 | 5.49 / 7.31 |
| GTK 4 | 39.69 / 40.82 | 17.79 / 20.97 | 33.90 / 36.91 |
| Qt Widgets | 15.70 / 16.83 | 7.70 / 8.05 | 23.14 / 26.92 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/8a089b59d06448549b53ddfc08c89500ddc150a2/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/8a089b59d06448549b53ddfc08c89500ddc150a2/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
