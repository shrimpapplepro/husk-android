# Patches

## `husk-qemu-ios-jit.patch`

Husk's own. Diverts `tcg/region.c`'s split-W^X allocator to
`alloc_code_gen_buffer_splitwx_husk_ios()` on iOS, which sources the executable
half from StikDebug rather than allocating it locally (TXM forbids the latter).
Applied by `scripts/integrate_husk.sh` along with copying `src/ios-jit/*` into the
QEMU tree.

GPL-2.0-or-later, same as the file it patches.

## `husk-virgl-yuv-planes.patch`

HuskDroid's own, against UTM's virglrenderer (`VIRGL_COMMIT` in `scripts/build_gpu_ios.sh`). A Linux host
samples video frames (YV12, NV12) through EGL images of GBM buffers; iOS has no GBM, so the formats were
not advertised, the guest's minigbm faked YV12 in one R8 texture, and every video played pink and green.
Without GBM the patch advertises both formats, keeps one texture per plane (R8 Y/V/U, or R8 Y + RG8 UV),
fills them from each uploaded frame (the stride arrives in the transfer's `level`, as for
`virgl_gbm_transfer`), and hands them to the guest's per-plane sampler views, whose plane index rides in
`first_element`. The guest's shader then converts YUV to RGB as it would on a GBM host. A view of the
whole resource gets a CPU-converted RGBA copy instead. Applied by `scripts/build_gpu_ios.sh`.

MIT, same as the files it patches.

## `husk-spirv-cross-zero-init-stride.patch`

Husk's own, against SPIRV-Cross at the revision MoltenVK pins. When a compute shader's
shared memory has a zero initializer (DXVK's groupshared variables), the MSL backend
zeroes it in a loop whose stride it wrote as `gl_WorkGroupSize`, which is only declared
when the shader uses the WorkgroupSize builtin. The Metal compile then failed and the
pipeline was dropped. The stride now comes from LocalSize / LocalSizeId when there is no
such builtin. Applied by `scripts/build_moltenvk_ios.sh`.

Apache-2.0, same as the file it patches.

## `qemu-10.0.12-utm.patch`, `pixman-0.38.0.patch`, `libslirp-v4.9.1.patch`

Not ours. Taken verbatim from UTM's `patches/` directory
(https://github.com/utmapp/UTM), vendored so the build is reproducible without
cloning UTM.

These are patches against QEMU, pixman and libslirp, so they carry those
projects' licences rather than UTM's own Apache-2.0 — the QEMU patch is
GPL-2.0. This distinction matters: UTM's *application* code is Apache-2.0, which
is incompatible with GPLv2 and must not be copied into Husk. See
`docs/01-licensing.md`.

UTM's build script (`scripts/build_dependencies.sh`), which Husk's
`scripts/build_ios.sh` borrows its toolchain setup from, is ISC-licensed
(credited to Angelo Haller, 2014) and therefore permissive.
