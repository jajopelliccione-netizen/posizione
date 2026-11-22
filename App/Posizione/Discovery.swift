import Foundation
import Network

/// Cerca il servizio _remotepairing._tcp dell'iPhone e ne ricava indirizzo e porta.
enum Discovery {
    struct Found { let host: String; let port: UInt16 }

    static func find(timeout: TimeInterval = 6) async -> [Found] {
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: nil), using: .tcp)
        var endpoints: [NWEndpoint] = []
        browser.browseResultsChangedHandler = { results, _ in
            endpoints = results.map { $0.endpoint }
        }
        browser.start(queue: .global())
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        browser.cancel()

        var out: [Found] = []
        for ep in endpoints {
            if let f = await resolve(ep) { out.append(f) }
        }
        return out
    }

    private static func resolve(_ ep: NWEndpoint) async -> Found? {
        await withCheckedContinuation { cont in
            let conn = NWConnection(to: ep, using: .tcp)
            var done = false
            func finish(_ f: Found?) {
                if done { return }
                done = true
                conn.cancel()
                cont.resume(returning: f)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let i = h.firstIndex(of: "%"), h.hasPrefix("fe80") { _ = i } // tengo la zona (es. %en0)
                        finish(Found(host: h, port: port.rawValue))
                    } else { finish(nil) }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }
}
