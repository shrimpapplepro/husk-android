// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Emulator-first: Android's screen fills the window; everything else is in the panel the strip pulls down.
struct RootView: View {
    @ObservedObject private var emulator = Emulator.shared
    @ObservedObject private var runner = QemuRunner.shared
    @State private var panelOpen = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if emulator.started {
                // Inside the safe area, below the status strip: nothing of Android's sits under the
                // Dynamic Island or the strip. The view letterboxes to Android's aspect ratio.
                AndroidScreen()
                    .padding(.top, 34)
            } else {
                StartCard(openPanel: { panelOpen = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            StatusStrip(open: $panelOpen)
                .padding(.top, 6)

            if panelOpen {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy) { panelOpen = false } }
                ControlPanel(close: { withAnimation(.snappy) { panelOpen = false } })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 1.2), value: emulator.screenReady)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }
}

/// Android's own screen: the GL surface, or the software display if GL could not start.
struct AndroidScreen: View {
    @ObservedObject private var runner = QemuRunner.shared
    @ObservedObject private var emulator = Emulator.shared

    var body: some View {
        ZStack {
            HuskGLScreen()
            if runner.displayKind == .software {
                HuskDisplay()
            }
            // While Android loads: a live rainbow, screen-blended over Android's picture, so wherever
            // Android draws black the rainbow shows and whatever it draws bright stays on top.
            if !emulator.screenReady {
                LoadingRainbow()
                    .blendMode(.screen)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if runner.isSavingState {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Saving Android…").font(.subheadline.weight(.semibold))
                    Text("So it starts in seconds next time.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)
            } else if runner.bootProgress > 0 && runner.bootProgress < 100 {
                VStack(spacing: 8) {
                    ProgressView(value: Double(runner.bootProgress), total: 100).frame(width: 180)
                    Text(runner.setupMessage ?? "Starting Android…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)
            }
        }
    }
}

/// The small pill at the top: what is on, and the way into the panel.
struct StatusStrip: View {
    @Binding var open: Bool
    @ObservedObject private var jit = JITFlow.shared
    @ObservedObject private var companion = Companion.shared
    @ObservedObject private var emulator = Emulator.shared
    @ObservedObject private var runner = QemuRunner.shared

    var body: some View {
        Button {
            withAnimation(.snappy) { open.toggle() }
        } label: {
            HStack(spacing: 10) {
                dot(jitColor, "JIT")
                dot(androidColor, "Android")
                dot(companionColor, "Mac")
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Status and controls")
    }

    private func dot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.primary)
        }
    }

    private var jitColor: Color {
        switch jit.phase {
        case .on: return .green
        case .failed: return .red
        case .off: return .gray
        default: return .yellow
        }
    }

    private var androidColor: Color {
        if runner.isSavingState { return .yellow }
        if emulator.started { return runner.bootProgress >= 100 || runner.restoredFromSnapshot ? .green : .yellow }
        return .gray
    }

    private var companionColor: Color {
        switch companion.link {
        case .linked: return .green
        case .searching: return .yellow
        case .offline: return .gray
        }
    }
}

/// Before Android runs: download it, get JIT, start it. Each step shows only once the one before is done.
struct StartCard: View {
    let openPanel: () -> Void
    @ObservedObject private var guest = GuestImage.shared
    @ObservedObject private var jit = JITFlow.shared
    @ObservedObject private var emulator = Emulator.shared
    @ObservedObject private var companion = Companion.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "apps.iphone")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("HuskDroid").font(.title2.weight(.semibold))

            switch guest.state {
            case .missing, .failed:
                step("Android isn't downloaded", detail: failure ?? "About 2 GB, once.") {
                    Button("Download Android") { guest.download() }
                }
            case let .downloading(progress, received, total):
                VStack(spacing: 8) {
                    ProgressView(value: progress).frame(width: 220)
                    Text(total > 0 ? "\(mb(received)) of \(mb(total))" : "Starting download…")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            case .installing:
                ProgressView("Preparing Android…")
            case .ready:
                readySteps
            }

            if let message = emulator.message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(28)
        .frame(maxWidth: 360)
    }

    @ViewBuilder private var readySteps: some View {
        switch jit.phase {
        case .on:
            Button {
                emulator.start()
            } label: {
                Label("Start Android", systemImage: "play.fill").frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        case .off, .failed:
            step(jitTitle, detail: jitDetail) {
                Button("Turn On JIT") { jit.request() }
                    .disabled(!companion.isLinked)
            }
        default:
            VStack(spacing: 8) {
                ProgressView()
                Text(jit.steps.last ?? "Asking your Mac…")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var jitTitle: String {
        if case .failed = jit.phase { return "JIT didn't turn on" }
        return "Android needs JIT"
    }

    private var jitDetail: String {
        if case let .failed(why) = jit.phase { return why }
        switch companion.link {
        case .linked(let host): return "Your Mac (\(host)) turns it on over the network."
        case .searching: return "Looking for the companion on your Mac…"
        case .offline(let why): return why + " Is the companion running?"
        }
    }

    private var failure: String? {
        if case let .failed(why) = guest.state { return why }
        return nil
    }

    private func step<B: View>(_ title: String, detail: String, @ViewBuilder button: () -> B) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            button().buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private func mb(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The pulled-down panel: JIT, Android, buttons, files, logs.
struct ControlPanel: View {
    let close: () -> Void
    @ObservedObject private var jit = JITFlow.shared
    @ObservedObject private var emulator = Emulator.shared
    @ObservedObject private var companion = Companion.shared
    @ObservedObject private var runner = QemuRunner.shared
    @State private var importing: ImportKind?
    @State private var showLogs = false
    @State private var busy: String?
    @State private var result: String?

    enum ImportKind: Identifiable { case apk, file; var id: Self { self } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRows
            Divider()
            buttons
            Divider()
            HStack(spacing: 10) {
                panelButton("Install APK", "square.and.arrow.down") { importing = .apk }
                panelButton("Send File", "doc.badge.arrow.up") { importing = .file }
                panelButton("Logs", "text.alignleft") { showLogs = true }
            }
            if let busy {
                HStack(spacing: 8) { ProgressView(); Text(busy).font(.footnote) }
            } else if let result {
                Text(result).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            Text(AppVersion.display)
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 44)
        .frame(maxWidth: 520)
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .apk ? [UTType("com.android.package-archive") ?? .data] : [.item],
                      allowsMultipleSelection: false) { picked in
            let kind = importing
            if case let .success(urls) = picked, let url = urls.first, let kind { bring(url, as: kind) }
        }
        .sheet(isPresented: $showLogs) { LogsView() }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("bolt.fill", "JIT", jitText) {
                if jit.phase != .on {
                    Button(jit.phase.isBusy ? "Working…" : "Turn On") { jit.request() }
                        .disabled(jit.phase.isBusy || !companion.isLinked)
                }
            }
            row("apps.iphone", "Android", androidText) {
                if emulator.started {
                    HStack(spacing: 6) {
                        // Quit without saving: the next start comes back to the last save, storage included.
                        Button("Quit") { emulator.quitWithoutSaving() }
                        Button("Save & Quit", role: .destructive) { emulator.saveAndQuit() }
                    }
                    .disabled(runner.isSavingState)
                } else {
                    Button("Start") { emulator.start(); close() }
                        .disabled(jit.phase != .on || emulator.needsDownload)
                }
            }
            row("desktopcomputer", "Mac", macText) { EmptyView() }
        }
    }

    private var buttons: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 7), spacing: 8) {
            ForEach(SystemKey.allCases) { key in
                Button { key.press() } label: {
                    Image(systemName: key.symbol)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.title)
            }
        }
        .disabled(!emulator.started)
        .opacity(emulator.started ? 1 : 0.4)
    }

    private func row<Trailing: View>(_ icon: String, _ title: String, _ detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            trailing().buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func panelButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var jitText: String {
        switch jit.phase {
        case .off: return "Off"
        case .asking: return "Asking your Mac…"
        case .attaching: return jit.steps.last ?? "Attaching…"
        case .claiming: return "Preparing 512 MB…"
        case .on: return "On for this session"
        case .failed(let why): return why
        }
    }

    private var androidText: String {
        if runner.isSavingState { return "Saving…" }
        if !emulator.started { return emulator.needsDownload ? "Not downloaded" : "Stopped" }
        if runner.restoredFromSnapshot { return "Running (restored)" }
        return runner.bootProgress >= 100 ? "Running" : "Booting \(runner.bootProgress)%"
    }

    private var macText: String {
        switch companion.link {
        case .linked(let host): return "Linked (\(host)) · logs streaming"
        case .searching: return "Looking…"
        case .offline(let why): return why
        }
    }

    /// Copy the picked file out of its security scope, then install or send it in the background.
    private func bring(_ url: URL, as kind: ImportKind) {
        guard emulator.started else { result = "Start Android first."; return }
        let scoped = url.startAccessingSecurityScopedResource()
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: local)
        do { try FileManager.default.copyItem(at: url, to: local) } catch {
            result = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            if scoped { url.stopAccessingSecurityScopedResource() }
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        busy = kind == .apk ? "Installing \(local.lastPathComponent)…" : "Sending \(local.lastPathComponent)…"
        result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let text: String
            do {
                if kind == .apk {
                    let out = try AndroidFiles.install(local)
                    text = out.contains("Success") ? "Installed \(local.lastPathComponent)." : "Install failed: \(out)"
                } else {
                    text = "Sent to \(try AndroidFiles.push(local, into: "/sdcard/Download"))"
                }
            } catch {
                text = "Failed: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: local)
            DispatchQueue.main.async { busy = nil; result = text }
        }
    }
}

/// The app's own log, live: what the companion also receives.
struct LogsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onReceive(timer) { _ in
                    lines = HuskLog.recentLines(600)
                    if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: HuskLog.logFileURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .onAppear { lines = HuskLog.recentLines(600) }
    }
}

/// The loading background: Rainbow.metal's huskRainbow, rendered live every frame.
struct LoadingRainbow: View {
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geo in
                Rectangle()
                    .colorEffect(ShaderLibrary.huskRainbow(
                        .float(Float(context.date.timeIntervalSince(start))),
                        .float2(geo.size)))
            }
        }
        .ignoresSafeArea()
    }
}
