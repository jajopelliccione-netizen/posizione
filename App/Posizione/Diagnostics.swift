import Foundation
import Darwin

enum Diagnostics {
    /// Elenco delle interfacce di rete e dei loro indirizzi.
    static func interfaces() -> String {
        var out = ""
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "(nessuna)\n" }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let f = p.pointee
            if let addr = f.ifa_addr {
                let fam = Int32(addr.pointee.sa_family)
                if fam == AF_INET || fam == AF_INET6 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        out += "\(String(cString: f.ifa_name)): \(String(cString: host))\n"
                    }
                }
            }
            ptr = f.ifa_next
        }
        return out
    }

    /// Rapporto completo (ci vuole fino a un paio di minuti).
    static func run() async -> String {
        var text = "DIAGNOSTICA\n\nInterfacce di rete:\n" + interfaces() + "\n"
        let found = await Discovery.find(timeout: 5)
        text += "Servizi _remotepairing trovati con Bonjour: \(found.count)\n"
        for f in found { text += "  \(f.host):\(f.port)\n" }
        text += "\n"
        let report: String = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async { c.resume(returning: Engine.probe(hosts: "10.7.0.1,127.0.0.1")) }
        }
        return text + report
    }
}
