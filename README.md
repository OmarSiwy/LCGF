# GUI framework benchmark results

Measured 2026-11-28 00:23 UTC at [`2359efaff6`](https://github.com/OmarSiwy/LCGF/commit/2359efaff679c4e206ca77d1e63c521bf976a580). [CI run](https://github.com/OmarSiwy/LCGF/actions/runs/46085177063)

AMD EPYC 9V45 96-Core Processor, Linux 7.0.0-1020-azure x86_64. Frame harnesses used CPU 2. Start/end load readings ranged from 0.6 to 1.9.

## LCGF against the lowest other measurement

The ratio divides LCGF's measured value by the lowest other value in the same run. Values below 1 favor LCGF. Ties share the comparison column.

| Measurement | LCGF | Lowest other | Ratio |
|---|---|---|---|
| Form frame median | 0.1 µs | 0.6 µs (LVGL) | 0.167 |
| List frame median | 5.9 µs | 3.4 µs (microui) | 1.735 |
| Text frame median | 0.1 µs | 0.9 µs (LVGL) | 0.111 |
| Springs frame median | 22.4 µs | 11.3 µs (microui) | 1.982 |
| Resize frame median | 6.5 µs | 16.8 µs (microui) | 0.387 |
| First frame | 0.314 ms | 0.304 ms (Nuklear) | 1.031 |
| Idle resident memory | 404 KiB | 416 KiB (Nuklear) | 0.971 |

## Frame time

Each harness ran 3,000 polls per scene in each of 5 runs. Each cell shows the median of the run medians and the median of the run p99s, in microseconds per poll. The cost can include command generation, tessellation or software rasterization depending on the toolkit. Idle polling and idle process wake-ups are separate measurements.

| Framework | Form | List | Text | Springs | Resize | Idle |
|---|---|---|---|---|---|---|
| LCGF | 0.1 / 9.0 | 5.9 / 6.8 | 0.1 / 0.1 | 22.4 / 29.4 | 6.5 / 7.9 | 0.1 / 0.1 |
| Clay | 22.3 / 28.2 | 18.1 / 23.8 | 27.8 / 34.3 | 86.9 / 97.3 | 27.1 / 33.6 | 22.2 / 27.9 |
| Dear ImGui | 12.1 / 17.7 | 8.4 / 11.1 | 62.1 / 71.5 | 43.4 / 52.0 | 62.8 / 99.0 | 12.1 / 17.6 |
| egui | 160.4 / 278.1 | 185.0 / 203.3 | 97.8 / 110.4 | 241.2 / 255.7 | 215.1 / 253.5 | 0.0 / 0.0 |
| Iced | 18.6 / 24.4 | 87.6 / 132.4 | 15.8 / 21.4 | 118.3 / 130.4 | 105.6 / 181.8 | 0.0 / 0.0 |
| LVGL | 0.6 / 1.0 | 609.8 / 720.5 | 0.9 / 1.6 | 2366.1 / 2520.6 | 1411.0 / 2930.2 | 0.2 / 0.2 |
| Slint | 36.2 / 269.0 | 1096.9 / 1146.6 | 25.0 / 30.5 | 3570.1 / 3805.9 | 1781.5 / 3521.3 | 0.2 / 0.2 |
| Qt Quick | 47.9 / 55.8 | 62.3 / 80.7 | 69.8 / 88.9 | 8982.8 / 14208.6 | 106.5 / 1903.1 | 2.1 / 2.2 |
| Nuklear | 6.7 / 9.3 | 4.7 / 5.0 | 45.1 / 53.5 | 20.9 / 26.4 | 45.3 / 59.2 | 6.5 / 8.0 |
| microui | 6.9 / 8.7 | 3.4 / 3.6 | 16.0 / 21.6 | 11.3 / 17.2 | 16.8 / 26.5 | 7.0 / 8.3 |
| GTK 4 | 28.7 / 41.0 | 1822.0 / 8444.7 | 25.7 / 35.4 | 908.0 / 1823.0 | 1645.5 / 3857.2 | 1.8 / 1.8 |
| Qt Widgets | 1251.2 / 1324.3 | 460.3 / 501.4 | 1395.0 / 1478.7 | 6250.6 / 7618.1 | 4281.0 / 6032.7 | 1.2 / 1.2 |

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
| Slint | 700 | 3000 | 1 | 3000 | 3000 | 1 |
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
| Iced | 5,804 / 5,804 | 5,728 / 5,728 | 8,380 / 8,380 | 4,752 / 4,752 | 10,184 / 10,184 | 5,796 / 5,796 |
| LVGL | 3,636 / 3,636 | 3,620 / 3,620 | 3,636 / 3,636 | 3,828 / 3,828 | 3,648 / 3,648 | 3,636 / 3,636 |
| Slint | 14,012 / 14,012 | 15,628 / 15,628 | 15,900 / 15,900 | 13,716 / 13,716 | 21,012 / 21,012 | 13,992 / 13,992 |
| Qt Quick | 68,800 / 68,800 | 67,752 / 67,752 | 70,376 / 70,376 | 939,252 / 939,252 | 77,452 / 93,916 | 66,916 / 66,916 |
| Nuklear | 2,712 / 2,712 | 2,700 / 2,700 | 2,712 / 2,712 | 2,728 / 2,728 | 2,712 / 2,712 | 2,712 / 2,712 |
| microui | 2,720 / 2,720 | 2,720 / 2,720 | 2,720 / 2,720 | 2,724 / 2,724 | 2,720 / 2,720 | 2,720 / 2,720 |
| GTK 4 | 42,912 / 46,300 | 51,956 / 55,888 | 42,852 / 50,416 | 44,624 / 46,848 | 44,852 / 44,852 | 42,808 / 46,356 |
| Qt Widgets | 36,776 / 36,776 | 39,640 / 39,640 | 38,752 / 38,752 | 59,084 / 59,084 | 47,920 / 54,496 | 36,812 / 36,812 |

## Startup and footprint

Startup is the median of 11 launches to the first completed frame. Idle RSS and the peak observed through the first idle frame include touched shared pages. Executable bytes sum text, read-only data and initialized data in the size build. Mapped libraries are the on-disk sizes of shared objects mapped by the speed build at idle. Clay, Nuklear and microui use static musl builds for startup, idle RSS and idle wake-ups. BSS is zero-initialized address space.

| Framework | Startup ms | Idle RSS KiB | Peak RSS KiB | Wake-ups/s | Executable bytes | BSS bytes | Mapped library bytes |
|---|---|---|---|---|---|---|---|
| LCGF | 0.314 | 404 | 404 | 0.0 | 69,143 | 33,000 | 0 |
| Clay | 0.316 | 424 | 424 | 0.0 | 99,576 | 100,864 | 2,457,760 |
| Dear ImGui | 0.922 | 3560 | 3560 | 0.0 | 763,991 | 58,656 | 3,377,608 |
| egui | 2.397 | 7152 | 7508 | 0.0 | 3,939,941 | 400 | 4,231,432 |
| Iced | 3.588 | 5776 | 5776 | 0.0 | 1,627,364 | 264 | 6,055,936 |
| LVGL | 2.431 | 3528 | 3528 | 30.0 | 669,321 | 1,020,080 | 2,457,760 |
| Slint | 22.280 | 13992 | 13992 | 0.0 | 8,017,341 | 2,312 | 6,752,256 |
| Qt Quick | 57.917 | 66896 | 66896 | 0.0 | 47,927 | 32,240 | 151,370,192 |
| Nuklear | 0.304 | 416 | 416 | 0.0 | 202,313 | 51,496 | 4,029,872 |
| microui | 0.329 | 436 | 436 | 0.0 | 27,498 | 303,128 | 4,029,872 |
| GTK 4 | 63.988 | 42776 | 46356 | 2.0 | 22,279 | 40,184 | 79,052,064 |
| Qt Widgets | 28.909 | 36832 | 36832 | 0.0 | 43,680 | 40,128 | 110,470,864 |

## Window resize to verified pixels

Median / p95 milliseconds across 25 samples per resize type. An independent X11 observer verifies every pixel of the resized window on the X server.

| Framework | Grow | Shrink | Drag and settle |
|---|---|---|---|
| LCGF | 5.47 / 6.37 | 1.69 / 1.82 | 5.17 / 6.16 |
| Clay | 4.67 / 5.04 | 1.52 / 1.81 | 4.30 / 4.64 |
| Dear ImGui | 4.64 / 5.66 | 1.56 / 1.88 | 3.54 / 4.64 |
| egui | 5.12 / 5.64 | 1.58 / 1.91 | 4.43 / 4.97 |
| Iced | 4.17 / 5.23 | 1.55 / 1.69 | 3.84 / 4.95 |
| LVGL | 3.78 / 5.02 | 1.57 / 2.12 | 3.56 / 4.41 |
| Slint | 5.68 / 6.68 | 1.54 / 1.92 | 5.32 / 6.51 |
| Qt Quick | 10.86 / 11.18 | 6.03 / 6.13 | 13.39 / 14.08 |
| Nuklear | 4.62 / 5.00 | 1.50 / 1.83 | 4.28 / 4.36 |
| microui | 4.60 / 5.20 | 1.57 / 1.85 | 3.76 / 4.39 |
| GTK 4 | 33.58 / 34.33 | 16.68 / 17.75 | 23.74 / 25.26 |
| Qt Widgets | 11.44 / 11.71 | 6.03 / 6.17 | 13.53 / 13.75 |

[Workloads and adapter boundaries](https://github.com/OmarSiwy/LCGF/blob/2359efaff679c4e206ca77d1e63c521bf976a580/docs/perf/vs.md) · [Release thresholds](https://github.com/OmarSiwy/LCGF/blob/2359efaff679c4e206ca77d1e63c521bf976a580/bench/gates/README.md)

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The raw file includes the frame counts, load readings and individual verified window-resize samples.
[Raw measurements and runner metadata](measurements.json)
