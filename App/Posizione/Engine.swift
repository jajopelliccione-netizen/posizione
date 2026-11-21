import Foundation

enum Engine {
    static func lastError() -> String {
        guard let p = ll_last_error() else { return "" }
        defer { ll_free_string(p) }
        return String(cString: p)
    }
    /// nil = ok, altrimenti messaggio di errore
    static func connect(pairingPath: String) -> String? {
        ll_connect(pairingPath) == 0 ? nil : lastError()
    }
    static func set(lat: Double, lon: Double) -> String? {
        ll_set_location(lat, lon) == 0 ? nil : lastError()
    }
    static func clear() { _ = ll_clear_location() }
    static func disconnect() { ll_disconnect() }
}
