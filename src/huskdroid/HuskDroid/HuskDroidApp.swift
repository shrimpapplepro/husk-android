// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

final class HuskDroidDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // Locked to the Rotate button's choice: turning the phone must not fight it.
        HuskGLView.rotated ? .landscapeRight : .portrait
    }
}

@main
struct HuskDroidApp: App {
    @UIApplicationDelegateAdaptor(HuskDroidDelegate.self) private var delegate
    @ObservedObject private var companion = Companion.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Emulator.shared.prepare()
        Companion.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Ask for JIT as soon as the Mac answers: by the time Android is downloaded or
                // the panel is opened, it is already on.
                // A failed try counts too: it usually failed because the Mac was out of reach (Tailscale off).
                .onChange(of: companion.isLinked) { _, linked in
                    guard linked, !JITBootstrap.prewarmed else { return }
                    switch JITFlow.shared.phase {
                    case .off, .failed: JITFlow.shared.request()
                    default: break
                    }
                }
                // Back from the Tailscale app (or anywhere): look for the Mac at once.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Companion.shared.lookNow() }
                }
        }
    }
}

/// A short message about something that just happened. The engine's AndroidHost posts these.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let title: String
    var detail: String?
    var good = true
}
