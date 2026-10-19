// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import Photos
import UIKit
import UniformTypeIdentifiers

/// Android's machine, as the UI sees it: download it, start it (once JIT is on), save and stop it.
@MainActor
final class Emulator: ObservableObject {
    static let shared = Emulator()

    @Published private(set) var started = false
    @Published var message: String?
    /// Android's screen is fully up (home or an app is showing). False through a cold boot, and through
    /// the framework restart that follows every GPU-mode restore; the loading background shows until then.
    @Published private(set) var screenReady = false
    private var watchers = Set<AnyCancellable>()

    /// Before the first frame: logs, the trap guard, the firmware and disk seeds, sound on.
    func prepare() {
        UserDefaults.standard.register(defaults: [
            // Sound is a machine device: on from the first boot, so it never costs a second cold boot.
            "husk.sound": true,
            // No automatic save. On the GPU display a save in a running session restarts Android's framework
            // (stale GPU handles; ~1 min, touch dead) -- the first-boot save did exactly that. Save & Quit,
            // which happens as you leave, is the only save, so a session is never interrupted.
            "husk.autoSave": false,
            // virtio-snd stalls after the first sound; testing USB audio instead.
            "husk.soundDeviceKind": "usb",
            // Android's servers get ports of their own, never ones the iPhone's apps use: LocalSend for iOS
            // holds 53317, so Android's LocalSend is set to 53318 and reached at the iPhone's address on it.
            "husk.portForwards": ["tcp:53318", "udp:53318"],
            // GPU display. The software display was measured (build 569): restores would resume in place,
            // but a cold boot took 2 min 47 s (GPU: ~60 s) and the launcher and system_server raised
            // "isn't responding" dialogs under its load. The GPU's restore-then-restart is the better trade.
            "husk.gpuMode": true,
            // Sideloadly's free-account signing drops extended-virtual-addressing; 5 GiB then exhausted the
            // address space mid-boot (build 570). 4 GiB is what Husk's own shipped snapshot uses.
            "husk.maxGuestMiB": 4096,
        ])
        HuskLog.start()
        HuskLog.log("ui", AppVersion.display)
        clearBogusMemoryVerdict()
        JITBootstrap.installTrapGuard()
        do { try GuestImage.shared.prepareFirmware() } catch {
            HuskLog.log("guest", "firmware not ready: \(error.localizedDescription)")
        }
        GuestImage.shared.refresh()

        // A save stops the compositor and closes every app, the launcher included, and only the
        // compositor comes back by itself. Left alone, Android sat on an empty FallbackHome for
        // three and a half minutes, eating touches. Open the home screen as soon as the save is done.
        QemuRunner.shared.$isSavingState
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            // Only GPU-mode saves close the apps; a software-display save leaves Android exactly as it was.
            .filter { _ in QemuRunner.glProven }
            .sink { _ in Emulator.reopenHome(after: 2) }
            .store(in: &watchers)
    }

