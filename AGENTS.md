# Setting up HuskDroid (for agents)

Follow these stages in order. Each ends with a check; do not move on until it passes. Read
[`README.md`](README.md) for what HuskDroid is and [`docs/huskdroid.md`](docs/huskdroid.md) for the design.

## 0. Values that belong to one setup

They live in `config/local.env`, which git ignores. Create it from the template and fill in:

```sh
cp config/local.env.example config/local.env
```

| Variable | What | How to find it |
|---|---|---|
| `HUSKDROID_UDID` | The iPhone | `xcrun devicectl list devices` |
| `HUSKDROID_PHONE_HOSTS` | The iPhone's addresses, tried in order | see *Network* below |
| `HUSKDROID_MAC_HOSTS` | `host:8790` of this Mac, tried in order | see *Network* below |
| `HUSKDROID_TEAM` | Paid developer team that signs the app | the team id of a paid account in Xcode |

### Network

Two connections must work, and both are plain TCP:

- **Mac → iPhone, port 62078** (lockdownd), for JIT. Test: `nc -z -G 3 <iphone> 62078`.
- **iPhone → Mac, ports 8790 and 8791** (companion and tunnels), for JIT requests, logs and adb.
  Test from the Mac: `curl -s -o /dev/null -w '%{http_code}\n' http://<mac>:8790/v1/status` gives `401`;
  the app's status pill shows Mac green once it gets through.

**Start with the same Wi-Fi.** It needs nothing else:

