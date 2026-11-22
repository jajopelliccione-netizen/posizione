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

enum TapTarget { case start, stop, end }

enum TimeMode: String, CaseIterable, Identifiable {
    case stima = "Stima"
    case velocita = "Velocità"
    case durata = "Durata"
    var id: String { rawValue }
}

struct Waypoint: Identifiable, Equatable {
    var id = UUID()
    var lat: Double
    var lon: Double
    var name: String
    var pauseMin: Double = 5
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

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
    @State private var timeMode: TimeMode = .stima
    @State private var waypoints: [Waypoint] = []
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
    @StateObject private var completer = SearchCompleter()
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
        if runner.running && runner.waiting > 0 { return "In sosta" }
        if runner.running { return "In movimento" }
        if simulating { return "Simulazione attiva" }
        if connected { return "Connesso" }
        return "Non connesso"
    }

    private var totalPauseSec: Double { waypoints.reduce(0) { $0 + $1.pauseMin * 60 } }

    private var defaultMps: Double { transport == 0 ? 1.4 : 11.0 }

    /// Velocità di marcia (m/s) in base alla modalità scelta.
    private var speedMps: Double {
        switch timeMode {
        case .velocita:
            return max(speedKmh / 3.6, 0.1)
        case .stima:
            if let r = runner.route, r.total > 0, r.expectedTime > 1 { return r.total / r.expectedTime }
            return defaultMps
        case .durata:
            if let r = runner.route, r.total > 0 {
                let moving = max(durationMin * 60 - totalPauseSec, 30)
                return r.total / moving
            }
            return defaultMps
        }
    }
    private var shownKmh: Double { speedMps * 3.6 }
    private var speedRange: ClosedRange<Double> { transport == 0 ? 1...15 : 5...130 }

    var body: some View {
        ZStack {
            mapLayer
            VStack(spacing: 0) {
                searchBar
                suggestionsList
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
                Notifier.post("Sei arrivato", "Percorso completato.")
            }
            runner.onEvent = { ev in
                switch ev {
                case .reachedStop(let i):
                    guard i < waypoints.count else { return }
                    let w = waypoints[i]
                    Notifier.post("Sosta: \(w.name)", "Resti fermo \(formatMinutes(w.pauseMin)).")
                case .leftStop(let i):
                    guard i < waypoints.count else { return }
                    Notifier.post("Si riparte", "Hai lasciato \(waypoints[i].name).")
                }
            }
            syncSpeed()
        }
        .onChange(of: speedKmh) { syncSpeed() }
        .onChange(of: durationMin) { syncSpeed() }
        .onChange(of: timeMode) { syncSpeed() }
        .onChange(of: waypoints) { syncSpeed() }
        .onChange(of: runner.route?.total) { syncSpeed() }
        .onChange(of: query) { completer.update(query) }
        .onChange(of: transport) {
            speedKmh = transport == 0 ? 5 : 40
            runner.setRoute(nil)
        }
    }

    func syncSpeed() {
        runner.speedMps = speedMps
        runner.pauses = waypoints.map { $0.pauseMin * 60 }
    }

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
                    ForEach(Array(waypoints.enumerated()), id: \.element.id) { i, w in
                        Marker("\(i + 1). \(w.name)", systemImage: "pause.circle.fill", coordinate: w.coordinate)
                            .tint(.orange)
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
            .onMapCameraChange(frequency: .onEnd) { ctx in
                completer.region = ctx.region
            }
            .onTapGesture { pt in
                guard let c = proxy.convert(pt, from: .local) else { return }
                searchFocused = false
                mapTapped(c)
            }
        }
        .ignoresSafeArea()
    }

    func mapTapped(_ c: CLLocationCoordinate2D) {
        if mode == .percorso && runner.running { return }
        place(c, name: "")
    }

    /// Usa un punto (tocco sulla mappa, ricerca o preferito) secondo la modalità attuale.
    func place(_ c: CLLocationCoordinate2D, name: String) {
        if mode == .posto {
            picked = c
            pickedName = name
            return
        }
        guard !runner.running else { return }
        switch tapTarget {
        case .start:
            routeStart = c
            tapTarget = .end
        case .end:
            routeEnd = c
        case .stop:
            let label = name.isEmpty ? "Tappa \(waypoints.count + 1)" : name
            waypoints.append(Waypoint(lat: c.latitude, lon: c.longitude, name: label))
        }
        runner.setRoute(nil)
    }

    // MARK: - Barra di ricerca

    @ViewBuilder
    private var suggestionsList: some View {
        if searchFocused && !query.isEmpty && !completer.results.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(completer.results.prefix(6).enumerated()), id: \.offset) { i, c in
                    Button { pickCompletion(c) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: c.subtitle.isEmpty ? "magnifyingglass" : "mappin.circle.fill")
                                .foregroundStyle(c.subtitle.isEmpty ? Color.secondary : Color.red)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary).lineLimit(1)
                                if !c.subtitle.isEmpty {
                                    Text(c.subtitle).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < min(completer.results.count, 6) - 1 { Divider().padding(.leading, 50) }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    func pickCompletion(_ c: MKLocalSearchCompletion) {
        searchFocused = false
        completer.clear()
        MKLocalSearch(request: MKLocalSearch.Request(completion: c)).start { resp, _ in
            guard let item = resp?.mapItems.first else { status = "Luogo non trovato"; return }
            let coord = item.placemark.coordinate
            let name = item.name ?? c.title
            query = name
            completer.clear()
            place(coord, name: name)
            camera = .region(MKCoordinateRegion(center: coord, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)))
        }
    }

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
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 5)
                .padding(.top, 2)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }

            header

            if expanded {
                if connected { modePicker }
                statusBanner
                if !hasPairing {
                    primaryButton("Importa file di pairing", "square.and.arrow.down") { showImporter = true }
                } else if !connected {
                    primaryButton(busy ? "Connessione…" : "Connetti", "bolt.fill") { connect() }
                        .disabled(busy)
                } else if mode == .posto {
                    postoPanel
                } else {
                    percorsoPanel
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                Text(stateTitle).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(stateColor.opacity(0.16), in: Capsule())
            Spacer(minLength: 4)
            Menu {
                Button { showImporter = true } label: {
                    Label("Cambia pairing", systemImage: "key")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modePicker: some View {
        Picker("Modalità", selection: $mode) {
            ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !status.isEmpty {
            let isError = status.hasPrefix("Errore") || status.contains("non trovato")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(isError ? Theme.danger : Theme.accent)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background((isError ? Theme.danger : Theme.accent).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Bottoni

    private func primaryButton(_ title: String, _ icon: String,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .buttonStyle(FilledButtonStyle(fill: AnyShapeStyle(Theme.gradient)))
    }

    private func dangerButton(_ title: String, _ icon: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .buttonStyle(FilledButtonStyle(fill: AnyShapeStyle(Theme.danger)))
    }

    private func warnButton(_ title: String, _ icon: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .buttonStyle(FilledButtonStyle(fill: AnyShapeStyle(Theme.warn)))
    }

    private func tonalButton(_ title: String, _ icon: String,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .buttonStyle(TonalButtonStyle())
    }

    // MARK: - Pannello Posto

    func coordsText(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", c.latitude, c.longitude)
    }

    private var postoPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: picked == nil ? "hand.tap.fill" : "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(picked == nil ? Color.secondary : Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(picked == nil ? "Scegli un posto" : (pickedName.isEmpty ? "Posizione scelta" : pickedName))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(picked == nil ? "Tocca la mappa, cerca un luogo o scegli un preferito"
                                       : coordsText(picked ?? CLLocationCoordinate2D()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    newFavName = pickedName
                    showSaveAlert = true
                } label: {
                    Image(systemName: "star.circle.fill")
                        .font(.title)
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .disabled(picked == nil)
                .opacity(picked == nil ? 0.35 : 1)
            }
            .panel()

            favoritesStrip

            HStack(spacing: 10) {
                primaryButton("Imposta qui", "location.fill") { apply() }
                    .disabled(picked == nil)
                dangerButton("Posizione reale", "location.slash.fill") { stop() }
            }
        }
    }

    /// Fascia con i preferiti salvati, sempre visibile sotto la scelta del posto.
    private var favoritesStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Preferiti", systemImage: "star.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !favorites.isEmpty {
                    Button("Gestisci") { showFavorites = true }
                        .font(.footnote.weight(.semibold))
                }
            }
            if favorites.isEmpty {
                Text("Nessun preferito. Scegli un posto e tocca la stella gialla per salvarlo qui.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(favorites) { f in
                            Button { select(f) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                                    Text(f.name).font(.footnote.weight(.medium)).lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Pannello Percorso

    private var percorsoPanel: some View {
        ViewThatFits(in: .vertical) {
            percorsoContent
            ScrollView(showsIndicators: false) { percorsoContent }
        }
        .frame(maxHeight: 360)
    }

    private var percorsoContent: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                Picker("Mezzo", selection: $transport) {
                    Label("A piedi", systemImage: "figure.walk").tag(0)
                    Label("In auto", systemImage: "car.fill").tag(1)
                }
                .pickerStyle(.segmented)
                .disabled(runner.running)

                HStack(spacing: 6) {
                    targetChip("Partenza", systemImage: "figure.walk", color: .green,
                               set: routeStart != nil, selected: tapTarget == .start) { tapTarget = .start }
                    targetChip("Tappa", systemImage: "plus.circle", color: .orange,
                               set: false, selected: tapTarget == .stop) { tapTarget = .stop }
                    targetChip("Arrivo", systemImage: "flag.checkered", color: .red,
                               set: routeEnd != nil, selected: tapTarget == .end) { tapTarget = .end }
                }

                if tapTarget == .stop && waypoints.isEmpty {
                    hint("Tocca la mappa o cerca un luogo per aggiungere una tappa.")
                } else if routeStart == nil && appliedCoord != nil && !runner.running {
                    hint("Partenza non scelta: uso la posizione attuale.")
                }
            }
            .panel()

            if !waypoints.isEmpty {
                VStack(spacing: 0) {
                    ForEach($waypoints) { $w in
                        waypointRow($w)
                        if w.id != waypoints.last?.id { Divider() }
                    }
                }
                .panel()
            }

            VStack(spacing: 10) {
                Picker("Tempo", selection: $timeMode) {
                    ForEach(TimeMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)

                switch timeMode {
                case .stima:
                    hint("Il tempo di cammino lo stima Mappe in base al percorso.")
                case .velocita:
                    sliderRow("Velocità", String(format: "%.0f km/h", speedKmh))
                    Slider(value: $speedKmh, in: speedRange, step: 1)
                case .durata:
                    sliderRow("Durata totale, soste incluse", formatMinutes(durationMin))
                    Slider(value: $durationMin, in: 1...480, step: 1)
                    if let r = runner.route, r.total > 0, durationMin * 60 <= totalPauseSec + 30 {
                        Text("Durata troppo corta per le soste: riducile o aumenta il tempo.")
                            .font(.caption).foregroundStyle(Theme.warn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .panel()

            if let r = runner.route {
                summary(r)
            }

            routeButtons
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sliderRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func summary(_ r: PlannedRoute) -> some View {
        let moving = r.total / max(speedMps, 0.1)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                tile(formatDistance(r.total), "Distanza")
                tile(formatDuration(moving + totalPauseSec), "Totale")
                tile(String(format: "%.1f km/h", shownKmh), "Velocità")
            }
            if totalPauseSec > 0 {
                hint("Cammino " + formatDuration(moving) + "  ·  Soste " + formatDuration(totalPauseSec))
            }
            if r.isStraightLine {
                Text("Per qualche tratto non ho trovato strade: uso la linea retta.")
                    .font(.caption).foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if runner.traveled > 0 {
                ProgressView(value: runner.progress).tint(Theme.accent)
                if runner.waiting > 0 {
                    Text("In sosta: ancora " + formatDuration(runner.waiting))
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    hint("Mancano " + formatDistance(max(r.total - runner.traveled, 0)))
                }
            }
        }
    }

    private func stepPause(_ v: Double, up: Bool) -> Double {
        let step: Double = v >= 10 ? 5 : 1
        return up ? min(180, v + step) : max(0, v - step)
    }

    private func waypointRow(_ w: Binding<Waypoint>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(Theme.warn)
            Text(w.wrappedValue.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Button { w.wrappedValue.pauseMin = stepPause(w.wrappedValue.pauseMin, up: false) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                Text(String(format: "%.0f min", w.wrappedValue.pauseMin))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(minWidth: 50)
                Button { w.wrappedValue.pauseMin = stepPause(w.wrappedValue.pauseMin, up: true) } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .font(.title3)
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
            Button { removeWaypoint(w.wrappedValue.id) } label: {
                Image(systemName: "trash").font(.footnote).foregroundStyle(Theme.danger)
            }
            .buttonStyle(.plain)
            .disabled(runner.running)
        }
        .padding(.vertical, 6)
    }

    func removeWaypoint(_ id: UUID) {
        waypoints.removeAll { $0.id == id }
        runner.setRoute(nil)
    }

    func formatMinutes(_ m: Double) -> String {
        let t = Int(m)
        return t >= 60 ? "\(t / 60) h \(t % 60) min" : "\(t) min"
    }

    @ViewBuilder
    private var routeButtons: some View {
        if runner.route == nil {
            primaryButton(planning ? "Calcolo…" : "Calcola percorso",
                          "point.topleft.down.to.point.bottomright.curvepath.fill") {
                computeRoute()
            }
            .disabled(planning || routeEnd == nil || (routeStart == nil && appliedCoord == nil))
        } else {
            HStack(spacing: 10) {
                if runner.running {
                    warnButton("Pausa", "pause.fill") {
                        runner.pause()
                        appliedCoord = runner.current
                    }
                } else {
                    primaryButton(runner.traveled > 0 ? "Riprendi" : "Avvia", "play.fill") {
                        startRoute()
                    }
                }
                dangerButton("Posizione reale", "location.slash.fill") { stop() }
            }
            if !runner.running && runner.traveled > 0 {
                tonalButton("Ricomincia", "arrow.counterclockwise") {
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
            .padding(.vertical, 10)
            .background(selected ? color.opacity(0.20) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? color : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(runner.running)
    }

    // MARK: - Preferiti

    private var favoritesSheet: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "star").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text("Nessun preferito").font(.headline)
                        Text("Scegli un posto sulla mappa e tocca la stella gialla per salvarlo qui.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    List {
                        Section {
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
                        } footer: {
                            Text("I preferiti sono salvati su questo iPhone, dentro l'app. Scorri a sinistra per eliminarli.")
                        }
                    }
                }
            }
            .navigationTitle("Preferiti salvati")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Chiudi") { showFavorites = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Azioni

    func select(_ f: Favorite) {
        place(f.coordinate, name: f.name)
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
            place(c, name: item.name ?? query)
            camera = .region(MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)))
        }
    }

    func connect() {
        busy = true; status = "Cerco il telefono…"
        let path = pairingURL.path
        Task {
            // 1) Indirizzi già noti: prima la VPN locale (non dipende dal Wi-Fi), poi quello trovato in rete.
            let found = await Discovery.find()
            var candidates: [(String, UInt16)] = []
            for f in found { candidates.append(("10.7.0.1", f.port)); candidates.append((f.host, f.port)) }
            if let last = loadLastEndpoint() {
                candidates.append(("10.7.0.1", last.1))
                candidates.append(last)
            }
            var tried = Set<String>()
            var errors: [String] = []

            func attempt(_ h: String, _ p: UInt16) async -> Bool {
                let key = "\(h):\(p)"
                if tried.contains(key) { return false }
                tried.insert(key)
                await MainActor.run { status = "Connessione a \(key)…" }
                let err = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                    DispatchQueue.global().async { c.resume(returning: Engine.connectRP(pairingPath: path, host: h, port: p)) }
                }
                if let err {
                    errors.append("\(key) -> \(err)")
                    return false
                }
                saveLastEndpoint(h, p)
                await MainActor.run {
                    busy = false
                    connected = true
                    status = "Connesso (\(key))"
                    KeepAlive.shared.start()
                    RealLocation.shared.requestPermission()
                }
                return true
            }

            for (h, p) in candidates {
                if await attempt(h, p) { return clearConnectedNote() }
            }

            // 2) Niente Wi-Fi o porta cambiata: cerco io la porta sulla VPN locale.
            await MainActor.run { status = "Cerco la porta sul telefono (può volerci un minuto)…" }
            let ports: [UInt16] = await withCheckedContinuation { (c: CheckedContinuation<[UInt16], Never>) in
                DispatchQueue.global().async { c.resume(returning: Engine.scanPorts(host: "10.7.0.1", lo: 49152, hi: 65535)) }
            }
            for p in ports {
                if await attempt("10.7.0.1", p) { return clearConnectedNote() }
            }

            await MainActor.run {
                busy = false; connected = false
                if errors.isEmpty {
                    status = "Telefono non trovato. Controlla che LocalDevVPN sia connessa, la Modalità sviluppatore e Rete locale."
                } else {
                    status = "Errore: " + errors.suffix(4).joined(separator: "\n")
                }
            }
        }
    }

    /// Toglie dopo qualche secondo la riga "Connesso (indirizzo)".
    func clearConnectedNote() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if status.hasPrefix("Connesso (") { status = "" }
        }
    }

    func saveLastEndpoint(_ host: String, _ port: UInt16) {
        UserDefaults.standard.set(host, forKey: "lastHost")
        UserDefaults.standard.set(Int(port), forKey: "lastPort")
    }

    func loadLastEndpoint() -> (String, UInt16)? {
        guard let h = UserDefaults.standard.string(forKey: "lastHost") else { return nil }
        let p = UserDefaults.standard.integer(forKey: "lastPort")
        guard p > 0 && p < 65536 else { return nil }
        return (h, UInt16(p))
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
        KeepAlive.shared.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { RealLocation.shared.refresh() }
        connected = false; simulating = false
        appliedCoord = nil
        status = "Posizione reale ripristinata. Il GPS può metterci qualche secondo a ritrovarti."
    }

    func computeRoute() {
        guard let end = routeEnd, let start = routeStart ?? appliedCoord else { return }
        planning = true
        status = ""
        let walking = transport == 0
        var points: [CLLocationCoordinate2D] = [start]
        points.append(contentsOf: waypoints.map { $0.coordinate })
        points.append(end)
        Task {
            let r = await Planner.plan(points: points, walking: walking)
            await MainActor.run {
                runner.setRoute(r)
                planning = false
                fitCamera(r.coords)
            }
        }
    }

    func startRoute() {
        syncSpeed()
        Notifier.requestAuth()
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
