// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Network

/// One TCP tunnel from the companion to a port inside Android (adb's 5555), opened from this side.
///
/// The companion asks with a "tunnel" command; this dials back to it, says which session it is for
/// (with the token), connects to the guest port on loopback (QEMU forwards 127.0.0.1:5555 there),
/// and copies bytes both ways until either end closes.
final class Tunnel {
    private static var live: [String: Tunnel] = [:]
    private static let lock = NSLock()

    private let session: String
    private let toMac: NWConnection
    private let toGuest: NWConnection
    private let queue: DispatchQueue
    private var closed = false

    static func open(session: String, host: String, tunnelPort: Int, guestPort: Int, token: String) {
        let t = Tunnel(session: session, host: host, tunnelPort: tunnelPort, guestPort: guestPort)
        lock.lock(); live[session] = t; lock.unlock()
        t.start(token: token)
    }

    private init(session: String, host: String, tunnelPort: Int, guestPort: Int) {
        self.session = session
        queue = DispatchQueue(label: "huskdroid.tunnel.\(session)")
        toMac = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(tunnelPort))!, using: .tcp)
        toGuest = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(guestPort))!, using: .tcp)
    }

    private func start(token: String) {
        HuskLog.log("tunnel", "\(session): opening")
        for c in [toMac, toGuest] {
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let e): self?.close("\(e)")
                case .cancelled: self?.close(nil)
                default: break
                }
            }
            c.start(queue: queue)
        }
        toMac.send(content: Data("\(session) \(token)\n".utf8), completion: .contentProcessed { [weak self] e in
            if let e { self?.close("hello: \(e)") }
        })
        pump(from: toMac, to: toGuest)
        pump(from: toGuest, to: toMac)
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { e in
                    if let e { self.close("send: \(e)") }
                })
            }
            if done || error != nil {
                self.close(error.map { "\($0)" })
                return
            }
            self.pump(from: from, to: to)
        }
    }

    private func close(_ why: String?) {
        guard !closed else { return }
        closed = true
        toMac.cancel()
        toGuest.cancel()
        HuskLog.log("tunnel", "\(session): closed\(why.map { " (\($0))" } ?? "")")
        Tunnel.lock.lock(); Tunnel.live[session] = nil; Tunnel.lock.unlock()
    }
}