- The iPhone's address: `ideviceinfo -n -k WiFiAddress` gives its hardware address; find that in
  `arp -a` (or the router's client list). `dns-sd -B _apple-mobdev2._tcp` confirms it is on the network.
- The Mac's address: `ipconfig getifaddr en0` (or `en1`), plus `:8790`.
- Addresses from DHCP can change: reserve both on the router, or the setup breaks when a lease renews.

**Away from that Wi-Fi**, any route that carries both connections works. Work out what this user's
setup can actually do and add those addresses after the Wi-Fi ones (each list is tried in order). A
mesh VPN both devices are on (Tailscale, ZeroTier, WireGuard) is the usual answer; use the tests above to
keep only addresses that really connect. Do not open these ports to the internet with port forwarding:
lockdownd and the companion would face the whole internet, with the token as the companion's only
protection. If no route exists, JIT works on the home Wi-Fi only; tell the user so.

`build.sh` reads it (the Mac hosts go into the app's Info.plist); `tools/companion/install.sh` copies it to
`~/.config/huskdroid/config.env`, where the companion reads the iPhone values. Also machine-specific:
`DEVELOPER_DIR` (default `/Applications/Xcode-beta.app`) and pymobiledevice3's Python (`PY` in
`install.sh`, default the `uv tool` install).

## 1. Engine

Prerequisites on the Mac:

```sh
brew install meson ninja pkg-config cmake xcodegen qemu
xcodebuild -downloadComponent MetalToolchain        # with DEVELOPER_DIR set to the Xcode you use
uv venv ~/huskdroid-py && VIRTUAL_ENV=~/huskdroid-py uv pip install pyyaml mako
```

The tree must be on APFS (an exFAT drive breaks symlinks; use an APFS sparse bundle on it instead).
~20 GB free.

```sh
PYTHON_ENV=~/huskdroid-py scripts/build_native.sh
```

Check: the script ends with `ENGINE DONE`, and
`nm -gU build/ios-arm64/lib/libqemu-aarch64-softmmu.dylib | grep husk_sound_attach` prints a symbol.

## 2. Companion (on the Mac)

```sh
uv tool install pymobiledevice3
~/.local/bin/perlica-secret set huskdroid.token     # the user types any long random string; never ask for it in chat
tools/companion/install.sh
```

Without `perlica-secret`, run the companion with the token in `PERLICA_SECRET` and adapt `install.sh`'s
LaunchAgent and `huskctl`'s `token()`.

The iPhone must be paired with this Mac (plugged in once, "Trust") and have Developer Mode on. The
Developer Disk Image must be mounted: `xcrun devicectl device info ddiServices --device <UDID>` mounts
Xcode's. **It is unmounted by every iPhone reboot; JIT fails until it is mounted again.**

Checks:

```sh
huskctl status                    # JSON from the companion
huskjit-net --probe               # "debugserver up in 0.4s" and a qHostInfo line
curl -s -o /dev/null -w '%{http_code}\n' http://<mac-host>:8790/v1/status   # 401 (token required)
```

## 3. App

```sh
src/huskdroid/build.sh --install
```

It reads the token from the vault, builds with the team's automatic signing, and refuses to install
unless the signed app carries `extended-virtual-addressing`, `increased-memory-limit` and
`get-task-allow`. If HuskDroid is open it is told to Save & Quit first. Build numbers are the commit
count; the panel shows `HuskDroid VERSION (BUILD)`.

`src/huskdroid/build.sh` with no flag makes an unsigned IPA for sideloaders instead. **Avoid that path:**
Sideloadly signs with the team but does not enable the memory capabilities, iOS strips them, and the
4 GiB guest then runs out of address space mid-boot.

Check on the device: `ideviceinstaller -u <UDID> list --user --xml` lists HuskDroid with both kernel
entitlements.

## 4. First run

The user opens HuskDroid, allows Local Network access, taps Download Android (~2 GB) and then Start
Android. JIT is requested automatically once the companion answers.

Follow it with `huskctl logs -f`:

```
[ui] HuskDroid 0.2.0 (N)
[companion] linked to http://...:8790
[jit] attached to HuskDroid; ... prepared 32768 pages in ~2s ... detach: OK
[app] [jit] region held; debugger released
[qemu] no saved machine; booting Android from cold        (first run)
[snap] Android reports boot_completed
[ui] Android's screen is up after N s
```

Then: `huskctl adb devices` (the user taps Allow on Android once), and ask the user to Save & Quit so the
first save exists. Later starts log `restored a saved machine` and the screen is up in ~45 s.

## Operating it

- Install apps: `huskctl install app.apk`, or for split APKs from another Android device:
  `adb -s <device> shell pm path <pkg>`, `adb pull` each, `huskctl adb install-multiple base.apk split_*.apk`.
- Files: `huskctl push FILE` (Pictures/Music/Download by type, indexed by MediaProvider).
- Never install over a running session yourself; `build.sh --install` saves first.
- A save happens only on Save & Quit (`huskctl stop`). Saving while the user is in a session restarts
  Android's framework (GPU state cannot be saved). A restore returns storage to the save.

## When something fails

| Symptom | Cause and fix |
|---|---|
| `[jit] ERROR: the phone is not reachable` | No address in `HUSKDROID_PHONE_HOSTS` answers on 62078: the iPhone is on another network, its address changed, or the route (VPN) is down |
| `no pair record` | Plug the iPhone in once and Trust; the record is copied to `~/.pymobiledevice3` |
| JIT attaches but `get_service_port` fails | Developer Disk Image not mounted (after a reboot): `devicectl device info ddiServices` |
| App closes instantly in `qemu_init` | A port forward could not bind (fixed: busy ports are skipped); check `husk.portForwards` |
| SIGABRT in `qemu_memalign` / `qht_grow_maybe` | Out of address space: the app lacks `extended-virtual-addressing`; reinstall with `build.sh --install` |
| `save FAILED: ... non-migratable device` | A sound device on the command line; sound must be `usb` (hot-plugged), never `virtio` |
| `no snapshot matching a N MiB guest` | Save taken at another size, display mode or sound kind; one cold boot, then Save & Quit |
| `memory layout changed ... retiring the old snapshot` | `husk-ram-failed` / memory strategy changed; the save is discarded once |
| Touch dead, black screen ~1 min after a restore | Expected: Android's framework restart; wait for `screen is up` |
| No sound in videos | virtio-sound stall; `husk.soundDeviceKind` must be `usb` |
| `Upgrade's application-identifier ... does not match` | The installed copy came from another signer; uninstall it (`devicectl device uninstall app`) |
| iOS crash reports | `devicectl device info files --domain-type systemCrashLogs`, files `HuskDroid-*.ips` |
| App log on the device | `devicectl device copy from --domain-type appDataContainer --domain-identifier <bundle id> --source Documents/husk.log` |
