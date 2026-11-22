import Foundation
import MapKit

/// Suggerimenti di ricerca mentre scrivi (negozi, vie, luoghi), come nelle app di mappe.
final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    var region: MKCoordinateRegion {
        get { completer.region }
        set { completer.region = newValue }
    }

    func update(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            results = []
        } else {
            completer.queryFragment = t
        }
    }

    func clear() {
        results = []
        completer.queryFragment = ""
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = completer.results
        DispatchQueue.main.async { self.results = r }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async { self.results = [] }
    }
}