    /// Build 563 crashed in qemu_init on a port forward that could not bind, and the engine read that
    /// as "5120 MiB is too much for this phone" and remembered it for good -- which would keep the
    /// 5120 MiB save from ever restoring. Clear that verdict once; a real memory failure records it again.
    private func clearBogusMemoryVerdict() {
        let key = "huskdroid.clearedPortCrashVerdict"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let docs = HuskLog.logFileURL.deletingLastPathComponent()
        for name in ["husk-ram-failed", "husk-ram-attempt"] {
            if (try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))) != nil {
                HuskLog.log("ui", "cleared \(name) left by the port-forward crash")
            }
        }
    }

    static func reopenHome(after delay: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            let r = try? GuestBridge.shared.run(
                "am start -a android.intent.action.MAIN -c android.intent.category.HOME", timeout: 30)
            // am prints "Starting: Intent ..." when it delivers the intent, even when its status is not 0
            // (it reports the activity already on top as a warning).
            let ok = r?.status == 0 || r?.out.contains("Starting: Intent") == true
            HuskLog.log("ui", "after the save: home screen \(ok ? "reopened" : "NOT reopened (\(r?.out ?? "no bridge"))")")
        }
    }

    var needsDownload: Bool {
        if case .ready = GuestImage.shared.state { return false }
        return true
    }

    /// Start Android. Refuses without JIT: QEMU would fault on its first translated block.
    func start() {
        guard !started else { return }
        guard JITBootstrap.prewarmed else { message = "Turn JIT on first."; return }
        guard !needsDownload else { message = "Android isn't downloaded yet."; return }
        started = true
        message = nil
        HuskLog.log("ui", "starting Android")
        QemuRunner.shared.start()
        GuestBridge.shared.startHealthWatch()
        if QemuRunner.soundEnabled { HuskAudio.shared.start() }
        watchForScreen()
    }

    /// Decide when Android's screen is really up, by asking Android every 2 s over the shell bridge.
    ///
    /// A cold boot is ready at sys.boot_completed. A restore is not: the saved machine wakes with dead
    /// GPU handles, Android's watchdog restarts the framework (~60 s), and only the screen that restart
    /// enables counts -- a boot_progress_enable_screen event stamped after the restore. Three minutes
    /// is the cap, so the background can never stay up for good.
    /// When the loading background can go: once Android is awake and its own screen capture has something
    /// on it (the lock screen, or an app). Nothing weaker counts. "Booted", "surfaceflinger running" and
    /// even a focused window were all true over a black screen: focus is system_server's memory of
    /// before the save, not proof that anything reaches the display.
    ///
    /// A restore needs help to get there. Saving stops surfaceflinger and keeps system_server, and on
    /// restore system_server is still bound to the compositor that was stopped: it never draws to the
    /// new one, so the screen stays black however long it waits. Sometimes system_server restarted by
    /// itself; mostly it did not. So when the new surfaceflinger runs and the capture stays black, the
    /// framework is restarted (init's ctl.restart, which the shell may set where ctl.stop is refused).
    /// A fresh system_server shows the lock screen ~40 s later, and the network and the shell bridge
    /// survive it. If Android is asleep it is woken.
    private func watchForScreen() {
        screenReady = false
        let thread = Thread {
            let began = Date()
            /// A black 360x672 PNG is ~2.5 KB; the lock screen or any app is tens of KB at least.
            let drawn = 20_000
            var blackPolls = 0
            var restarted = false
            var codecsRestarted = false
            var lastWake = Date.distantPast
            var ready = false
            var how = ""
            while !ready && Date().timeIntervalSince(began) < 240 {
                Thread.sleep(forTimeInterval: 2)
                // Nothing past the getprops runs until surfaceflinger does: screencap waits for it
                // forever, and a waiting command holds the one shell connection -- the one the restore
                // needs to start surfaceflinger. That deadlock is what build 590 shipped. The timeouts
                // keep any later stall from holding it either.
                guard let r = try? GuestBridge.shared.run(
                    "getprop sys.boot_completed; sf=$(getprop init.svc.surfaceflinger); echo sf=$sf; "
                    + "[ \"$sf\" = running ] || exit 0; "
                    + "echo wake=$(timeout 8 dumpsys power 2>/dev/null | grep -m1 mWakefulness=); "
                    + "echo focus=$(timeout 8 dumpsys window 2>/dev/null | grep -m1 mCurrentFocus); "
                    + "echo shot=$(timeout 8 screencap -p 2>/dev/null | wc -c)",
                    timeout: 30) else { continue }
                let lines = r.out.split(separator: "\n").map(String.init)
                func value(_ key: String) -> String {
                    lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
                }
                let booted = lines.first?.trimmingCharacters(in: .whitespaces) == "1"
                guard booted, value("sf") == "running" else { continue }
                // The software codecs run in their own service, which a framework restart does not touch.
                // Its GPU context died with the save (the host cannot keep one), and the host drops every
                // upload from a context it does not know -- silently: videos then play black.
                if QemuRunner.didRestore && !codecsRestarted {
                    codecsRestarted = true
                    HuskLog.log("ui", "restored: restarting the media codec service (its GPU context did not survive)")
                    _ = try? GuestBridge.shared.run("setprop ctl.restart media.swcodec", timeout: 15)
                }
                let awake = value("wake").contains("Awake")
                let bytes = Int(value("shot")) ?? 0
                if awake && bytes > drawn {
                    ready = true
                    how = " (" + (value("focus").contains("NotificationShade") ? "lock screen" : "drawing")
                        + ", \(bytes / 1024) KB capture" + (restarted ? ", after restarting the framework" : "") + ")"
                    continue
                }
                if !awake && Date().timeIntervalSince(lastWake) > 10 {
                    lastWake = Date()
                    HuskLog.log("ui", "Android is asleep; waking it")
                    _ = try? GuestBridge.shared.run("input keyevent KEYCODE_WAKEUP", timeout: 15)
                    continue
                }
                blackPolls += 1
                if QemuRunner.didRestore && !restarted && blackPolls >= 2 {
                    restarted = true
                    HuskLog.log("ui", "restored onto a black screen; restarting Android's framework")
                    _ = try? GuestBridge.shared.run("setprop ctl.restart zygote", timeout: 15)
                }
            }
            HuskLog.log("ui", "Android's screen is up after \(Int(Date().timeIntervalSince(began))) s"
                              + (ready ? how : " (gave up waiting)"))
            Task { @MainActor in self.screenReady = true }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Quit without saving. The next start restores the last save, and its storage with it, so anything
    /// changed since is gone; with no save yet, the next start is a cold boot.
    func quitWithoutSaving() {
        HuskLog.log("ui", "quitting without saving")
        HuskLog.flushNow()
        exit(0)
    }

    /// QEMU cannot be stopped and started again in one process, so stopping is: save the machine, then quit.
    /// The next launch restores the save in seconds.
    func saveAndQuit() {
        guard started else { exit(0) }
        message = "Saving Android…"
        HuskLog.log("ui", "saving the machine, then quitting")
        QemuRunner.shared.saveState(reason: "stop") { ok in
            HuskLog.log("ui", "save \(ok ? "succeeded" : "FAILED"); quitting")
            HuskLog.flushNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }
}

/// Android's hardware and navigation buttons.
enum SystemKey: String, CaseIterable, Identifiable {
    case volumeUp = "volup", volumeDown = "voldown", mute, power, back, home, recents

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .volumeUp: return "speaker.plus"
        case .volumeDown: return "speaker.minus"
        case .mute: return "speaker.slash"
        case .power: return "power"
        case .back: return "chevron.backward"
        case .home: return "circle"
        case .recents: return "square.on.square"
        }
    }

    var title: String {
        switch self {
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        case .power: return "Power"
        case .back: return "Back"
        case .home: return "Home"
        case .recents: return "Recents"
        }
    }

    /// A USB keyboard key QEMU passes through (hw/input/hid.c maps these), or nil for an Android key event.
    private var qcode: String? {
        switch self {
        case .volumeUp: return "volumeup"
        case .volumeDown: return "volumedown"
        case .mute: return "audiomute"
        case .power: return "power"
        case .back: return "esc"   // Android treats Escape as Back
        case .home, .recents: return nil
        }
    }

    private var keyEvent: Int {
        switch self {
        case .home: return 3
        case .recents: return 187
        default: return 0
        }
    }

    /// Press and release. Keyboard keys are instant; Home and Recents go over the shell bridge.
    @discardableResult
    func press() -> Bool {
        if let qcode {
            let down = husk_display_send_key(qcode, true)
            _ = husk_display_send_key(qcode, false)
            return down
        }
        let code = keyEvent
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? GuestBridge.shared.run("input keyevent \(code)", timeout: 10)
        }
        return true
    }
}

