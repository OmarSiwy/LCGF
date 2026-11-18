# GUI framework benchmark results

Measured 2026-11-18 02:21 UTC at [`ed94db3da2`](https://github.com/OmarSiwy/LCGF/commit/ed94db3da27882ef1c87d0dd15a382b4df39e2c2). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/44217355543)

Intel(R) Xeon(R) Platinum 8370C CPU @ 2.80GHz, Linux 7.0.0-1019-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.7 to 1.7.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| List frame median | 19.7 µs | 6.1 µs (microui) | 3.230 |
| Text frame median | 0.1 µs | 1.3 µs (LVGL) | 0.077 |
| Springs frame median | 92.1 µs | 22.4 µs (microui) | 4.112 |
| Resize frame median | 27.9 µs | 33.9 µs (microui) | 0.823 |
| First frame | 0.382 ms | 0.339 ms (Nuklear) | 1.125 |
| Idle resident memory | 400 KiB | 416 KiB (Nuklear) | 0.962 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 35.1 | 19.7 / 26.7 | 0.1 / 0.1 | 92.1 / 107.6 | 27.9 / 35.3 | 0.1 / 0.1 |
| Clay | 34.8 / 71.9 | 29.4 / 37.2 | 43.0 / 50.9 | 173.9 / 294.3 | 43.0 / 51.6 | 34.4 / 42.6 |
| Dear ImGui | 22.0 / 29.3 | 15.8 / 21.4 | 114.4 / 130.4 | 93.7 / 106.7 | 109.6 / 176.3 | 22.2 / 29.9 |
| egui | 278.3 / 400.9 | 315.8 / 344.3 | 161.2 / 181.4 | 413.5 / 442.2 | 370.4 / 459.7 | 0.0 / 0.0 |
| Iced | 29.4 / 37.8 | 148.3 / 224.5 | 24.9 / 31.6 | 202.5 / 216.2 | 200.1 / 351.7 | 0.0 / 0.0 |
| LVGL | 0.9 / 1.6 | 1024.3 / 1184.7 | 1.3 / 2.5 | 4157.8 / 4504.0 | 2692.6 / 4969.8 | 0.3 / 0.8 |
| Slint | 55.0 / 461.0 | 1898.5 / 2028.4 | 36.6 / 43.1 | 6653.8 / 7021.4 | 2873.8 / 5863.9 | 0.2 / 0.3 |
| Qt Quick | 148.6 / 165.0 | 269.0 / 290.9 | 278.7 / 299.5 | 15835.3 / 20556.5 | 433.3 / 2544.7 | 2.7 / 2.8 |
| Nuklear | 12.7 / 19.1 | 9.0 / 14.0 | 76.4 / 85.2 | 32.9 / 40.2 | 77.3 / 93.8 | 12.5 / 18.6 |
| microui | 14.8 / 20.7 | 6.1 / 10.9 | 33.4 / 39.7 | 22.4 / 28.3 | 33.9 / 52.4 | 14.8 / 20.8 |
| GTK 4 | 40.6 / 63.5 | 3888.3 / 13692.1 | 39.8 / 60.9 | 1838.5 / 4653.2 | 3041.9 / 7477.9 | 1.5 / 1.6 |
| Qt Widgets | 2584.1 / 2790.9 | 1040.6 / 1105.1 | 2571.8 / 2818.5 | 12532.6 / 15669.1 | 7886.7 / 11102.7 | 1.2 / 1.3 |

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
| Slint | 832 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Dear ImGui | 3,644 / 3,644 | 3,648 / 3,648 | 3,936 / 3,936 | 3,828 / 3,912 | 4,356 / 4,444 | 3,644 / 3,644 |
| egui | 7,252 / 7,572 | 7,348 / 7,348 | 8,144 / 8,164 | 6,096 / 6,096 | 9,272 / 9,272 | 7,488 / 7,572 |
| Iced | 5,808 / 5,808 | 5,728 / 5,728 | 8,376 / 8,376 | 4,752 / 4,752 | 10,160 / 10,160 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,024 / 14,024 | 15,628 / 15,628 | 15,904 / 15,904 | 13,720 / 13,720 | 21,012 / 21,012 | 13,996 / 13,996 |
| Qt Quick | 68,796 / 68,796 | 67,756 / 67,756 | 70,368 / 70,368 | 939,252 / 939,252 | 76,524 / 96,144 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,928 / 46,356 | 51,776 / 55,708 | 42,736 / 50,412 | 44,660 / 46,848 | 44,860 / 44,860 | 42,832 / 46,344 |
| Qt Widgets | 36,776 / 36,776 | 39,640 / 39,640 | 38,756 / 38,756 | 59,084 / 59,084 | 46,800 / 55,084 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.382 | 400 | 400 | 0.0 | 65,258 | 32,792 | 0 |
| Clay | 0.365 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.131 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 3.080 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.436 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.799 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 31.000 | 13996 | 13996 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 83.204 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.339 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.372 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 89.300 | 42808 | 46384 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 41.414 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 13.57 / 16.39 | 3.90 / 4.31 | 17.12 / 19.99 |
| Clay | 10.38 / 11.56 | 3.31 / 4.14 | 11.27 / 13.37 |
| Dear ImGui | 10.38 / 11.46 | 3.28 / 3.62 | 10.34 / 12.73 |
| egui | 10.89 / 11.59 | 3.32 / 3.64 | 10.86 / 12.36 |
| Iced | 11.40 / 13.23 | 3.36 / 3.66 | 12.01 / 13.88 |
| LVGL | 10.59 / 11.77 | 3.34 / 5.27 | 11.52 / 14.40 |
| Slint | 14.03 / 14.76 | 3.42 / 3.92 | 15.08 / 19.04 |
| Qt Quick | 13.13 / 14.60 | 6.07 / 7.27 | 14.25 / 15.58 |
| Nuklear | 10.09 / 10.92 | 3.14 / 3.50 | 10.18 / 14.74 |
| microui | 10.43 / 11.31 | 3.22 / 3.48 | 11.10 / 14.93 |
| GTK 4 | 39.78 / 43.29 | 10.31 / 12.46 | 39.08 / 43.90 |
| Qt Widgets | 14.75 / 15.42 | 6.16 / 6.44 | 14.88 / 16.42 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
