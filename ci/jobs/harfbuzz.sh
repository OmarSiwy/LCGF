# all: no
# The optional HarfBuzz shaping adapter (src/text/shape/harfbuzz.zig): shapes a Devanagari
# sample through HarfBuzz built from source (lazy build.zig.zon dependency) and renders it with src/text/raster/.
zig build harfbuzz