/// Portrait or landscape, by hand -- like turning a phone with auto-rotate off.
///
/// Android's panel stays the same portrait size (no cold boot, the save stays valid); Android lays its
/// UI out sideways inside it (user_rotation), the picture is turned a quarter turn to match
/// (HuskGLView.rotated, which also maps touches through the turn), and iOS is held in landscape.
@MainActor
enum Rotation {
    static var landscape: Bool { HuskGLView.rotated }

    static func toggle() { set(landscape: !landscape) }

    static func set(landscape on: Bool) {
        HuskGLView.rotated = on
        applyToWindow()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = try? GuestBridge.shared.run(
                "settings put system accelerometer_rotation 0; settings put system user_rotation \(on ? 1 : 0)", timeout: 15)
            HuskLog.log("ui", "rotation: \(on ? "landscape" : "portrait") (android \(r?.status == 0 ? "turned" : "NOT turned"))")
        }
    }

    /// Ask iOS to match the current choice (the delegate's mask follows HuskGLView.rotated).
    static func applyToWindow() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { error in
                HuskLog.log("ui", "rotation refused by iOS: \(error.localizedDescription)")
            }
        }
    }
}

/// Commands from the companion (huskctl). Each returns a JSON body, or a PNG for a screenshot.
enum RemoteCommands {
    struct Reply: @unchecked Sendable {
        var body: Data
        var type = "application/json"
        var after: (() -> Void)?
    }

