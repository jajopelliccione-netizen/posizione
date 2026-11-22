import Foundation
import CoreLocation

/// Dopo la simulazione sveglia il GPS vero, così iOS ritrova la tua posizione più in fretta.
final class RealLocation: NSObject, CLLocationManagerDelegate {
    static let shared = RealLocation()
    private let manager = CLLocationManager()
    private var stopWork: DispatchWorkItem?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Chiede il permesso (una sola volta) mentre sei connesso.
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Chiede la posizione per qualche decina di secondi, poi smette.
    func refresh(seconds: TimeInterval = 45) {
        manager.startUpdatingLocation()
        stopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.manager.stopUpdatingLocation() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
