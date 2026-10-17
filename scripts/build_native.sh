#!/bin/bash
# HuskDroid: build the emulator engine -- QEMU and its dependencies, ANGLE, libepoxy + virglrenderer,
# QEMU with Husk's sources integrated, and the guest firmware. The app (src/huskdroid) links the result.
#
#   scripts/build_native.sh            everything not built yet (stages are stamped in build/stamps)
#   PYTHON_ENV=/path/to/venv scripts/build_native.sh
#
# Needs Xcode 27 (DEVELOPER_DIR), its Metal Toolchain (xcodebuild -downloadComponent MetalToolchain),
# meson, ninja, pkg-config, cmake, qemu-img, and a python3 with pyyaml and mako first on PATH
# (virglrenderer's meson build imports yaml).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}
[ -n "${PYTHON_ENV:-}" ] && export PATH="$PYTHON_ENV/bin:$PATH"
python3 -c 'import yaml, mako' 2>/dev/null || { echo "python3 needs pyyaml and mako (set PYTHON_ENV to a venv with them)" >&2; exit 1; }
step() { printf '\n##### %s  [%s]\n' "$*" "$(date +%H:%M:%S)"; }
step "fetch sources";        ./scripts/fetch_sources.sh
step "deps";                 ./scripts/build_ios.sh libffi glib pixman libucontext libslirp
cp build/ios-arm64/cross-darwin.meson build/ios-arm64/cross-ios-darwin.meson
[ -f build/ios-arm64/sysroot/lib/libANGLE-shared.dylib ] || { step "ANGLE"; ./scripts/build_angle_ios.sh; }
[ -f build/ios-arm64/sysroot/lib/libvirglrenderer.a ] || { step "epoxy + virglrenderer";
  PKG_CONFIG_LIBDIR="$PWD/build/ios-arm64/sysroot/lib/pkgconfig:$PWD/build/ios-arm64/sysroot/share/pkgconfig" ./scripts/build_gpu_ios.sh; }
step "QEMU";                 ./scripts/build_ios.sh qemu
step "integrate + rebuild";  ./scripts/integrate_husk.sh && ./scripts/build_ios.sh qemurebuild
step "guest firmware";       ./scripts/fetch_phase0_guest.sh
nm -gU build/ios-arm64/lib/libqemu-aarch64-softmmu.dylib | grep -q husk_sound_attach \
  || { echo "libqemu is missing husk_sound_attach: integrate_husk.sh did not export it" >&2; exit 1; }
step "ENGINE DONE"
