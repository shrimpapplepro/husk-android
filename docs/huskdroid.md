# HuskDroid

An Android emulator for iOS, and nothing else. It keeps Husk's emulator engine
and replaces everything around it.

## What is kept from Husk

The engine only:

- `src/ios-jit/` — QEMU glue: JIT region (brk protocol), GL/software display,
  input (`husk_display_send_key`/`_pointer`), audio ring (`husk_audio_pull`),
  snapshots.
- QEMU itself (`scripts/build_ios.sh`, `integrate_husk.sh`), ANGLE, virglrenderer.
- From `src/app/Husk/`, as engine code, not UI: `QemuRunner` (machine setup and
  lifecycle), `GuestImage`/`GuestManifest`/`Downloads` (Android image download
  and snapshot), `GuestBridge` (shell into Android), `HuskAudio` (iOS audio out),
  `HuskGLView`/`HuskMetalPresenter` (the guest's surface), `JITBootstrap`,
  `HuskLog`.

Everything else in `src/app/Husk/` is not compiled: the translation layer, PS4,
the library, Discover, StikJIT, onboarding, settings. The app's UI is new code
in `src/app/HuskDroid/`.

## The app

Emulator-first. It opens on Android's screen; everything else is in a pull-down
panel.

- **Status strip** (top): JIT, Android, snapshot, companion link.
- **Panel**: Request JIT, Start/Stop Android, Import APK, Import file, Logs,
  system buttons.
- **System buttons**: Volume up/down and Mute and Power go to Android as USB
  keyboard keys (HID 0x80/0x81/0x7f/0x66, which QEMU's usb-kbd passes through);
  Back is Esc; Home and Recents are `input keyevent 3` / `187` over the bridge.
- **Sound**: the engine's audio ring, played by `HuskAudio`.
- **Rotation**: follows the game; the guest display is resized to match.

## JIT

The phone cannot grant itself JIT (TXM); an attached debugger must service the
brk protocol. The companion does that over the network (`huskjit-net`:
lockdown over TCP → userspace RSD tunnel → debugserver over gdb-remote).

Flow: app launches → asks the companion `POST /v1/jit` → companion attaches by
name and streams progress → app sees `CS_DEBUGGED`, claims its 512 MiB region
→ companion detaches. The app shows each step; no walkthrough, no other app.

## Companion (`tools/companion/`, runs on himari)

The phone always opens the connections, so it works on home Wi-Fi and over
Tailscale without listening on the phone.

- App → companion: `POST /v1/jit` (streamed), `POST /v1/logs` (batched lines),
  `GET /v1/next` (long-poll for a command), `POST /v1/result/<id>`.
- `huskctl` (on the Mac) → companion: `logs [-f]`, `shell CMD`, `status`,
  `start`, `stop`, `install APK`, `push FILE`, `key NAME`, `screenshot`, `jit`.
- Bearer token, from the vault (`huskdroid.token`), handed to xcodebuild through
  the environment by `src/huskdroid/build.sh` (never in a tracked file).
- Listens on 8790 (and 8791 for tunnels). The app tries the addresses in
  `HUSKDROID_MAC_HOSTS` (config/local.env) in order: Wi-Fi, then Tailscale.

## Identity and signing

`com.shrimpapplepro.huskdroid.<TEAM>`, Xcode-signed with the paid team and the
extended-virtual-addressing and increased-memory-limit entitlements
(`build.sh --install`). Sideloadly's signing drops both, which ran the address
space out mid-boot.

## Status

See README.md (what changed from Husk, known limits) and AGENTS.md (setup).