    static func json(_ obj: [String: Any]) -> Reply {
        Reply(body: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
    }

    static func run(_ cmd: [String: Any]) async -> Reply {
        let type = cmd["type"] as? String ?? ""
        HuskLog.log("remote", "command: \(type)")
        do {
            switch type {
            case "shell":
                let r = try GuestBridge.shared.run(cmd["cmd"] as? String ?? "true", timeout: 90)
                return json(["ok": r.status == 0, "status": r.status, "output": r.out])
            case "start":
                await MainActor.run { Emulator.shared.start() }
                let msg = await MainActor.run { Emulator.shared.message }
                return json(["ok": msg == nil, "message": msg ?? "starting"])
            case "stop":
                return Reply(body: Data(#"{"ok":true,"message":"saving, then quitting"}"#.utf8),
                             after: { MainActor.assumeIsolated { Emulator.shared.saveAndQuit() } })
            case "key":
                guard let key = SystemKey(rawValue: cmd["name"] as? String ?? "") else {
                    return json(["ok": false, "error": "keys: " + SystemKey.allCases.map(\.rawValue).joined(separator: " ")])
                }
                return json(["ok": key.press()])
            case "install", "push":
                let name = cmd["file"] as? String ?? ""
                guard let req = await Companion.shared.stagedFileURL(name) else { return json(["ok": false, "error": "bad file"]) }
                let tmp = try await Companion.shared.download(req)
                let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: tmp, to: local)
                defer { try? FileManager.default.removeItem(at: local) }
                if type == "install" {
                    let out = try AndroidFiles.install(local)
                    return json(["ok": out.contains("Success"), "output": out])
                }
                let dest = try AndroidFiles.push(local, into: cmd["dir"] as? String)
                return json(["ok": true, "output": dest])
            case "launch":
                let pkg = cmd["package"] as? String ?? ""
                let r = try GuestBridge.shared.run("monkey -p \(AndroidHost.quote(pkg)) -c android.intent.category.LAUNCHER 1", timeout: 30)
                return json(["ok": r.status == 0, "output": r.out])
            case "tunnel":
                let (host, token) = await MainActor.run { (Companion.shared.host, Companion.shared.tunnelToken) }
                guard let host, let session = cmd["session"] as? String,
                      let guestPort = cmd["guestPort"] as? Int, let tunnelPort = cmd["tunnelPort"] as? Int else {
                    return json(["ok": false, "error": "bad tunnel request"])
                }
                Tunnel.open(session: session, host: host, tunnelPort: tunnelPort, guestPort: guestPort, token: token)
                return json(["ok": true])
            case "rotate":
                let want = cmd["landscape"] as? Bool
                await MainActor.run { want.map { Rotation.set(landscape: $0) } ?? Rotation.toggle() }
                return json(["ok": true, "landscape": await MainActor.run { Rotation.landscape }])
            case "screenshot":
                let png = try GuestBridge.shared.pull("screencap -p", timeout: 30)
                return Reply(body: png, type: "image/png")
            case "status":
                return await MainActor.run {
                    json(["ok": true,
                          "jit": JITBootstrap.prewarmed,
                          "android": Emulator.shared.started,
                          "bootProgress": QemuRunner.shared.bootProgress,
                          "restored": QemuRunner.shared.restoredFromSnapshot,
                          "fps": QemuRunner.shared.fps])
                }
            default:
                return json(["ok": false, "error": "unknown command \(type)"])
            }
        } catch {
            return json(["ok": false, "error": error.localizedDescription])
        }
    }
}

/// Putting things into Android: APKs installed with pm, other files copied into a folder by type and
/// registered with Android's media library, so Gallery and Files see them at once.
enum AndroidFiles {
    /// Why this APK can't run here, before sending 80 MB for pm to refuse it; nil when it can (or
    /// the APK can't be read, in which case pm decides).
    static func incompatibility(_ apk: URL) -> String? {
        guard let abis = ApkABIs.read(apk), !abis.isEmpty, !abis.contains("arm64-v8a") else { return nil }
        let bits = abis.allSatisfy { $0.hasPrefix("armeabi") } ? "32-bit ARM" : abis.sorted().joined(separator: ", ")
        return "\(apk.lastPathComponent) only has \(bits) code, and HuskDroid's Android runs 64-bit (arm64) apps only."
    }

