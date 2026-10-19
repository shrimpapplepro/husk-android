// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import UIKit

/// The link to the companion on the Mac (tools/companion). This side opens every connection:
/// JIT requests, the log stream, and a long-poll for remote commands.
@MainActor
final class Companion: ObservableObject {
    static let shared = Companion()

    enum Link: Equatable {
        case searching
        case linked(String)
        case offline(String)
    }

    @Published private(set) var link: Link = .searching
    var isLinked: Bool { if case .linked = link { return true }; return false }
    /// How the companion is reached right now, for the UI: "Tailscale" or "Wi-Fi".
    var route: String? { base.map(Tailscale.route) }
    /// Whether any configured address of the Mac goes through Tailscale.
    var triesTailscale: Bool { bases.contains { Tailscale.carries($0.host ?? "") } }
    /// The companion's host, for connections that are not HTTP (tunnels dial back to it).
    var host: String? { base?.host }
    var tunnelToken: String { token }

    private let token = Bundle.main.object(forInfoDictionaryKey: "HDCompanionToken") as? String ?? ""
    /// "host:port,host:port,https://name.ts.net/huskdroid" from config/local.env (HUSKDROID_MAC_HOSTS),
    /// tried in order. A bare host:port is plain HTTP; a full URL (a Tailscale Funnel) keeps its path.
    private let bases: [URL] = (Bundle.main.object(forInfoDictionaryKey: "HDCompanionHosts") as? String ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .compactMap { URL(string: $0.contains("://") ? $0 : "http://\($0)") }
    private var base: URL?
    /// Bumped on every new link. A command loop belongs to one link: its long-poll can outlive a drop,
    /// and finishing after the relink it would either run beside the new loop or drop the new link.
    private var linkID = 0
    private var started = false
    private var lookSoon = false
    private let shipper = LogShipper()

    /// Short requests: status, hello, logs, results.
    private lazy var quick: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    /// Long ones: the JIT stream and the command long-poll.
    private lazy var slow: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 150
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    func start() {
        guard !started else { return }
        started = true
        HuskLog.log("companion", "Tailscale button: \(Tailscale.how)")
        Task { await self.maintain() }
    }

    /// Look for the Mac now rather than at the next 10 s tick: back from the Tailscale app, or in the foreground again.
    func lookNow() {
        if base == nil { lookSoon = true }
    }

    /// Find the companion, then keep the command loop and log shipping running; look again if it goes away.
    private func maintain() async {
        while true {
            if base == nil {
                link = .searching
                if let found = await findHost() {
                    base = found
                    link = .linked(found.host ?? "?")
                    HuskLog.log("companion", "linked to \(found.absoluteString) over \(route ?? "?")")
                    linkID += 1
                    let id = linkID
                    await hello()
                    shipper.start { [weak self] text in await self?.post("/v1/logs", body: Data(text.utf8), type: "text/plain") ?? false }
                    Task { await self.commandLoop(link: id) }
                } else {
                    link = .offline(token.isEmpty ? "This build has no companion token." : "Not reachable on Wi-Fi or Tailscale.")
                }
            }
            // In half-second steps, so lookNow() is answered within one.
            for _ in 0..<(base == nil ? 20 : 10) where !lookSoon {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            lookSoon = false
        }
    }

    private func findHost() async -> URL? {
        guard !token.isEmpty else { return nil }
        for url in bases {
            var req = URLRequest(url: url.appendingPathComponent("v1/status"))
            authorise(&req)
            // A Funnel goes out to Tailscale's relay and back: about 1.7 s, against milliseconds at home.
            req.timeoutInterval = url.scheme == "https" ? 5 : 2.5
            if let (_, resp) = try? await quick.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
                return url
            }
        }
        return nil
    }

    private func dropLink(_ why: String) {
        guard base != nil else { return }
        HuskLog.log("companion", "link lost: \(why)")
        base = nil
        shipper.stop()
        link = .offline(why)
    }

    private func authorise(_ req: inout URLRequest) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, type: String? = nil) -> URLRequest? {
        // Appended, not resolved: resolving "/v1/..." against a Funnel URL would drop its /huskdroid prefix.
        let root = base?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let root, let url = URL(string: root + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let type { req.setValue(type, forHTTPHeaderField: "Content-Type") }
        authorise(&req)
        return req
    }

    @discardableResult
    func post(_ path: String, body: Data, type: String = "application/json") async -> Bool {
        guard let req = request(path, method: "POST", body: body, type: type) else { return false }
        do {
            let (_, resp) = try await quick.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 500) < 300
        } catch {
            dropLink(error.localizedDescription)
            return false
        }
    }

    private func hello() async {
        let info: [String: Any] = [
            "device": UIDevice.current.name,
            "ios": UIDevice.current.systemVersion,
            "app": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            "jit": JITBootstrap.prewarmed,
            "android": QemuRunner.shared.isRunning,
        ]
        await post("/v1/hello", body: (try? JSONSerialization.data(withJSONObject: info)) ?? Data())
    }

