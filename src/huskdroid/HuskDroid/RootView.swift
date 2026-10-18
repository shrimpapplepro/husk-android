// SPDX-License-Identifier: GPL-2.0-or-later
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Emulator-first: Android's screen fills the window; everything else is in the panel the strip pulls down.
struct RootView: View {
    @ObservedObject private var emulator = Emulator.shared
    @ObservedObject private var runner = QemuRunner.shared
    @State private var panelOpen = false
    @Namespace private var glass

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

            if panelOpen {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture { toggle() }
                    .transition(.opacity)
            }

            // The pill and the panel are one piece of glass: opening morphs the pill into the panel.
            GlassEffectContainer(spacing: 24) {
                if panelOpen {
                    ControlPanel(close: toggle)
                        .glassEffect(.regular, in: .rect(cornerRadius: 30))
                        .glassEffectID("chrome", in: glass)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: 520)
                } else {
                    StatusStrip(open: panelOpen, toggle: toggle)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .glassEffectID("chrome", in: glass)
                }
            }
            .padding(.top, 6)
        }
        .animation(.easeInOut(duration: 1.2), value: emulator.screenReady)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private func toggle() {
        withAnimation(.bouncy(duration: 0.45)) { panelOpen.toggle() }
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
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .allowsHitTesting(false)
            } else if runner.bootProgress > 0 && runner.bootProgress < 100 {
                VStack(spacing: 8) {
                    ProgressView(value: Double(runner.bootProgress), total: 100).frame(width: 180)
                    Text(runner.setupMessage ?? "Starting Android…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .allowsHitTesting(false)
            }
        }
    }
}

/// The small pill at the top: what is on, and the way into the panel.
struct StatusStrip: View {
    let open: Bool
    let toggle: () -> Void
    @ObservedObject private var jit = JITFlow.shared
    @ObservedObject private var companion = Companion.shared
    @ObservedObject private var emulator = Emulator.shared
    @ObservedObject private var runner = QemuRunner.shared

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                dot(jitColor, "JIT")
                dot(androidColor, "Android")
                dot(companionColor, "Mac")
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Close controls" : "Status and controls")
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
            .buttonStyle(.glassProminent).controlSize(.large)
        case .off, .failed:
            step(jitTitle, detail: jitDetail) {
                Button("Turn On JIT") { jit.request() }
                    .disabled(!companion.isLinked)
            }
            if offerTailscale {
                Button { Tailscale.open() } label: {
                    Label("Open Tailscale", systemImage: "network")
                }
                .buttonStyle(.glass)
            }
        default:
            VStack(spacing: 8) {
                ProgressView()
                Text(jit.steps.last ?? "Asking your Mac over \(companion.route ?? "the network")…")
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
        case .linked(let host): return "Your Mac (\(host)) turns it on over \(companion.route ?? "the network")."
        case .searching: return "Looking for the companion on your Mac…"
        case .offline(let why):
            return why + (companion.triesTailscale ? " Is the companion running, and Tailscale connected here?"
                                                   : " Is the companion running?")
        }
    }

    /// Away from home the Mac is usually only a Tailscale hop away: offer the switch when it can't be reached.
    private var offerTailscale: Bool {
        guard companion.triesTailscale else { return false }
        if case .offline = companion.link { return true }
        if case let .failed(why) = jit.phase { return why.contains("reachable") }
        return false
    }

    private var failure: String? {
        if case let .failed(why) = guest.state { return why }
        return nil
    }

    private func step<B: View>(_ title: String, detail: String, @ViewBuilder button: () -> B) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            button().buttonStyle(.glassProminent).controlSize(.large)
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
    @ObservedObject private var transfers = Transfers.shared
    @State private var importing: ImportKind?
    @State private var showLogs = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []

    enum ImportKind: Identifiable { case apk, files; var id: Self { self } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusStrip(open: true, toggle: close)
                .frame(maxWidth: .infinity)
            statusRows
            Divider()
            buttons
            Divider()
            HStack(spacing: 10) {
                panelButton("Install APK", "square.and.arrow.down") { importing = .apk }
                Menu {
                    Button { showPhotos = true } label: { Label("Photos & Videos", systemImage: "photo.on.rectangle") }
                    Button { importing = .files } label: { Label("Files", systemImage: "folder") }
                } label: {
                    panelLabel("Send to Android", "square.and.arrow.up.on.square")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                panelButton("Logs", "text.alignleft") { showLogs = true }
            }
            if let busy = transfers.busy {
                HStack(spacing: 8) { ProgressView(); Text(busy).font(.footnote) }
            } else if let result = transfers.result {
                Text(result).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
            Text(AppVersion.display)
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 18)
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
                      allowedContentTypes: importing == .apk ? [UTType("com.android.package-archive") ?? .data] : [.item],
                      allowsMultipleSelection: importing == .files) { picked in
            let kind = importing
            guard case let .success(urls) = picked else { return }
            transfers.send(urls, securityScoped: true, install: kind == .apk)
        }
        // Compatible encoding: JPEG and H.264 rather than HEIC/HEVC, which not every Android app opens.
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 30,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                var urls: [URL] = []
                for item in items {
                    if let picked = try? await item.loadTransferable(type: PickedMedia.self) { urls.append(picked.url) }
                    else { HuskLog.log("files", "could not load a picked photo/video (\(item.supportedContentTypes.map(\.identifier)))") }
                }
                transfers.send(urls, securityScoped: false)
            }
        }
        .sheet(isPresented: $showLogs) { LogsView() }
    }

    private var statusRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("bolt.fill", "JIT", jitText) {
                if jit.phase != .on {
                    if !companion.isLinked, companion.triesTailscale {
                        Button("Open Tailscale") { Tailscale.open() }
                    } else {
                        Button(jit.phase.isBusy ? "Working…" : "Turn On") { jit.request() }
                            .disabled(jit.phase.isBusy || !companion.isLinked)
                    }
                }
            }
            row("apps.iphone", "Android", androidText) {
                if emulator.started {
                    // The only way out: closing always keeps the session.
                    Button("Save & Quit", role: .destructive) { emulator.saveAndQuit() }
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
        // A plain row, not a lazy grid: lazy items are laid out late and animated in from nowhere.
        HStack(spacing: 6) {
            ForEach(SystemKey.allCases) { key in
                Button { key.press() } label: { keyLabel(key.symbol) }
                    .accessibilityLabel(key.title)
            }
            Button { Rotation.toggle(); close() } label: {
                keyLabel(Rotation.landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
            }
            .accessibilityLabel(Rotation.landscape ? "Portrait" : "Landscape")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .disabled(!emulator.started)
        .opacity(emulator.started ? 1 : 0.4)
    }

    private func keyLabel(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 30)
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
            trailing().buttonStyle(.glass).controlSize(.small)
        }
    }

    private func panelButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { panelLabel(title, icon) }
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 16))
    }

    private func panelLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
    }

    private var jitText: String {
        switch jit.phase {
        case .off: return "Off"
        case .asking: return "Asking your Mac over \(companion.route ?? "the network")…"
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
        case .linked(let host): return "Linked over \(companion.route ?? "?") (\(host)) · logs streaming"
        case .searching: return "Looking…"
        case .offline(let why): return why
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

/// A photo or video from the Photos picker, as a file of its own (with its original name) in tmp.
struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try PickedMedia(copying: received.file) }
        FileRepresentation(importedContentType: .image) { received in try PickedMedia(copying: received.file) }
    }

    init(copying file: URL) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: url)
    }
}
