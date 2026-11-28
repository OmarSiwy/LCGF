# GUI framework benchmark results

Measured 2026-11-28 00:43 UTC at [`d897943760`](https://github.com/OmarSiwy/LCGF/commit/d897943760cb41eb57c99c6ff94ebc8b79327f20). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46085331618)

INTEL(R) XEON(R) PLATINUM 8573C, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.8 to 1.6.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| List frame median | 8.8 µs | 5.8 µs (microui) | 1.517 |
| Text frame median | 0.1 µs | 1.4 µs (LVGL) | 0.071 |
| Springs frame median | 42.3 µs | 20.1 µs (microui) | 2.104 |
| Resize frame median | 10.7 µs | 31.5 µs (microui) | 0.340 |
| First frame | 0.337 ms | 0.329 ms (Nuklear) | 1.023 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 17.7 | 8.8 / 15.3 | 0.1 / 0.1 | 42.3 / 52.4 | 10.7 / 17.3 | 0.1 / 0.1 |
| Clay | 33.6 / 43.0 | 28.1 / 37.9 | 40.9 / 50.6 | 145.5 / 164.5 | 41.0 / 50.6 | 33.0 / 42.8 |
| Dear ImGui | 18.9 / 26.6 | 13.4 / 20.6 | 113.6 / 127.5 | 65.0 / 75.8 | 108.3 / 171.9 | 18.9 / 26.6 |
| egui | 269.8 / 381.3 | 299.6 / 336.1 | 157.6 / 185.2 | 395.3 / 427.7 | 349.2 / 441.7 | 0.0 / 0.0 |
| Iced | 29.4 / 40.2 | 140.2 / 209.3 | 24.8 / 34.7 | 193.7 / 216.4 | 182.7 / 365.8 | 0.0 / 0.0 |
| LVGL | 0.9 / 1.2 | 1047.2 / 1215.4 | 1.4 / 2.5 | 4304.8 / 4549.2 | 2453.3 / 4498.8 | 0.3 / 0.3 |
| Slint | 58.6 / 468.3 | 1981.2 / 2129.0 | 40.1 / 47.5 | 7028.1 / 7353.5 | 2990.0 / 6103.4 | 0.2 / 0.3 |
| Qt Quick | 161.1 / 186.2 | 303.2 / 322.9 | 320.7 / 350.7 | 15738.2 / 20724.4 | 444.3 / 2664.3 | 2.7 / 2.9 |
| Nuklear | 10.4 / 16.6 | 7.2 / 12.4 | 70.1 / 81.5 | 34.4 / 42.5 | 70.8 / 88.3 | 10.2 / 16.6 |
| microui | 12.5 / 19.7 | 5.8 / 6.1 | 30.9 / 38.8 | 20.1 / 26.9 | 31.5 / 49.8 | 12.5 / 19.6 |
| GTK 4 | 36.5 / 64.7 | 3044.7 / 11831.8 | 35.9 / 54.8 | 1641.9 / 3940.2 | 2775.3 / 6986.1 | 1.6 / 1.7 |
| Qt Widgets | 5330.4 / 5816.7 | 797.0 / 866.4 | 1573.4 / 1708.1 | 10380.1 / 12858.8 | 7130.9 / 9058.6 | 1.5 / 1.5 |

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
| Slint | 835 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Dear ImGui | 3,652 / 3,652 | 3,656 / 3,656 | 3,944 / 3,944 | 3,836 / 3,920 | 4,364 / 4,452 | 3,652 / 3,652 |
| egui | 7,252 / 7,572 | 7,348 / 7,348 | 8,144 / 8,164 | 6,096 / 6,096 | 9,272 / 9,272 | 7,488 / 7,572 |
| Iced | 5,804 / 5,804 | 5,732 / 5,732 | 8,376 / 8,376 | 4,752 / 4,752 | 10,180 / 10,180 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,016 / 14,016 | 15,628 / 15,628 | 15,900 / 15,900 | 13,720 / 13,720 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,792 / 68,792 | 67,752 / 67,752 | 70,364 / 70,364 | 939,252 / 939,252 | 77,468 / 93,916 | 66,912 / 66,912 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,924 / 46,340 | 51,816 / 55,712 | 42,692 / 50,364 | 44,660 / 46,912 | 44,868 / 44,868 | 42,836 / 46,356 |
| Qt Widgets | 36,776 / 36,776 | 39,640 / 39,640 | 38,756 / 38,756 | 59,084 / 59,084 | 47,192 / 55,508 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.337 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.354 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 1.201 | 3568 | 3568 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 3.397 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.531 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 3.879 | 3528 | 3528 | 30.0 | 669,317 | 1,020,080 | 2,457,760 |
| Slint | 32.763 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 82.910 | 66900 | 66900 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.329 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.346 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 88.360 | 42808 | 46320 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 44.534 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 11.15 / 12.57 | 3.32 / 3.60 | 10.81 / 11.41 |
| Clay | 7.62 / 9.76 | 2.63 / 2.95 | 8.11 / 13.96 |
| Dear ImGui | 7.46 / 9.66 | 2.57 / 2.78 | 7.12 / 10.12 |
| egui | 8.53 / 9.77 | 2.57 / 3.08 | 7.26 / 10.10 |
| Iced | 9.14 / 10.40 | 2.66 / 2.97 | 8.79 / 12.12 |
| LVGL | 6.82 / 10.13 | 2.57 / 2.96 | 6.75 / 10.90 |
| Slint | 10.82 / 13.14 | 2.63 / 2.99 | 9.73 / 16.31 |
| Qt Quick | 12.34 / 12.96 | 5.69 / 5.95 | 13.09 / 14.22 |
| Nuklear | 7.27 / 9.48 | 2.52 / 2.77 | 6.99 / 11.01 |
| microui | 7.28 / 9.35 | 2.59 / 2.81 | 7.13 / 10.43 |
| GTK 4 | 38.77 / 44.81 | 10.32 / 15.07 | 33.42 / 47.37 |
| Qt Widgets | 13.63 / 14.34 | 5.68 / 5.94 | 13.37 / 14.34 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/d897943760cb41eb57c99c6ff94ebc8b79327f20/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/d897943760cb41eb57c99c6ff94ebc8b79327f20/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
