import SwiftUI
import MapKit

struct Favorite: Codable, Identifiable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
}

struct ContentView: View {
    @State private var camera: MapCameraPosition = .automatic
    @State private var picked: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var status = "Non connesso"
    @State private var connected = false
    @State private var simulating = false
    @State private var busy = false
    @State private var showImporter = false
    @State private var favorites: [Favorite] = {
        guard let d = UserDefaults.standard.data(forKey: "favs"),
              let f = try? JSONDecoder().decode([Favorite].self, from: d) else { return [] }
        return f
    }()

    private var pairingURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pairing.plist")
    }
    private var hasPairing: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Cerca un luogo…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit(search)
                Button("Cerca", action: search).buttonStyle(.bordered)
            }.padding(8)

            MapReader { proxy in
                Map(position: $camera) {
                    if let c = picked { Marker("Posizione scelta", coordinate: c).tint(.red) }
                }
                .onTapGesture { pt in
                    if let c = proxy.convert(pt, from: .local) { picked = c }
                }
            }

            VStack(spacing: 8) {
                Text(status).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let c = picked {
                    Text(String(format: "%.5f, %.5f", c.latitude, c.longitude)).font(.caption.monospaced())
                }
                if !hasPairing {
                    Button("Importa file di pairing") { showImporter = true }.buttonStyle(.borderedProminent)
                } else if !connected {
                    Button(busy ? "Connessione…" : "Connetti (LocalDevVPN attiva)", action: connect)
                        .buttonStyle(.borderedProminent).disabled(busy)
                } else {
                    HStack {
                        Button("Imposta posizione", action: apply)
                            .buttonStyle(.borderedProminent).disabled(picked == nil)
                        Button("Posizione reale", action: stop).buttonStyle(.bordered).tint(.red)
                    }
                }
                HStack {
                    Button("Salva preferito", action: saveFav).disabled(picked == nil)
                    if hasPairing { Button("Cambia pairing") { showImporter = true } }
                }.font(.footnote)
                if !favorites.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(favorites) { f in
                                Button(f.name) { pick(f) }
                                    .buttonStyle(.bordered)
                                    .contextMenu { Button("Elimina", role: .destructive) { remove(f) } }
                            }
                        }
                    }
                }
            }.padding(8).background(.bar)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.removeItem(at: pairingURL)
            do {
                try FileManager.default.copyItem(at: url, to: pairingURL)
                status = "Pairing importato. Ora premi Connetti."
            } catch { status = "Import fallito: \(error.localizedDescription)" }
        }
    }

    func connect() {
        busy = true; status = "Cerco il telefono in rete…"
        let path = pairingURL.path
        Task {
            let found = await Discovery.find()
            guard !found.isEmpty else {
                await MainActor.run {
                    busy = false
                    status = "Servizio non trovato. Controlla Rete locale (Impostazioni > Posizione), Wi-Fi acceso e Modalita sviluppatore."
                }
                return
            }
            var candidates: [(String, UInt16)] = []
            for f in found { candidates.append((f.host, f.port)); candidates.append(("10.7.0.1", f.port)) }
            var errors: [String] = []
            for (h, p) in candidates {
                await MainActor.run { status = "Connessione a \(h):\(p)…" }
                let err = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                    DispatchQueue.global().async { c.resume(returning: Engine.connectRP(pairingPath: path, host: h, port: p)) }
                }
                if err == nil {
                    await MainActor.run { busy = false; connected = true; status = "Connesso. Tocca la mappa e premi Imposta posizione." }
                    return
                }
                errors.append("\(h):\(p) -> \(err!)")
            }
            await MainActor.run {
                busy = false; connected = false
                status = "Errore: " + errors.joined(separator: "\n")
            }
        }
    }

    func apply() {
        guard let c = picked else { return }
        if let err = Engine.set(lat: c.latitude, lon: c.longitude) { status = "Errore: \(err)" }
        else { simulating = true; status = "Posizione simulata attiva. Tieni LocalDevVPN e l'app aperti." }
    }

    func stop() {
        Engine.clear(); Engine.disconnect()
        connected = false; simulating = false
        status = "Posizione reale ripristinata."
    }

    func search() {
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = query
        MKLocalSearch(request: req).start { resp, _ in
            guard let item = resp?.mapItems.first else { status = "Nessun risultato"; return }
            let c = item.placemark.coordinate
            picked = c
            camera = .region(MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        }
    }

    func pick(_ f: Favorite) {
        let c = CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon)
        picked = c
        camera = .region(MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))
    }

    func saveFav() {
        guard let c = picked else { return }
        let name = query.isEmpty ? String(format: "%.3f,%.3f", c.latitude, c.longitude) : query
        favorites.append(Favorite(name: name, lat: c.latitude, lon: c.longitude)); persist()
    }
    func remove(_ f: Favorite) { favorites.removeAll { $0.id == f.id }; persist() }
    func persist() {
        if let d = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(d, forKey: "favs") }
    }
}
