# all: no
# Screen-reader smoke test of the AccessKit bridge on Linux (src/a11y/accesskit/smoke.py): the
# shells' example on a private AT-SPI bus. Its tree is walked and its buttons clicked over D-Bus,
# then Orca runs (on Xvfb) while the example moves focus, and Orca's speech must name the window,
# Reset, Wireframe and the Exposure slider with its range. at-spi2-core, Orca, Xvfb and busctl
# come from the flake's pinned nixpkgs. Out of `all`: it fetches them and AccessKit's 68 MB archive, and takes ~20 s.
zig build accesskit-smoke
pkgs="nixpkgs#dbus nixpkgs#at-spi2-core nixpkgs#orca nixpkgs#python3 nixpkgs#xvfb-run nixpkgs#systemd"
spi=$(nix build --inputs-from . nixpkgs#at-spi2-core --no-link --print-out-paths)
rm -rf zig-out/accesskit-smoke
# shellcheck disable=SC2086
nix shell --inputs-from . $pkgs -c env -u WAYLAND_DISPLAY -u DISPLAY \
    xvfb-run -a dbus-run-session -- \
    python3 src/a11y/accesskit/smoke.py "$PWD/zig-out/bin/accesskit-smoke" "$spi" zig-out/accesskit-smoke
