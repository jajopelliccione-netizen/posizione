import Foundation
import MapKit

/// Percorso calcolato: punti + distanza cumulativa in metri.
struct PlannedRoute {
    var coords: [CLLocationCoordinate2D]
    var cumulative: [Double]
    var isStraightLine = false

    var total: Double { cumulative.last ?? 0 }

    init(coords: [CLLocationCoordinate2D], isStraightLine: Bool = false) {
        self.coords = coords
        self.isStraightLine = isStraightLine
        var cum: [Double] = [0]
        if coords.count > 1 {
            for i in 1..<coords.count {
                let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                cum.append(cum[i - 1] + a.distance(from: b))
            }
        }
        self.cumulative = cum
    }

    /// Posizione dopo aver percorso `d` metri.
    func position(at d: Double) -> CLLocationCoordinate2D {
        guard coords.count > 1 else { return coords.first ?? CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let dist = min(max(d, 0), total)
        var i = 1
        while i < cumulative.count - 1 && cumulative[i] < dist { i += 1 }
        let d0 = cumulative[i - 1]
        let d1 = cumulative[i]
        let t = d1 > d0 ? (dist - d0) / (d1 - d0) : 0
        let a = coords[i - 1]
        let b = coords[i]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}

enum Planner {
    /// Calcola il percorso con Mappe. Se non esiste (es. mare) usa la linea retta.
    static func plan(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, walking: Bool) async -> PlannedRoute {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = walking ? .walking : .automobile
        do {
            let resp = try await MKDirections(request: req).calculate()
            if let route = resp.routes.first {
                let n = route.polyline.pointCount
                let pts = route.polyline.points()
                var coords: [CLLocationCoordinate2D] = []
                for i in 0..<n { coords.append(pts[i].coordinate) }
                if coords.count > 1 { return PlannedRoute(coords: coords) }
            }
        } catch {}
        return PlannedRoute(coords: [from, to], isStraightLine: true)
    }
}

/// Fa avanzare la posizione simulata lungo il percorso, una volta al secondo.
@MainActor
final class RouteRunner: ObservableObject {
    @Published var route: PlannedRoute?
    @Published var traveled: Double = 0
    @Published var running = false
    @Published var current: CLLocationCoordinate2D?

    /// Velocita in metri al secondo (aggiornata dalla schermata).
    var speedMps: Double = 1.4
    var onError: ((String) -> Void)?
    var onFinished: (() -> Void)?
    private var task: Task<Void, Never>?

    var progress: Double {
        guard let r = route, r.total > 0 else { return 0 }
        return min(traveled / r.total, 1)
    }

    func setRoute(_ r: PlannedRoute?) {
        stop()
        route = r
        traveled = 0
        current = nil
    }

    func start() {
        guard let route, !running else { return }
        if traveled >= route.total { traveled = 0 }
        running = true
        pushPosition()
        task = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                self.traveled = min(self.traveled + self.speedMps * dt, route.total)
                self.pushPosition()
                if self.traveled >= route.total {
                    self.running = false
                    self.onFinished?()
                    return
                }
            }
        }
    }

    func pause() {
        running = false
        task?.cancel()
        task = nil
    }

    func stop() { pause() }

    private func pushPosition() {
        guard let route else { return }
        let p = route.position(at: traveled)
        current = p
        if let err = Engine.set(lat: p.latitude, lon: p.longitude) { onError?(err) }
    }
}

func formatDistance(_ m: Double) -> String {
    m >= 1000 ? String(format: "%.1f km", m / 1000) : String(format: "%.0f m", m)
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    let h = t / 3600
    let m = (t % 3600) / 60
    let sec = t % 60
    if h > 0 { return "\(h) h \(m) min" }
    if m > 0 { return "\(m) min \(sec) s" }
    return "\(sec) s"
}