    /// pm's "Failure [INSTALL_FAILED_X: detail]" in words, or nil when pm said Success.
    static func failureReason(_ pmOutput: String) -> String? {
        guard !pmOutput.contains("Success") else { return nil }
        guard let code = pmOutput.firstMatch(of: /INSTALL_[A-Z_]+/).map({ String($0.output) }) else {
            return "Android refused it. See Logs."
        }
        switch code {
        case "INSTALL_FAILED_NO_MATCHING_ABIS": return "it has no 64-bit (arm64) code, which HuskDroid's Android needs."
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE": return "a different signature of this app is installed; uninstall it in Android first."
        case "INSTALL_FAILED_VERSION_DOWNGRADE": return "a newer version is already installed."
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE": return "Android is out of storage."
        case "INSTALL_FAILED_OLDER_SDK": return "it needs a newer Android than this one."
        case "INSTALL_PARSE_FAILED_NOT_APK", "INSTALL_PARSE_FAILED_NO_CERTIFICATES": return "it isn't a complete, signed APK (split APK bundles need all their parts)."
        default: return "Android refused it (\(code))."
        }
    }

    static func install(_ apk: URL) throws -> String {
        if let why = incompatibility(apk) {
            HuskLog.log("files", "install \(apk.lastPathComponent): not sent: \(why)")
            return "Failure [INSTALL_FAILED_NO_MATCHING_ABIS: checked before sending]"
        }
        let remote = "/data/local/tmp/huskdroid-install.apk"
        HuskLog.log("files", "install \(apk.lastPathComponent): pushing")
        try GuestBridge.shared.push(apk, to: remote) { _ in }
        defer { _ = try? GuestBridge.shared.run("rm -f \(remote)", timeout: 10) }
        let r = try GuestBridge.shared.run("pm install -r -t \(remote)", timeout: 600)
        HuskLog.log("files", "install \(apk.lastPathComponent): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
        return r.out
    }

    /// Where a file of this kind belongs in Android's shared storage.
    static func folder(for file: URL) -> String {
        let type = UTType(filenameExtension: file.pathExtension.lowercased())
        if type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true { return "/sdcard/Pictures" }
        if type?.conforms(to: .audio) == true { return "/sdcard/Music" }
        return "/sdcard/Download"
    }

    @discardableResult
    static func push(_ file: URL, into dir: String? = nil) throws -> String {
        let dest = "\(dir ?? folder(for: file))/\(androidName(file.lastPathComponent))"
        HuskLog.log("files", "sending \(file.lastPathComponent) (\(fileSize(file)) bytes) to \(dest)")
        try GuestBridge.shared.push(file, to: dest) { _ in }
        // MediaProvider's scan_file: the legacy MEDIA_SCANNER broadcast is ignored on this Android.
        let scan = try? GuestBridge.shared.run(
            "content call --uri content://media --method scan_file --arg \(AndroidHost.quote(dest))", timeout: 30)
        HuskLog.log("files", "sent \(file.lastPathComponent); media scan \(scan?.out.contains("Result") == true ? "ok" : "skipped")")
        return dest
    }

    /// A name Android's shared storage takes as it is: the characters its FAT-style rules refuse become
    /// "_", and the name fits in 255 bytes of UTF-8 with its extension kept. Names saved from the web
    /// carry all of them ("... on X: "https:__t.co_..." _ X.mp4").
    static func androidName(_ name: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|'").union(.controlCharacters)
        var clean = String(name.unicodeScalars.map { banned.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        while clean.contains("__") { clean = clean.replacingOccurrences(of: "__", with: "_") }
        let ext = (clean as NSString).pathExtension
        var stem = (clean as NSString).deletingPathExtension
        let limit = 255 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        while stem.utf8.count > limit { stem.removeLast() }
        if stem.isEmpty || stem.hasPrefix(".") { stem = "file" + stem }
        return ext.isEmpty ? stem : stem + "." + ext
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}

/// The native-code ABIs an APK carries (its lib/<abi>/ folders), read from the zip's central
/// directory without unpacking anything. Empty for a pure-Java APK; nil when it isn't a readable zip.
enum ApkABIs {
    static func read(_ url: URL) -> Set<String>? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size >= 22 else { return nil }
        // End of central directory: the last 22 bytes plus up to 64 KiB of comment.
        let tail = min(size, 22 + 65_535)
        try? h.seek(toOffset: size - tail)
        guard let end = try? h.read(upToCount: Int(tail)) else { return nil }
        let bytes = [UInt8](end)
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x05 && bytes[$0 + 3] == 0x06
        }) else { return nil }
        func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }
        let count = u16(bytes, eocd + 10), dirSize = u32(bytes, eocd + 12), dirOffset = u32(bytes, eocd + 16)
        guard dirOffset + dirSize <= size, (try? h.seek(toOffset: UInt64(dirOffset))) != nil,
              let dir = try? h.read(upToCount: dirSize) else { return nil }
        let d = [UInt8](dir)
        var abis = Set<String>(), o = 0
        for _ in 0..<count {
            guard o + 46 <= d.count, u32(d, o) == 0x0201_4B50 else { return nil }
            let nameLen = u16(d, o + 28), extraLen = u16(d, o + 30), commentLen = u16(d, o + 32)
            guard o + 46 + nameLen <= d.count else { return nil }
            let name = String(decoding: d[(o + 46)..<(o + 46 + nameLen)], as: UTF8.self)
            let parts = name.split(separator: "/")
            if parts.count == 3, parts[0] == "lib", parts[2].hasSuffix(".so") { abis.insert(String(parts[1])) }
            o += 46 + nameLen + extraLen + commentLen
        }
        return abis
    }
}

/// Android's own frame, as screencap draws it (Android's resolution and rotation, none of the app's
/// chrome), saved to the iPhone's photo library as a PNG.
@MainActor
final class Screenshot: ObservableObject {
    static let shared = Screenshot()

