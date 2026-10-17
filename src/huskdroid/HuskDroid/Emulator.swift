// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
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
    private func watchForScreen() {
        screenReady = false
        let thread = Thread {
            let began = Date()
            var restoreUptimeMs: Int?
            var ready = false
            while !ready && Date().timeIntervalSince(began) < 180 {
                Thread.sleep(forTimeInterval: 2)
                guard let r = try? GuestBridge.shared.run(
                    "cat /proc/uptime; getprop sys.boot_completed; "
                    + "logcat -b events -d -t 4000 2>/dev/null | grep boot_progress_enable_screen | tail -3",
                    timeout: 15) else { continue }
                let lines = r.out.split(separator: "\n").map(String.init)
                guard let uptime = lines.first.flatMap({ Double($0.split(separator: " ").first ?? "") }) else { continue }
                let booted = lines.count > 1 && lines[1].trimmingCharacters(in: .whitespaces) == "1"
                let screens = lines.compactMap { line -> Int? in
                    guard let r = line.range(of: "boot_progress_enable_screen: ") else { return nil }
                    return Int(line[r.upperBound...].trimmingCharacters(in: .whitespaces))
                }
                let restored = QemuRunner.didRestore
                if restored {
                    if restoreUptimeMs == nil { restoreUptimeMs = Int(uptime * 1000) - 3000 }
                    ready = booted && screens.contains { $0 > restoreUptimeMs! }
                } else {
                    ready = booted
                }
            }
            HuskLog.log("ui", "Android's screen is up after \(Int(Date().timeIntervalSince(began))) s"
                              + (ready ? "" : " (gave up waiting)"))
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
    static func install(_ apk: URL) throws -> String {
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
        let dest = "\(dir ?? folder(for: file))/\(file.lastPathComponent)"
        HuskLog.log("files", "sending \(file.lastPathComponent) (\(fileSize(file)) bytes) to \(dest)")
        try GuestBridge.shared.push(file, to: dest) { _ in }
        // MediaProvider's scan_file: the legacy MEDIA_SCANNER broadcast is ignored on this Android.
        let scan = try? GuestBridge.shared.run(
            "content call --uri content://media --method scan_file --arg \(AndroidHost.quote(dest))", timeout: 30)
        HuskLog.log("files", "sent \(file.lastPathComponent); media scan \(scan?.out.contains("Result") == true ? "ok" : "skipped")")
        return dest
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
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
            var sent: [String] = [], failed: [String] = []
            for (i, local) in locals.enumerated() {
                Task { @MainActor in
                    if locals.count > 1 { self.busy = "Sending \(i + 1) of \(locals.count)…" }
                }
                do {
                    if install {
                        let out = try AndroidFiles.install(local)
                        out.contains("Success") ? sent.append(local.lastPathComponent) : failed.append(local.lastPathComponent)
                    } else {
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
                                      : "Install failed: \(failed.joined(separator: ", ")). See Logs."
            } else {
                let folders = Set(sent.map { ($0 as NSString).deletingLastPathComponent.replacingOccurrences(of: "/sdcard/", with: "") })
                text = (sent.isEmpty ? "" : "Sent \(sent.count) to Android › \(folders.sorted().joined(separator: ", ")). Open Files or Gallery in Android.")
                     + (failed.isEmpty ? "" : " Failed: \(failed.joined(separator: ", ")).")
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