    /// Ask for JIT and pass each line of the companion's progress to `onLine`. Returns when it is done.
    func streamJIT(name: String, onLine: @escaping @MainActor (String) -> Void) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        guard let req = request("/v1/jit", method: "POST", body: body, type: "application/json") else {
            throw URLError(.cannotConnectToHost)
        }
        let (bytes, _) = try await slow.bytes(for: req)
        for try await line in bytes.lines {
            onLine(line)
        }
    }

    /// Long-poll for commands and run each one. Ends when its link drops; maintain() starts another.
    private func commandLoop(link: Int) async {
        while base != nil && linkID == link {
            guard let req = request("/v1/next?wait=25") else { return }
            do {
                let (data, resp) = try await slow.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200,
                      let cmd = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = cmd["id"] as? String else { continue }
                Task.detached(priority: .userInitiated) {
                    let reply = await RemoteCommands.run(cmd)
                    await self.post("/v1/result/\(id)", body: reply.body, type: reply.type)
                    await MainActor.run { reply.after?() }
                }
            } catch {
                if linkID == link { dropLink(error.localizedDescription) }
                return
            }
        }
    }

    /// Where a staged file (huskctl install/push) is fetched from.
    func stagedFileURL(_ name: String) -> URLRequest? {
        guard let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return request("/v1/files/\(escaped)")
    }

    func download(_ req: URLRequest) async throws -> URL {
        let (tmp, resp) = try await slow.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        return tmp
    }
}

/// Ships new lines of the app's own log files to the companion, once a second.
/// Reading the files (rather than hooking HuskLog) also catches QEMU's stderr in husk-native.log.
final class LogShipper {
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private let queue = DispatchQueue(label: "huskdroid.logs")

    private var files: [(path: String, tag: String)] {
        let docs = HuskLog.logFileURL.deletingLastPathComponent()
        return [(HuskLog.logFileURL.path, ""),
                (docs.appendingPathComponent("husk-native.log").path, "native| ")]
    }

    func start(send: @escaping (String) async -> Bool) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var out = ""
            var reached: [String: UInt64] = [:]
            for f in self.files {
                let (text, end) = self.newLines(f.path, tag: f.tag)
                out += text
                if let end { reached[f.path] = end }
            }
            guard !out.isEmpty else { return }
            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var delivered = false
            Task { delivered = await send(out); sem.signal() }
            sem.wait()
            // Undelivered lines are sent again next time rather than skipped.
            if delivered { self.offsets.merge(reached) { $1 } }
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// The whole lines after what was last delivered, and the offset they end at.
    private func newLines(_ path: String, tag: String) -> (String, UInt64?) {
        guard let h = FileHandle(forReadingAtPath: path) else { return ("", nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var from = offsets[path] ?? max(0, size > 64_000 ? size - 64_000 : 0)
        if size < from { from = 0 }   // a new run truncated the file
        guard size > from else { return ("", nil) }
        try? h.seek(toOffset: from)
        let data = (try? h.read(upToCount: Int(min(size - from, 512_000)))) ?? Data()
        // Only whole lines; the rest waits for the next tick.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ("", nil) }
        let text = String(decoding: data[..<(lastNewline + 1)], as: UTF8.self)
        return (tag.isEmpty ? text : text.split(separator: "\n").map { tag + $0 + "\n" }.joined(),
                from + UInt64(lastNewline + 1))
    }
}

/// The usual way to the Mac away from the home Wi-Fi. JIT needs it on both ways: the companion reaches
/// the phone's Tailscale address, and the app reaches the Mac's.
enum Tailscale {
    /// Tailscale hands out addresses in 100.64.0.0/10 and MagicDNS names under .ts.net.
    static func carries(_ host: String) -> Bool {
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func route(_ url: URL) -> String {
        guard let host = url.host, carries(host) else { return "Wi-Fi" }
        return url.scheme == "https" ? "Tailscale Funnel" : "Tailscale"
    }

    /// The Mac app answers tailscale://; what the iOS app registers is not documented, so the app
    /// tries each (all listed in LSApplicationQueriesSchemes) and logs the one that works.
    private static let schemes = ["tailscale", "io.tailscale.ipn.ios", "io.tailscale.ipn"]
    /// Tailscale's App Store page (io.tailscale.ipn.ios): it always opens, and shows Open when installed.
    private static let store = URL(string: "itms-apps://apps.apple.com/app/id1470499037")!

    @MainActor private static var direct: URL? {
        schemes.lazy.compactMap { URL(string: "\($0)://") }.first { UIApplication.shared.canOpenURL($0) }
    }

    /// For the log: how the button will get to Tailscale.
    @MainActor static var how: String { direct.map { "opens \($0.absoluteString)" } ?? "no URL scheme answers; opens its App Store page" }

    @MainActor static func open() {
        let url = direct ?? store
        UIApplication.shared.open(url) { ok in HuskLog.log("companion", "opening Tailscale (\(url.absoluteString)): \(ok ? "OK" : "FAILED")") }
    }
}
