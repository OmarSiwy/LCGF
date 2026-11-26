"""Reads a dump (bindings/check/dump.zig's format) and fails unless every widget slot that the
UI has got at least one event: the replay exercised input, not just drawing. Prints the frames
with focus set, with a spring moving and with custom draws, for the record."""
import struct, sys

QUAD, RUN, CUSTOM = 136, 52, 48
data = open(sys.argv[1], "rb").read()
i, frames, events, focused, moving, customs = 0, 0, {}, 0, 0, 0
while i < len(data):
    for size in (QUAD, RUN, 1):
        (n,) = struct.unpack_from("<I", data, i)
        i += 4 + n * size
    (n,) = struct.unpack_from("<I", data, i)
    i += 4 + 16 * n
    (n,) = struct.unpack_from("<I", data, i)
    i += 4 + CUSTOM * n
    customs += n > 0
    w, f, wake = struct.unpack_from("<IIf", data, i)
    i += 12
    frames += 1
    focused += f != 0xFFFFFFFF
    moving += wake == 0
    if w != 0xFFFFFFFF:
        events[w] = events.get(w, 0) + 1
slots = sorted(events)
if not slots or slots != list(range(len(slots))) or len(slots) < 3:
    sys.exit(f"{sys.argv[1]}: events by widget {events}: some widget never had one")
print(f"ok   {sys.argv[1].rsplit('/', 1)[-1]}: {frames} frames, events by widget slot {events}; "
      f"{focused} frames with focus, {moving} with a spring moving, {customs} with custom draws")
