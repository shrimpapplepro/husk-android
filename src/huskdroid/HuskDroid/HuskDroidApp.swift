// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

final class HuskDroidDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        [.portrait, .landscapeLeft, .landscapeRight]
    }
}

@main
struct HuskDroidApp: App {
    @UIApplicationDelegateAdaptor(HuskDroidDelegate.self) private var delegate
    @ObservedObject private var companion = Companion.shared

    init() {
        Emulator.shared.prepare()
        Companion.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Ask for JIT as soon as the Mac answers: by the time Android is downloaded or
                // the panel is opened, it is already on.
                .onChange(of: companion.isLinked) { _, linked in
                    if linked, !JITBootstrap.prewarmed, JITFlow.shared.phase == .off { JITFlow.shared.request() }
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
