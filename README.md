# HuskDroid

An Android emulator for iPhone, and nothing else. A full LineageOS (Android 16) runs under QEMU inside
an iOS app, with JIT granted wirelessly by a companion on a Mac, sound, snapshots, file import and adb.

HuskDroid is a fork of [Leviidev/Husk](https://github.com/Leviidev/Husk) (GPL-2.0-or-later). It keeps
Husk's emulator engine and replaces everything around it. Husk's own README is kept at
[`docs/husk-upstream-README.md`](docs/husk-upstream-README.md); the design notes are in
[`docs/huskdroid.md`](docs/huskdroid.md). To set it up with an AI agent, point the agent at
[`AGENTS.md`](AGENTS.md).

## What it does

- **Android, full screen.** LineageOS on a virtual GPU (virtio-gpu-gl through virglrenderer and ANGLE to
  Metal), 360×672 at 160 dpi, 4 GiB of RAM, 4 cores. Touch, keyboard, and Android's system buttons.
- **JIT without a cable, a VPN or StikDebug.** The app asks a companion on your Mac; the companion
  reaches the iPhone over Wi-Fi or Tailscale and services the JIT request in about 2 seconds.
- **Sound.** Android's audio plays on the iPhone.
- **Snapshots.** Save & Quit stores the whole machine; the next start restores it instead of booting
  (~45 s until the screen is back, against ~60 s to 2 min for a cold boot).
- **Getting things in.** Install APKs, send photos, videos and files (sorted into Pictures, Music or
  Download and indexed, so Android's Gallery and Files see them), or use adb from the Mac.
- **Remote control for debugging.** The app streams its logs to the Mac, and `huskctl` runs shell
  commands in Android, installs, pushes, takes screenshots, rotates and connects adb.
- **Landscape** with a Rotate button, a Liquid Glass control panel that morphs out of the status pill,
  and a live-rendered spectrum glow behind Android while it loads.

## What changed from Husk

Husk runs Android apps two ways: a translation layer that runs games' native code directly, and full
Android under QEMU. HuskDroid keeps only the second, and fixes what that left broken.

| Area | Husk | HuskDroid |
|---|---|---|
| App | Library, translation layer, PS4 layer, Discover, StikJIT | A new emulator-first app (`src/huskdroid`); only the engine is shared |
| JIT | StikDebug, built-in StikJIT, TrollStore; all need LocalDevVPN | A companion on the Mac grants it over Wi-Fi/Tailscale (`huskjit_core.py`): lockdown over TCP, a no-root userspace tunnel, debugserver over gdb-remote |
| Sound | Off by default; virtio-sound stalls after the first sound | USB audio, hot-plugged after boot/restore and unplugged around every save |
| Snapshots | A locally saved machine never restored (size bug); every save closed all apps | Fixed restore; saving only on Save & Quit; home screen reopened; updates save first |
| Memory | 5 GiB guest | 4 GiB cap (`husk.maxGuestMiB`), since some signers drop extended VA |
| Networking | Shell bridge only | Port forwards from the iPhone into Android (LocalSend on 53318), adb over a tunnel |
| Build | Needs Rust, MoltenVK, the PS4 dylib, Java runtime | Engine + app only; fixes for Xcode under `env -i`, Meson on macOS 27, Metal toolchain, PyYAML |
| Install | Sideloadly / AltStore / TrollStore | Xcode-signed with the memory entitlements, installed by `devicectl` |

Engine fixes in shared files (`src/app/Husk`, `src/ios-jit`, `scripts`) are written to be upstreamable:

- `QemuRunner.guestMemoryMiB()` returned a saved machine's size without recording it, so the restore
  check compared it with 0 and every local save cold-booted.
- `husk-snapshot.c`: `husk_sound_attach()` plugs a `usb-audio` card in at run time and the save path
  unplugs it for the save, because both QEMU sound devices this guest can drive are `.unmigratable`.
- `husk-audio.c`: a 10 ms fade-in after silence removes the crack at the start of every sound.
- `QemuRunner.portForwards` (`husk.portForwards`): forwards checked before launch; a busy port is
  skipped instead of making QEMU exit in `qemu_init`.
- `husk.soundDeviceKind`, `husk.maxGuestMiB`: settings for the above.
- `build_angle_ios.sh` passes `DEVELOPER_DIR` through `env -i`; `build_ios.sh` marks QEMU's cross file
  `needs_exe_wrapper` (macOS 27 kills iOS binaries run from a shell).

## Known limits

- **A restore restarts Android's screen.** The GPU's state cannot be saved, so after a restore Android's
  framework restarts once (~45 s, under the loading glow). The software display would avoid it, but it
  was measured and rejected: a 2 min 47 s cold boot and "isn't responding" dialogs.
- **Saving in a running session** would restart the framework for the same reason, so nothing saves
  until Save & Quit. A restore also returns Android's storage to the save.
- **No Google Play / Play Services.** Copy apps from another Android device (`adb pull` the splits) or
  use APKs.
- **Emulated CPU.** Every Android instruction is translated (TCG); expect a fraction of a real phone's
  speed. Fine for apps and benchmarks, not for heavy games. GPU compute (Vulkan/OpenCL) is absent.
- **LocalSend discovery.** iOS blocks multicast for sideloaded apps; other devices reach Android's
  LocalSend at the iPhone's address on port 53318.

## Setup

You need an iPhone on iOS 27 with Developer Mode on, a Mac with Xcode 27 (the beta is fine), a paid
Apple developer team (for the memory entitlements), and the iPhone paired with the Mac once over USB.
[`AGENTS.md`](AGENTS.md) has every command, check and machine-specific value; this is the outline.

1. **Build the engine** (QEMU and its libraries, ANGLE, virglrenderer, firmware) on an APFS volume (not
   exFAT) with ~20 GB free: `scripts/build_native.sh`. About 5 minutes on an M-series Mac.
2. **Install the companion** on the Mac: `uv tool install pymobiledevice3`, put a token in the vault
   (`perlica-secret set huskdroid.token`), then `tools/companion/install.sh`. It runs as a LaunchAgent on
   port 8790 (JIT, logs, commands) and 8791 (tunnels), and installs `huskctl` and `huskjit-net`.
3. **Build and install the app**: `src/huskdroid/build.sh --install` signs with your team, checks the
   memory entitlements and installs on the iPhone. If HuskDroid is open, it is saved and closed first.
4. **First run.** Open HuskDroid, allow Local Network access, tap Download Android (~2 GB). JIT turns on
   by itself once the Mac answers. Tap Start Android; the first boot takes about 2 minutes.

### JIT

TXM-enforced iPhones only let an attached debugger give an app executable memory. HuskDroid claims one
512 MiB region at start, through Husk's brk protocol (`src/ios-jit/husk-brk.S`), while the companion's
debugger answers:

```
HuskDroid ──POST /v1/jit──▶ companion (Mac) ──lockdown TCP :62078──▶ iPhone
                                 └─ userspace RSD tunnel ─▶ debugserver ─ vAttachName;HuskDroid
brk #0x69  → probe answered      brk #0xf00d x16=1 → 512 MiB RX allocated, 32768 pages touched
brk #0xf00d x16=0 → detach        (≈ 2 s on Wi-Fi)
```

From the Mac, `huskjit-net [AppName]` does the same by hand (it also works for Husk). JIT lasts until
the app quits.

### Everyday use

- **Panel** (tap the status pill): JIT, Android (Start / Save & Quit), Mac link; Volume ±, Mute, Power,
  Back, Home, Recents, Rotate; Install APK, Send to Android (Photos & Videos or Files), Logs.
- **Leaving:** always Save & Quit. Swiping the app away loses everything since the last save.
- **From the Mac:**

```
huskctl status | logs -f | jit
huskctl shell 'pm list packages'          huskctl screenshot
huskctl install app.apk                   huskctl push photo.jpg [DIR]
huskctl key volup|voldown|mute|power|back|home|recents
huskctl rotate [portrait|landscape]       huskctl start | stop
huskctl adb devices                       # adb at 127.0.0.1:15555 (approve once on Android)
huskctl adb install-multiple base.apk split_*.apk
```

## Layout

```
src/huskdroid/          the app: UI, JIT flow, companion link, tunnels, Rainbow.metal, build.sh
src/app/Husk/           Husk's engine files HuskDroid compiles (QemuRunner, GuestImage, HuskBridgeFS,
                        HuskGLView, HuskMetalPresenter, HuskAudio, HuskLog, ApkMetadata)
src/ios-jit/            QEMU glue: JIT region, display, audio, snapshots, USB sound hot-plug
tools/companion/        companion.py, huskjit_core.py, huskctl, install.sh
scripts/                engine build scripts (from Husk, with the fixes above)
docs/huskdroid.md       design notes
```

## Licence

GPL-2.0-or-later, as Husk: HuskDroid links QEMU (GPLv2). See [`docs/01-licensing.md`](docs/01-licensing.md).
