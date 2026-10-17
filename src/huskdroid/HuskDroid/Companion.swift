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

    private let token = Bundle.main.object(forInfoDictionaryKey: "HDCompanionToken") as? String ?? ""
    private let hosts = Bundle.main.object(forInfoDictionaryKey: "HDCompanionHosts") as? [String] ?? []
    private var base: URL?
    private var started = false
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
        Task { await self.maintain() }
    }

    /// Find the companion, then keep the command loop and log shipping running; look again if it goes away.
    private func maintain() async {
        while true {
            if base == nil {
                link = .searching
                if let found = await findHost() {
                    base = found
                    link = .linked(found.host ?? "?")
                    HuskLog.log("companion", "linked to \(found.absoluteString)")
                    await hello()
                    shipper.start { [weak self] text in await self?.post("/v1/logs", body: Data(text.utf8), type: "text/plain") ?? false }
                    Task { await self.commandLoop() }
                } else {
                    link = .offline(token.isEmpty ? "This build has no companion token." : "Not reachable on Wi-Fi or Tailscale.")
                }
            }
            try? await Task.sleep(nanoseconds: base == nil ? 10_000_000_000 : 5_000_000_000)
        }
    }

    private func findHost() async -> URL? {
        guard !token.isEmpty else { return nil }
        for host in hosts {
            guard let url = URL(string: "http://\(host)") else { continue }
            var req = URLRequest(url: url.appendingPathComponent("v1/status"))
            authorise(&req)
            req.timeoutInterval = 2.5
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
        guard let base, let url = URL(string: path, relativeTo: base) else { return nil }
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

    /// Long-poll for commands and run each one. Ends when the link drops; maintain() starts another.
    private func commandLoop() async {
        while base != nil {
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
                dropLink(error.localizedDescription)
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
            for f in self.files { out += self.newLines(f.path, tag: f.tag) }
            guard !out.isEmpty else { return }
            let sem = DispatchSemaphore(value: 0)
            Task { _ = await send(out); sem.signal() }
            sem.wait()
        }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func newLines(_ path: String, tag: String) -> String {
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var from = offsets[path] ?? max(0, size > 64_000 ? size - 64_000 : 0)
        if size < from { from = 0 }   // a new run truncated the file
        guard size > from else { return "" }
        try? h.seek(toOffset: from)
        let data = (try? h.read(upToCount: Int(min(size - from, 512_000)))) ?? Data()
        // Only whole lines; the rest waits for the next tick.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return "" }
        offsets[path] = from + UInt64(lastNewline + 1)
        let text = String(decoding: data[..<(lastNewline + 1)], as: UTF8.self)
        return tag.isEmpty ? text : text.split(separator: "\n").map { tag + $0 + "\n" }.joined()
    }
}
