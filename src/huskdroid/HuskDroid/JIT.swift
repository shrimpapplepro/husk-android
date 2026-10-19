// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@_silgen_name("csops")
private func csops(_ pid: Int32, _ ops: Int32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int) -> Int32

/// What the engine needs from JIT: one executable region, claimed while a debugger answers the brk
/// protocol (src/ios-jit/husk-brk.S), then the debugger let go. QEMU's translation buffer comes out
/// of this region (`husk_ios_jit_allocate`), so it must be claimed before Android starts.
enum JITBootstrap {
    /// QEMU's tb-size takes the top of it; claimed once, because a second claim needs a second attach.
    static let jitBytes = 512 * 1024 * 1024

    /// Read by QemuRunner for its memory budget.
    nonisolated(unsafe) static var prewarmed = false

    /// One claim at a time: the debugger answers a single request, so a second caller racing the
    /// first would see its brk go unanswered and report a failure while the region is being held.
    private static let claimLock = NSLock()

    /// Before anything can execute a brk: an unanswered one returns 0 instead of killing the process.
    static func installTrapGuard() { husk_ios_jit_install_trap_handler() }

    /// CS_DEBUGGED: a debugger is attached right now. Costs a syscall, not a trap.
    static var isDebuggerAttached: Bool {
        var flags: UInt32 = 0
        let rc = withUnsafeMutableBytes(of: &flags) { csops(getpid(), 0, $0.baseAddress, $0.count) }
        return rc == 0 && flags & 0x1000_0000 != 0
    }

    /// Take the region and release the debugger. Blocks while the debugger answers, so never on the
    /// main thread (the brk stops the calling thread until the companion has prepared every page).
    static func claim() -> Bool {
        claimLock.lock()
        defer { claimLock.unlock() }
        if prewarmed { return true }
        guard isDebuggerAttached else { return false }
        HuskLog.log("jit", "claiming \(jitBytes >> 20) MiB")
        guard husk_ios_jit_prewarm(jitBytes) else {
            HuskLog.log("jit", "claim FAILED: the debugger did not answer the request")
            return false
        }
        prewarmed = true
        husk_ios_jit_detach()
        HuskLog.log("jit", "region held; debugger released")
        return true
    }
}

/// Getting JIT from the companion, step by step, for the status strip and the panel.
@MainActor
final class JITFlow: ObservableObject {
    static let shared = JITFlow()

    enum Phase: Equatable {
        case off
        case asking          // the companion is reaching the phone
        case attaching       // it is attaching its debugger to this app
        case claiming        // the region is being prepared
        case on
        case failed(String)

        var isBusy: Bool { [.asking, .attaching, .claiming].contains(self) }
    }

    @Published private(set) var phase: Phase = JITBootstrap.prewarmed ? .on : .off
    /// The companion's own words, newest last, for the panel.
    @Published private(set) var steps: [String] = []
    /// Bumped when a request ends, so its attach watcher stops instead of claiming for a later one.
    nonisolated(unsafe) private static var generation = 0

    func request() {
        guard !phase.isBusy else { return }
        if JITBootstrap.prewarmed { phase = .on; return }
        guard Companion.shared.isLinked else {
            phase = .failed("The companion on your Mac isn't reachable.")
            return
        }
        phase = .asking
        steps = []
        HuskLog.log("jit", "asking the companion for JIT")
        let mine = Self.generation

        // The companion attaches over the network; this side only watches for the attach,
        // then claims the region while the debugger is there to answer.
        let waiter = Thread {
            let deadline = Date().addingTimeInterval(90)
            while !JITBootstrap.isDebuggerAttached && Date() < deadline && !JITBootstrap.prewarmed
                    && Self.generation == mine {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard JITBootstrap.isDebuggerAttached, Self.generation == mine else { return }
            Task { @MainActor in self.phase = .claiming }
            let ok = JITBootstrap.claim()
            Task { @MainActor in
                if ok || JITBootstrap.prewarmed { self.phase = .on }
                else if case .claiming = self.phase { self.phase = .failed("The debugger attached but did not answer.") }
            }
        }
        waiter.qualityOfService = .userInitiated
        waiter.start()

        Task {
            do {
                try await Companion.shared.streamJIT(name: ProcessInfo.processInfo.processName) { line in
                    self.steps.append(line)
                    // The stream lags the claim: its lines can arrive after the region is already held,
                    // so they only ever move the phase forward, never back from .claiming or .on.
                    guard !JITBootstrap.prewarmed, self.phase != .on, self.phase != .claiming else { return }
                    if line.hasPrefix("ERROR:") { self.phase = .failed(String(line.dropFirst(7))) }
                    else if line.hasPrefix("connecting") || line.hasPrefix("attached") { self.phase = .attaching }
                }
            } catch {
                if !JITBootstrap.prewarmed { phase = .failed(error.localizedDescription) }
            }
            // The region is the truth, whatever the stream said last.
            if !JITBootstrap.prewarmed && !JITBootstrap.isDebuggerAttached { Self.generation += 1 }
            if JITBootstrap.prewarmed { phase = .on }
            else if phase.isBusy { phase = .failed(steps.last ?? "The companion stopped before JIT was on.") }
        }
    }
}
