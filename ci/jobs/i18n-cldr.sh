# all: no
# The hand-written i18n locale tables (src/i18n/) against CLDR 49 JSON (src/i18n/cldr.zig): plural
# rules (every CLDR sample, and the rule text over a grid), number symbols, grouping and digits,
# date patterns and month names, for en, de, fr, ru, pl, ja and ar. Out of `all` because the CLDR
# packages (lazy build.zig.zon dependencies) unpack to about 128 MB in each checkout's zig-pkg/.
zig build i18n-cldr --summary all
