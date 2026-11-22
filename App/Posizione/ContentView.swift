import SwiftUI
import MapKit

struct Favorite: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct ContentView: View {
    @State private var camera: MapCameraPosition = .automatic
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedName = ""
    @State private var query = ""
    @State private var status = "Non connesso"
    @State private var connected = false
    @State private var simulating = false
    @State private var busy = false
    @State private var showImporter = false
    @State private var showFavorites = false
    @State private var showSaveAlert = false
    @State private var newFavName = ""
    @FocusState private var searchFocused: Bool
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

    private var stateColor: Color {
        if simulating { return .orange }
        if connected { return .green }
        return .gray
    }
    private var stateTitle: String {
        if simulating { return "Posizione simulata attiva" }
        if connected { return "Connesso" }
        return "Non connesso"
    }

    var body: some View {
        ZStack {
            mapLayer
            VStack(spacing: 0) {
                searchBar
                Spacer()
                bottomCard
            }
        }
        .sheet(isPresented: $showFavorites) { favoritesSheet }
        .alert("Salva preferito", isPresented: $showSaveAlert) {
            TextField("Nome del posto", text: $newFavName)
            Button("Salva") { saveFavorite() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Dai un nome a questa posizione.")
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

    // MARK: - Mappa

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $camera) {
                ForEach(favorites) { f in
                    Marker(f.name, systemImage: "star.fill", coordinate: f.coordinate)
                        .tint(.yellow)
                }
                if let c = picked {
                    Marker(pickedName.isEmpty ? "Posizione scelta" : pickedName, coordinate: c)
                        .tint(.red)
                }
            }
            .mapControls { MapCompass() }
            .onTapGesture { pt in
                if let c = proxy.convert(pt, from: .local) {
                    picked = c
                    pickedName = ""
                    searchFocused = false
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Barra di ricerca

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Cerca un luogo…", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit(search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            Divider().frame(height: 22)
            Button { showFavorites = true } label: {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Scheda in basso

    private var bottomCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(stateTitle).font(.subheadline.weight(.semibold))
                Spacer()
                if let c = picked {
                    Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if !pickedName.isEmpty {
                HStack {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red)
                    Text(pickedName).font(.callout).lineLimit(1)
                    Spacer()
                }
            }

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(5)

            mainButtons

            HStack(spacing: 10) {
                smallButton("Salva preferito", systemImage: "star") {
                    newFavName = pickedName
                    showSaveAlert = true
                }
                .disabled(picked == nil)
                smallButton(hasPairing ? "Cambia pairing" : "Importa pairing", systemImage: "key") {
                    showImporter = true
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var mainButtons: some View {
        if !hasPairing {
            bigButton("Importa file di pairing", systemImage: "square.and.arrow.down", color: .blue) {
                showImporter = true
            }
        } else if !connected {
            bigButton(busy ? "Connessione…" : "Connetti", systemImage: "bolt.fill", color: .blue) {
                connect()
            }
            .disabled(busy)
        } else {
            HStack(spacing: 10) {
                bigButton("Imposta posizione", systemImage: "location.fill", color: .blue) { apply() }
                    .disabled(picked == nil)
                bigButton("Posizione reale", systemImage: "location.slash.fill", color: .red) { stop() }
            }
        }
    }

    private func bigButton(_ title: String, systemImage: String, color: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(.white)
        }
    }

    private func smallButton(_ title: String, systemImage: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preferiti

    private var favoritesSheet: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "star").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Nessun preferito").font(.headline)
                        Text("Scegli un posto sulla mappa e premi “Salva preferito”.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    List {
                        ForEach(favorites) { f in
                            Button { select(f) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.name).font(.body).foregroundStyle(.primary)
                                        Text(String(format: "%.4f, %.4f", f.lat, f.lon))
                                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .onDelete { idx in
                            favorites.remove(atOffsets: idx)
                            persist()
                        }
                    }
                }
            }
            .navigationTitle("Preferiti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { if !favorites.isEmpty { EditButton() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Chiudi") { showFavorites = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Azioni

    func select(_ f: Favorite) {
        picked = f.coordinate
        pickedName = f.name
        camera = .region(MKCoordinateRegion(center: f.coordinate,
                                            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        showFavorites = false
    }

    func saveFavorite() {
        guard let c = picked else { return }
        let trimmed = newFavName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? String(format: "%.3f, %.3f", c.latitude, c.longitude) : trimmed
        favorites.append(Favorite(name: name, lat: c.latitude, lon: c.longitude))
        pickedName = name
        persist()
        status = "Salvato nei preferiti: \(name)"
    }

    func persist() {
        if let d = try? JSONEncoder().encode(favorites) { UserDefaults.standard.set(d, forKey: "favs") }
    }

    func search() {
        searchFocused = false
        let req = MKLocalSearch.Request(); req.naturalLanguageQuery = query
        MKLocalSearch(request: req).start { resp, _ in
            guard let item = resp?.mapItems.first else { status = "Nessun risultato"; return }
            let c = item.placemark.coordinate
            picked = c
            pickedName = item.name ?? query
            camera = .region(MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))
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
                    await MainActor.run { busy = false; connected = true; status = "Connesso. Scegli un posto e premi Imposta posizione." }
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
        else {
            simulating = true
            status = pickedName.isEmpty ? "Sei qui con la posizione simulata." : "Sei a: \(pickedName). Tieni LocalDevVPN e l'app aperti."
        }
    }

    func stop() {
        Engine.clear(); Engine.disconnect()
        connected = false; simulating = false
        status = "Posizione reale ripristinata."
    }
}
