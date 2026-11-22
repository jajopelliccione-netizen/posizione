import SwiftUI
import MapKit

struct Favorite: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

enum Mode: String, CaseIterable, Identifiable {
    case posto = "Posto"
    case percorso = "Percorso"
    var id: String { rawValue }
}

enum TapTarget { case start, end }

struct ContentView: View {
    @StateObject private var runner = RouteRunner()

    @State private var camera: MapCameraPosition = .automatic
    @State private var mode: Mode = .posto
    @State private var expanded = true

    // Posto singolo
    @State private var picked: CLLocationCoordinate2D?
    @State private var pickedName = ""
    @State private var query = ""
    @State private var appliedCoord: CLLocationCoordinate2D?

    // Percorso
    @State private var routeStart: CLLocationCoordinate2D?
    @State private var routeEnd: CLLocationCoordinate2D?
    @State private var tapTarget: TapTarget = .end
    @State private var transport = 0            // 0 = a piedi, 1 = in auto
    @State private var useDuration = false
    @State private var speedKmh: Double = 5
    @State private var durationMin: Double = 20
    @State private var planning = false

    // Stato generale
    @State private var status = ""
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
        if runner.running { return .blue }
        if simulating { return .orange }
        if connected { return .green }
        return .gray
    }
    private var stateTitle: String {
        if runner.running { return "In movimento" }
        if simulating { return "Simulazione attiva" }
        if connected { return "Connesso" }
        return "Non connesso"
    }

    private var speedMps: Double {
        if useDuration, let r = runner.route, r.total > 0 {
            return r.total / max(durationMin * 60, 1)
        }
        return max(speedKmh / 3.6, 0.1)
    }
    private var shownKmh: Double { speedMps * 3.6 }
    private var speedRange: ClosedRange<Double> { transport == 0 ? 1...15 : 5...130 }

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
                status = "Pairing importato. Premi Connetti."
            } catch { status = "Import fallito: \(error.localizedDescription)" }
        }
        .onAppear {
            runner.onError = { err in status = "Errore: \(err)" }
            runner.onFinished = {
                appliedCoord = runner.current
                status = "Arrivato a destinazione."
            }
            syncSpeed()
        }
        .onChange(of: speedKmh) { syncSpeed() }
        .onChange(of: durationMin) { syncSpeed() }
        .onChange(of: useDuration) { syncSpeed() }
        .onChange(of: runner.route?.total) { syncSpeed() }
        .onChange(of: transport) {
            speedKmh = transport == 0 ? 5 : 40
            runner.setRoute(nil)
        }
    }

    func syncSpeed() { runner.speedMps = speedMps }

    // MARK: - Mappa

    private var mapLayer: some View {
        MapReader { proxy in
            Map(position: $camera) {
                ForEach(favorites) { f in
                    Marker(f.name, systemImage: "star.fill", coordinate: f.coordinate)
                        .tint(.yellow)
                }
                if mode == .posto, let c = picked {
                    Marker(pickedName.isEmpty ? "Posizione scelta" : pickedName, coordinate: c)
                        .tint(.red)
                }
                if mode == .percorso {
                    if let r = runner.route {
                        MapPolyline(coordinates: r.coords)
                            .stroke(.blue, lineWidth: 5)
                    }
                    if let s = routeStart {
                        Marker("Partenza", systemImage: "figure.walk", coordinate: s).tint(.green)
                    }
                    if let e = routeEnd {
                        Marker("Arrivo", systemImage: "flag.checkered", coordinate: e).tint(.red)
                    }
                    if let cur = runner.current {
                        Annotation("", coordinate: cur) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.white, lineWidth: 3))
                                .shadow(radius: 3)
                        }
                    }
                }
            }
            .mapControls { MapCompass() }
            .onTapGesture { pt in
                guard let c = proxy.convert(pt, from: .local) else { return }
                searchFocused = false
                mapTapped(c)
            }
        }
        .ignoresSafeArea()
    }

    func mapTapped(_ c: CLLocationCoordinate2D) {
        if mode == .posto {
            picked = c
            pickedName = ""
        } else {
            guard !runner.running else { return }
            if tapTarget == .start {
                routeStart = c
                tapTarget = .end
            } else {
                routeEnd = c
            }
            runner.setRoute(nil)
        }
    }

    // MARK: - Barra di ricerca

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Cerca un luogo", text: $query)
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
            header

            if expanded {
                if connected {
                    Picker("Modalità", selection: $mode) {
                        ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(4)
                }

                if !hasPairing {
                    bigButton("Importa pairing", systemImage: "square.and.arrow.down", color: .blue) {
                        showImporter = true
                    }
                } else if !connected {
                    bigButton(busy ? "Connessione…" : "Connetti", systemImage: "bolt.fill", color: .blue) {
                        connect()
                    }
                    .disabled(busy)
                } else if mode == .posto {
                    postoPanel
                } else {
                    percorsoPanel
                }

                HStack(spacing: 10) {
                    if mode == .posto {
                        smallButton("Salva preferito", systemImage: "star") {
                            newFavName = pickedName
                            showSaveAlert = true
                        }
                        .disabled(picked == nil)
                    }
                    smallButton("Cambia pairing", systemImage: "key") { showImporter = true }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 10, height: 10)
            Text(stateTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if mode == .posto, let c = picked {
                Text(pickedName.isEmpty ? String(format: "%.4f, %.4f", c.latitude, c.longitude) : pickedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Button { withAnimation { expanded.toggle() } } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
    }

    // MARK: - Pannello Posto

    private var postoPanel: some View {
        HStack(spacing: 10) {
            bigButton("Imposta qui", systemImage: "location.fill", color: .blue) { apply() }
                .disabled(picked == nil)
            bigButton("Posizione reale", systemImage: "location.slash.fill", color: .red) { stop() }
        }
    }

    // MARK: - Pannello Percorso

    private var percorsoPanel: some View {
        VStack(spacing: 10) {
            Picker("Mezzo", selection: $transport) {
                Label("A piedi", systemImage: "figure.walk").tag(0)
                Label("In auto", systemImage: "car.fill").tag(1)
            }
            .pickerStyle(.segmented)
            .disabled(runner.running)

            HStack(spacing: 8) {
                targetChip("Partenza", systemImage: "figure.walk", color: .green,
                           set: routeStart != nil, selected: tapTarget == .start) { tapTarget = .start }
                targetChip("Arrivo", systemImage: "flag.checkered", color: .red,
                           set: routeEnd != nil, selected: tapTarget == .end) { tapTarget = .end }
            }

            if routeStart == nil && appliedCoord != nil && !runner.running {
                Text("Partenza non scelta: uso la posizione attuale.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("Imposta", selection: $useDuration) {
                Text("Velocità").tag(false)
                Text("Durata").tag(true)
            }
            .pickerStyle(.segmented)

            if useDuration {
                HStack {
                    Text("Durata").font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f min", durationMin)).font(.subheadline.monospacedDigit())
                }
                Slider(value: $durationMin, in: 1...240, step: 1)
                if runner.route != nil {
                    Text(String(format: "Velocità necessaria: %.1f km/h", shownKmh))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Calcola il percorso per vedere la velocità.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack {
                    Text("Velocità").font(.subheadline)
                    Spacer()
                    Text(String(format: "%.0f km/h", speedKmh)).font(.subheadline.monospacedDigit())
                }
                Slider(value: $speedKmh, in: speedRange, step: 1)
            }

            if let r = runner.route {
                VStack(spacing: 6) {
                    HStack {
                        Text(formatDistance(r.total))
                        Spacer()
                        Text("Tempo: " + formatDuration(r.total / max(speedMps, 0.1)))
                    }
                    .font(.subheadline.weight(.medium))
                    if r.isStraightLine {
                        Text("Nessuna strada trovata: uso la linea retta.")
                            .font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if runner.traveled > 0 {
                        ProgressView(value: runner.progress)
                        Text("Mancano " + formatDistance(max(r.total - runner.traveled, 0)))
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            routeButtons
        }
    }

    @ViewBuilder
    private var routeButtons: some View {
        if runner.route == nil {
            bigButton(planning ? "Calcolo…" : "Calcola percorso", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", color: .blue) {
                computeRoute()
            }
            .disabled(planning || routeEnd == nil || (routeStart == nil && appliedCoord == nil))
        } else {
            HStack(spacing: 10) {
                if runner.running {
                    bigButton("Pausa", systemImage: "pause.fill", color: .orange) {
                        runner.pause()
                        appliedCoord = runner.current
                    }
                } else {
                    bigButton(runner.traveled > 0 ? "Riprendi" : "Avvia", systemImage: "play.fill", color: .blue) {
                        startRoute()
                    }
                }
                bigButton("Posizione reale", systemImage: "location.slash.fill", color: .red) { stop() }
            }
            if !runner.running && runner.traveled > 0 {
                smallButton("Ricomincia", systemImage: "arrow.counterclockwise") {
                    let r = runner.route
                    runner.setRoute(r)
                }
            }
        }
    }

    private func targetChip(_ title: String, systemImage: String, color: Color,
                            set: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: set ? "checkmark.circle.fill" : systemImage)
                    .foregroundStyle(color)
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selected ? color.opacity(0.22) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? color : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(runner.running)
    }

    // MARK: - Bottoni

    private func bigButton(_ title: String, systemImage: String, color: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
        }
    }

    private func smallButton(_ title: String, systemImage: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
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
                        Text("Scegli un posto sulla mappa e premi Salva preferito.")
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
        if mode == .posto {
            picked = f.coordinate
            pickedName = f.name
        } else if tapTarget == .start {
            routeStart = f.coordinate
            tapTarget = .end
            runner.setRoute(nil)
        } else {
            routeEnd = f.coordinate
            runner.setRoute(nil)
        }
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
            let name = item.name ?? query
            if mode == .posto {
                picked = c
                pickedName = name
            } else if tapTarget == .start {
                routeStart = c
                tapTarget = .end
                runner.setRoute(nil)
            } else {
                routeEnd = c
                runner.setRoute(nil)
            }
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
                    status = "Telefono non trovato. Controlla Rete locale, Wi-Fi e Modalità sviluppatore."
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
                    await MainActor.run { busy = false; connected = true; status = "" }
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
            appliedCoord = c
            status = ""
        }
    }

    func stop() {
        runner.setRoute(runner.route)
        Engine.clear(); Engine.disconnect()
        connected = false; simulating = false
        appliedCoord = nil
        status = "Posizione reale ripristinata."
    }

    func computeRoute() {
        guard let end = routeEnd, let start = routeStart ?? appliedCoord else { return }
        planning = true
        status = ""
        let walking = transport == 0
        Task {
            let r = await Planner.plan(from: start, to: end, walking: walking)
            await MainActor.run {
                runner.setRoute(r)
                planning = false
                fitCamera(r.coords)
            }
        }
    }

    func startRoute() {
        syncSpeed()
        simulating = true
        status = ""
        runner.start()
    }

    func fitCamera(_ coords: [CLLocationCoordinate2D]) {
        guard let first = coords.first else { return }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.005),
                                    longitudeDelta: max((maxLon - minLon) * 1.6, 0.005))
        camera = .region(MKCoordinateRegion(center: center, span: span))
    }
}
