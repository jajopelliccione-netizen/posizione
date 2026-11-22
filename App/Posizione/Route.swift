import Foundation
import MapKit

/// Percorso calcolato: punti + distanza cumulativa in metri.
struct PlannedRoute {
    var coords: [CLLocationCoordinate2D]
    var cumulative: [Double]
    var isStraightLine = false
    /// Distanza (m dalla partenza) di ogni tappa intermedia.
    var stopDistances: [Double] = []
    /// Tempo di percorrenza stimato da Mappe, in secondi (senza soste).
    var expectedTime: Double = 0

    var total: Double { cumulative.last ?? 0 }

    init(coords: [CLLocationCoordinate2D], stopIndices: [Int] = [], expectedTime: Double = 0,
         isStraightLine: Bool = false) {
        self.coords = coords
        self.isStraightLine = isStraightLine
        self.expectedTime = expectedTime
        var cum: [Double] = [0]
        if coords.count > 1 {
            for i in 1..<coords.count {
                let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                cum.append(cum[i - 1] + a.distance(from: b))
            }
        }
        self.cumulative = cum
        self.stopDistances = stopIndices.map { $0 < cum.count ? cum[$0] : (cum.last ?? 0) }
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
    /// Calcola il percorso passando per tutti i punti (partenza, tappe, arrivo).
    /// Per ogni tratto senza strada usa la linea retta.
    static func plan(points: [CLLocationCoordinate2D], walking: Bool) async -> PlannedRoute {
        var all: [CLLocationCoordinate2D] = []
        var stopIndices: [Int] = []
        var expected = 0.0
        var straight = false
        let fallbackSpeed = walking ? 1.4 : 11.0

        for i in 0..<max(points.count - 1, 0) {
            let from = points[i]
            let to = points[i + 1]
            var leg: [CLLocationCoordinate2D] = []
            var legTime = 0.0

            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
            req.transportType = walking ? .walking : .automobile
            if let resp = try? await MKDirections(request: req).calculate(),
               let route = resp.routes.first, route.polyline.pointCount > 1 {
                let n = route.polyline.pointCount
                let pts = route.polyline.points()
                for k in 0..<n { leg.append(pts[k].coordinate) }
                legTime = route.expectedTravelTime
            } else {
                leg = [from, to]
                straight = true
                let d = CLLocation(latitude: from.latitude, longitude: from.longitude)
                    .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
                legTime = d / fallbackSpeed
            }
            if all.isEmpty { all = leg } else { all.append(contentsOf: leg.dropFirst()) }
            expected += legTime
            if i < points.count - 2 { stopIndices.append(all.count - 1) }
        }
        if all.count < 2, let f = points.first { all = [f, f] }
        return PlannedRoute(coords: all, stopIndices: stopIndices, expectedTime: expected,
                            isStraightLine: straight)
    }
}

enum RouteEvent {
    case reachedStop(Int)   // arrivato a una tappa con sosta
    case leftStop(Int)      // la sosta è finita, si riparte
}

/// Fa avanzare la posizione simulata lungo il percorso, una volta al secondo.
@MainActor
final class RouteRunner: ObservableObject {
    @Published var route: PlannedRoute?
    @Published var traveled: Double = 0
    @Published var running = false
    @Published var current: CLLocationCoordinate2D?
    /// Secondi di sosta rimasti (0 = in movimento).
    @Published var waiting: Double = 0

    /// Velocita in metri al secondo (aggiornata dalla schermata).
    var speedMps: Double = 1.4
    /// Durata (secondi) della sosta in ogni tappa, nello stesso ordine delle tappe.
    var pauses: [Double] = []
    private var nextStop = 0
    var onError: ((String) -> Void)?
    var onFinished: (() -> Void)?
    var onEvent: ((RouteEvent) -> Void)?
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
        waiting = 0
        nextStop = 0
    }

    func start() {
        guard let route, !running else { return }
        if traveled >= route.total { traveled = 0; nextStop = 0; waiting = 0 }
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
                if self.waiting > 0 {
                    // sosta: la posizione resta ferma
                    self.waiting = max(0, self.waiting - dt)
                    self.pushPosition()
                    if self.waiting == 0 { self.onEvent?(.leftStop(self.nextStop - 1)) }
                    continue
                }
                var newTravel = min(self.traveled + self.speedMps * dt, route.total)
                if self.nextStop < route.stopDistances.count,
                   newTravel >= route.stopDistances[self.nextStop] {
                    newTravel = route.stopDistances[self.nextStop]
                    let p = self.nextStop < self.pauses.count ? self.pauses[self.nextStop] : 0
                    self.nextStop += 1
                    self.waiting = p
                    if p > 0 { self.onEvent?(.reachedStop(self.nextStop - 1)) }
                }
                self.traveled = newTravel
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
