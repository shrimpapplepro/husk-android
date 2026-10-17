// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import UIKit

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
            "husk.autoSave": true,
            // virtio-snd stalls after the first sound; testing USB audio instead.
            "husk.soundDeviceKind": "usb",
            // Android's servers get ports of their own, never ones the iPhone's apps use: LocalSend for iOS
            // holds 53317, so Android's LocalSend is set to 53318 and reached at the iPhone's address on it.
            "husk.portForwards": ["tcp:53318", "udp:53318"],
            // GPU display. The software display was measured (build 569): restores would resume in place,
            // but a cold boot took 2 min 47 s (GPU: ~60 s) and the launcher and system_server raised
            // "isn't responding" dialogs under its load. The GPU's restore-then-restart is the better trade.
            "husk.gpuMode": true,
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
            HuskLog.log("ui", "after the save: home screen \(r?.status == 0 ? "reopened" : "NOT reopened (\(r?.out ?? "no bridge"))")")
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
                let dest = try AndroidFiles.push(local, into: cmd["dir"] as? String ?? "/sdcard/Download")
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

/// Putting things into Android: APKs installed with pm, other files copied into a folder.
enum AndroidFiles {
    static func install(_ apk: URL) throws -> String {
        let remote = "/data/local/tmp/huskdroid-install.apk"
        try GuestBridge.shared.push(apk, to: remote) { _ in }
        defer { _ = try? GuestBridge.shared.run("rm -f \(remote)", timeout: 10) }
        let r = try GuestBridge.shared.run("pm install -r -t \(remote)", timeout: 600)
        HuskLog.log("files", "install \(apk.lastPathComponent): \(r.out.trimmingCharacters(in: .whitespacesAndNewlines))")
        return r.out
    }

    static func push(_ file: URL, into dir: String) throws -> String {
        let dest = "\(dir)/\(file.lastPathComponent)"
        try GuestBridge.shared.push(file, to: dest) { _ in }
        // Make it show up in Android's file pickers and gallery.
        _ = try? GuestBridge.shared.run("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://\(AndroidHost.quote(dest))", timeout: 15)
        HuskLog.log("files", "copied \(file.lastPathComponent) to \(dest)")
        return dest
    }
}

enum AppVersion {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static var display: String { "HuskDroid \(version) (\(build))" }
}