    @Published private(set) var busy = false
    @Published private(set) var toast: String?
    private var toastID = 0

    /// Only once Android draws: screencap waits forever while surfaceflinger is down.
    var available: Bool { Emulator.shared.screenReady && !QemuRunner.shared.isSavingState }

    func take() {
        guard available, !busy else { return }
        busy = true
        Task.detached(priority: .userInitiated) {
            let outcome: String
            do {
                let png = try GuestBridge.shared.pull("timeout 15 screencap -p", timeout: 30)
                guard png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
                    throw NSError(domain: "Screenshot", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Android sent no picture"])
                }
                try await Self.save(png)
                HuskLog.log("ui", "screenshot saved to Photos (\(png.count / 1024) KB)")
                outcome = "Screenshot saved to Photos"
            } catch {
                HuskLog.log("ui", "screenshot FAILED: \(error.localizedDescription)")
                outcome = "Screenshot failed: \(error.localizedDescription)"
            }
            await MainActor.run {
                self.busy = false
                self.show(outcome)
            }
        }
    }

    private nonisolated static func save(_ png: Data) async throws {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
            throw NSError(domain: "Screenshot", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "HuskDroid can't add to Photos. Allow it in Settings › HuskDroid › Photos."])
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = "Android \(stamp.string(from: Date())).png"
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: options)
        }
    }

    private func show(_ text: String) {
        toastID += 1
        let id = toastID
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if self.toastID == id { self.toast = nil }
        }
    }
}

/// Files and apps on their way into Android, with progress that outlives the panel.
@MainActor
final class Transfers: ObservableObject {
    static let shared = Transfers()

    @Published private(set) var busy: String?
    @Published private(set) var result: String?

    /// Copy picked files out of their security scope (Files) or take them as already-local (Photos),
    /// then send or install them one by one in the background.
    func send(_ urls: [URL], securityScoped: Bool, install: Bool = false) {
        guard Emulator.shared.started else { result = "Start Android first."; return }
        guard !urls.isEmpty else { return }
        var locals: [URL] = []
        for url in urls {
            let scoped = securityScoped && url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: local)
            do {
                try FileManager.default.copyItem(at: url, to: local)
                locals.append(local)
            } catch {
                HuskLog.log("files", "could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
            if !securityScoped { try? FileManager.default.removeItem(at: url) }
        }
        guard !locals.isEmpty else { result = "Couldn't read the picked file."; return }
        result = nil
        busy = install ? "Installing \(locals[0].lastPathComponent)…" : "Sending \(locals.count) file\(locals.count == 1 ? "" : "s")…"
        DispatchQueue.global(qos: .userInitiated).async {
            var sent: [String] = [], failed: [String] = [], notes: [String] = []
            for (i, local) in locals.enumerated() {
                Task { @MainActor in
                    if locals.count > 1 { self.busy = "Sending \(i + 1) of \(locals.count)…" }
                }
                do {
                    if install {
                        let out = try AndroidFiles.install(local)
                        if let why = AndroidFiles.failureReason(out) {
                            failed.append(local.lastPathComponent)
                            notes.append(AndroidFiles.incompatibility(local) ?? "\(local.lastPathComponent): \(why)")
                        } else {
                            sent.append(local.lastPathComponent)
                        }
                    } else {
                        if local.pathExtension.lowercased() == "apk", let why = AndroidFiles.incompatibility(local) {
                            notes.append(why + " Android will say \"App not installed\".")
                        }
                        sent.append(try AndroidFiles.push(local))
                    }
                } catch {
                    HuskLog.log("files", "FAILED \(local.lastPathComponent): \(error.localizedDescription)")
                    failed.append(local.lastPathComponent)
                }
                try? FileManager.default.removeItem(at: local)
            }
            let text: String
            if install {
                text = failed.isEmpty ? "Installed \(sent.first ?? "the app"). It's in Android's app list."
                                      : "Install failed: " + (notes.isEmpty ? "\(failed.joined(separator: ", ")). See Logs."
                                                                            : notes.joined(separator: " "))
            } else {
                let folders = Set(sent.map { ($0 as NSString).deletingLastPathComponent.replacingOccurrences(of: "/sdcard/", with: "") })
                text = (sent.isEmpty ? "" : "Sent \(sent.count) to Android › \(folders.sorted().joined(separator: ", ")). Open Files or Gallery in Android.")
                     + (failed.isEmpty ? "" : " Failed: \(failed.joined(separator: ", ")).")
                     + (notes.isEmpty ? "" : " " + notes.joined(separator: " "))
            }
            Task { @MainActor in self.busy = nil; self.result = text }
        }
    }
}

enum AppVersion {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static var display: String { "HuskDroid \(version) (\(build))" }
}
