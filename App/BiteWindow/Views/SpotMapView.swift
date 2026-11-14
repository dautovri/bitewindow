import BiteCore
import MapKit
import Observation
import SwiftData
import SwiftUI
import UIKit

/// Spots on a map. A spot is dropped at the map centre, so no location
/// permission is needed; "my location" asks for it only when tapped.
struct SpotMapView: View {
    @Query private var spots: [Spot]
    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementManager.self) private var entitlements
    @Environment(AppRouter.self) private var router
    @AppStorage(ForecastService.lastPrefetchKey) private var lastPrefetch = 0.0

    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var newName = ""
    @State private var showNamePrompt = false
    @State private var showPaywall = false
    @State private var isHybrid = true
    /// Today's best-window index per spot, worked out once per forecast download rather than
    /// on every frame of a map pan.
    @State private var indices: [UUID: Double] = [:]
    /// Which fish the water suits right now, per spot, worked out with the indices.
    @State private var outlooks: [UUID: SpotOutlook] = [:]
    @State private var selectedSpotID: UUID?
    @State private var appearances = 0
    @State private var searchCompleter = PlaceSearchCompleter()
    @State private var locationCenter = LocationCenter()
    /// What the geocoder found at the crosshair when "Add spot" was tapped.
    @State private var suggestion = SpotSuggestion()
    @State private var isLookingUp = false
    /// The crosshair position the lookup was made for; the spot is saved exactly there.
    @State private var pendingCoordinate: CLLocationCoordinate2D?
    @State private var showLocationHelp = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selectedSpotID) {
                // Only once location was allowed: MapKit would otherwise ask for it by itself.
                if locationCenter.isAuthorized { UserAnnotation() }
                ForEach(spots) { spot in
                    let index = indices[spot.id]
                    Annotation(spot.name, coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)) {
                        SpotAnnotationPin(name: spot.name, index: index, best: outlooks[spot.id]?.ranked.first)
                    }
                    .annotationTitles(.hidden)
                    .tag(spot.id)
                }
            }
            .mapStyle(isHybrid ? .hybrid : .standard)
            .animation(.snappy, value: selectedSpotID)
            .onChange(of: selectedSpotID) { if selectedSpotID != nil { searchFocused = false } }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                center = context.region.center
            }
            .overlay {
                // Hidden while a spot's card is open: adding is off then, and it would sit on the pin.
                CrosshairReticle(center: center)
                    .opacity(selectedSpotID == nil ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .safeAreaInset(edge: .top, spacing: 8) {
                topOverlay
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            // Again each time the tab comes forward: the Forecast tab may have saved a spot's
            // first forecast in the meantime.
            .onAppear { appearances += 1 }
            // From the welcome screen: go to the phone's position, or open the search.
            .onChange(of: router.mapRequest, initial: true) {
                guard let request = router.mapRequest else { return }
                router.mapRequest = nil
                switch request {
                case .locate:
                    locationCenter.requestCenter()
                    showLocationHelp = locationCenter.isDenied
                case .search:
                    searchFocused = true
                }
            }
            .task(id: "\(appearances)|\(lastPrefetch)|\(spots.map { "\($0.id)\($0.waterRaw)\($0.speciesRaw)\($0.waterTempC ?? -999)\($0.timeZoneID ?? "")" }.joined())") {
                var fresh: [UUID: Double] = [:]
                var freshOutlooks: [UUID: SpotOutlook] = [:]
                for spot in spots {
                    // The tide counts at saltwater spots, as on the Forecast tab (saved station first).
                    let tide = spot.isSalt
                        ? await ForecastService.shared.tideStation(latitude: spot.latitude, longitude: spot.longitude) : nil
                    fresh[spot.id] = currentIndex(for: spot, tide: tide)
                    freshOutlooks[spot.id] = outlook(for: spot, tide: tide)
                }
                indices = fresh
                outlooks = freshOutlooks
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Name this spot", isPresented: $showNamePrompt) {
                TextField("Name", text: $newName)
                Button("Save") { addSpot() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if suggestion.looksLikeLand {
                    Text("No lake, river or sea was found at this point. Move the crosshair onto the water, or save it anyway.")
                }
            }
            .onChange(of: locationCenter.centerRequests) {
                withAnimation { position = .userLocation(fallback: .automatic) }
            }
            .alert("Location is off for BiteCurve", isPresented: Binding(get: { locationCenter.isDenied && showLocationHelp },
                                                                         set: { showLocationHelp = $0 })) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow location in Settings to centre the map on where you are. The app works without it.")
            }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    private var topOverlay: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SearchBar(completer: searchCompleter, isFocused: $searchFocused) { completion in
                    selectSuggestion(completion)
                }
                Button {
                    isHybrid.toggle()
                } label: {
                    Image(systemName: isHybrid ? "globe.americas.fill" : "map")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: .circle)
                        .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                }
                .accessibilityLabel(Text("Map style"))
                Button {
                    searchFocused = false
                    locationCenter.requestCenter()
                    // Only when it was refused earlier; the first ask is the system's own prompt.
                    showLocationHelp = locationCenter.isDenied
                } label: {
                    Image(systemName: locationCenter.isAuthorized ? "location.fill" : "location")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: .circle)
                        .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                }
                .accessibilityLabel(Text("My location"))
            }
            .frame(maxWidth: Theme.readableWidth)

            if !searchCompleter.results.isEmpty && !searchCompleter.query.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchSuggestionsList(results: searchCompleter.results) { completion in
                    selectSuggestion(completion)
                }
                .frame(maxWidth: Theme.readableWidth)
            }

            if !spots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(spots) { spot in
                            SpotPill(name: spot.name, index: indices[spot.id]) {
                                searchFocused = false
                                flyTo(spot)
                                selectedSpotID = spot.id
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
                .frame(maxWidth: Theme.readableWidth)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func selectSuggestion(_ completion: MKLocalSearchCompletion) {
        searchFocused = false
        Task {
            if let region = await searchCompleter.resolve(completion) {
                withAnimation {
                    position = .region(region)
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let id = selectedSpotID, let spot = spots.first(where: { $0.id == id }) {
                SpeciesNowCard(name: spot.name, isSalt: spot.isSalt, outlook: outlooks[id]) {
                    selectedSpotID = nil
                }
                .frame(maxWidth: Theme.readableWidth)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                // Out of the way while a spot's card is open, so the map stays visible.
                addSpotButton
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .padding()
    }

    private var addSpotButton: some View {
        Button {
            if !entitlements.isPro && spots.count >= EntitlementManager.freeSpotLimit {
                showPaywall = true
            } else if let center, !isLookingUp {
                searchFocused = false
                // The water's name, salt or fresh, and whether the point is on water at all;
                // the prompt opens after three seconds at most, with or without an answer.
                isLookingUp = true
                pendingCoordinate = center
                Task {
                    suggestion = await SpotSuggestion.lookup(latitude: center.latitude, longitude: center.longitude)
                    newName = suggestion.waterName ?? ""
                    isLookingUp = false
                    showNamePrompt = true
                }
            }
        } label: {
            Label("Add spot at crosshair", systemImage: "plus")
                .font(.headline)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.accent)
        .controlSize(.large)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        // The crosshair position is known once the map has reported its camera.
        .disabled(center == nil)
    }

    private func flyTo(_ spot: Spot) {
        let coordinate = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
        let span = MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        withAnimation {
            position = .region(MKCoordinateRegion(center: coordinate, span: span))
        }
    }

    /// The index of today's best window, as the Forecast tab shows it, from the forecast saved
    /// on the phone only (no network from the map). Nil without a saved forecast or a window.
    private func currentIndex(for spot: Spot, tide: TideStation?) -> Double? {
        guard let saved = ForecastService.shared.cached(latitude: spot.latitude, longitude: spot.longitude) else {
            return nil
        }
        let calendar = spot.calendar
        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        var context = spot.context
        context.tide = tide
        let points = Forecaster.curve(context: context, hours: saved.hours, from: today, to: end, fillMissingWeather: true)
            .filter { $0.time < end }
        return Forecaster.bestWindow(in: points, notBefore: now.addingTimeInterval(-900))?.meanIndex
    }

    /// Fish ranked by how well the water suits them now, from the saved forecast only. The
    /// measured water temperature when there is one, else an estimate from the last days' air.
    private func outlook(for spot: Spot, tide: TideStation?) -> SpotOutlook? {
        guard let saved = ForecastService.shared.cached(latitude: spot.latitude, longitude: spot.longitude) else {
            return nil
        }
        let now = Date()
        // Measured, else the saved estimate, else (inland, nothing saved yet) the last days' air.
        var reading = spot.waterReading
        if reading == nil, !spot.isSalt, let rough = Terms.estimatedWaterTempC(hours: saved.hours, now: now) {
            reading = .modelled(rough)
        }
        var context = spot.context
        context.tide = tide
        let ranked = Forecaster.speciesNow(context: context, hours: saved.hours, now: now, waterTempC: reading?.tempC)
        return SpotOutlook(reading: reading, ranked: ranked)
    }

    private func addSpot() {
        guard let center = pendingCoordinate ?? center else { return }
        pendingCoordinate = nil
        // Checked again here: the count can change while the name prompt is open.
        guard entitlements.isPro || spots.count < EntitlementManager.freeSpotLimit else {
            showPaywall = true
            return
        }
        // Asked before the insert: the query may already count the new spot afterwards.
        let isFirstSpot = spots.isEmpty
        let name = newName.trimmingCharacters(in: .whitespaces)
        let spot = Spot(name: name.isEmpty ? String(localized: "Spot \(spots.count + 1)") : name,
                        latitude: center.latitude, longitude: center.longitude)
        // From the geocoder: sea or inland water, the fish usual in that country, the zone.
        if let water = suggestion.water { spot.water = water }
        spot.species = Species.defaultSpecies(forRegion: suggestion.regionCode ?? Locale.current.region?.identifier, water: spot.water)
        spot.timeZoneID = suggestion.timeZoneID
        suggestion = SpotSuggestion()
        modelContext.insert(spot)
        // Saved at once: the system's own save can come seconds later, and a spot must not be
        // lost if the app is closed right after it was added.
        try? modelContext.save()
        Task { await SpotTimeZone.resolveIfNeeded(spot) }
        // The first spot: straight to its forecast.
        if isFirstSpot { router.selectedTab = 0 }
    }
}

/// Floating search field over the map with a material background.
private struct SearchBar: View {
    @Bindable var completer: PlaceSearchCompleter
    var isFocused: FocusState<Bool>.Binding
    var onSubmitFirst: (MKLocalSearchCompletion) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(text: $completer.query, prompt: Text("Search lakes, rivers, bays")) {
                Text("Search lakes, rivers, bays")
            }
            .focused(isFocused)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .onSubmit {
                if let first = completer.results.first {
                    onSubmitFirst(first)
                }
            }
            if !completer.query.isEmpty {
                Button {
                    completer.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Drop-down suggestions from MKLocalSearchCompleter.
private struct SearchSuggestionsList: View {
    let results: [MKLocalSearchCompletion]
    let onSelect: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.prefix(5).enumerated()), id: \.offset) { offset, item in
                if offset > 0 {
                    Divider()
                }
                Button {
                    onSelect(item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        if !item.subtitle.isEmpty {
                            Text(verbatim: item.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}

/// Horizontal pill for one saved spot, showing its current bite index dot and value when cached.
private struct SpotPill: View {
    let name: String
    let index: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let index {
                    Circle()
                        .fill(BiteScale.color(index))
                        .frame(width: 8, height: 8)
                    Text(verbatim: name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(verbatim: "\(Int(index.rounded()))")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(BiteScale.color(index))
                } else {
                    Text(verbatim: name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Which fish the water at a spot suits right now.
struct SpotOutlook: Equatable {
    var reading: Spot.WaterReading?
    /// Best first; empty without a water temperature or at a saltwater spot.
    var ranked: [SpeciesOutlook]
}

/// Custom annotation pin for a saved spot on the map.
private struct SpotAnnotationPin: View {
    let name: String
    let index: Double?
    /// The fish the water suits best now; shown under the name when it is biting above average.
    var best: SpeciesOutlook?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(index != nil ? BiteScale.color(index) : Theme.accent)
                if let index {
                    Text(verbatim: "\(Int(index.rounded()))")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "fish.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 34, height: 34)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)

            Text(verbatim: name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.5))

            if let best, best.index >= 50 {
                HStack(spacing: 4) {
                    best.species.image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 16)
                    Text(verbatim: best.species.localizedName)
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
                .background(BiteScale.color(best.index), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityValue: Text {
        let score = index.map { Text("Bite index") + Text(verbatim: " \(Int($0.rounded()))") } ?? Text(verbatim: "")
        guard let best, best.index >= 50 else { return score }
        return score + Text(verbatim: ", ") + Text("Best match right now") + Text(verbatim: ": \(best.species.localizedName)")
    }
}

/// Card for a tapped spot: the fish the water suits right now, with their bite index.
private struct SpeciesNowCard: View {
    let name: String
    let isSalt: Bool
    let outlook: SpotOutlook?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(.headline)
                        .lineLimit(1)
                    if let reading = outlook?.reading {
                        // °C or °F as the weather strip shows it.
                        let degrees = Measurement(value: reading.tempC, unit: UnitTemperature.celsius)
                            .formatted(.measurement(width: .abbreviated, usage: .weather,
                                                    numberFormatStyle: .number.precision(.fractionLength(0))))
                        Group {
                            switch reading {
                            case .measured: Text("Water \(degrees) · measured")
                            case .satellite: Text("Water about \(degrees) · satellite estimate")
                            case .modelled: Text("Water about \(degrees) · estimated from air")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }

            if let ranked = outlook?.ranked, !ranked.isEmpty {
                Text("Best match right now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(ranked.prefix(3), id: \.species) { item in
                    SpeciesNowRow(item: item)
                }
                Text("Conditions that suit each fish, not a survey of this water.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if isSalt, outlook != nil {
                // Weather is saved but no sea temperature has arrived for this spot yet.
                message("No sea temperature for this spot yet. Open it on the Forecast tab while online.")
            } else {
                message("Open this spot on the Forecast tab to download weather.")
            }
        }
        .card(padding: 14)
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct SpeciesNowRow: View {
    let item: SpeciesOutlook

    var body: some View {
        HStack(spacing: 12) {
            // A light tile, so dark fish (perch, pike) still read in dark mode.
            item.species.image
                .resizable()
                .scaledToFit()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(width: 72, height: 44)
                .background(Color(light: 0xEEF3F6, dark: 0xDCE6EC), in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.species.localizedName)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: BiteScale.label(item.index))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(BiteScale.color(item.index))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(BiteScale.color(item.index).opacity(0.18), in: .capsule)
                    .overlay(Capsule().strokeBorder(BiteScale.color(item.index).opacity(0.35), lineWidth: 0.5))
            }
            Spacer()
            IndexGauge(index: item.index, size: 36)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Reticle in the centre of the map: a dashed ring with a crosshair and a 4-decimal coordinate capsule below.
private struct CrosshairReticle: View {
    let center: CLLocationCoordinate2D?

    private var coordinateText: String? {
        guard let center else { return nil }
        let latHemisphere = center.latitude >= 0 ? "N" : "S"
        let lonHemisphere = center.longitude >= 0 ? "E" : "W"
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(4...4))
        let lat = abs(center.latitude).formatted(format)
        let lon = abs(center.longitude).formatted(format)
        return "\(lat)° \(latHemisphere)  \(lon)° \(lonHemisphere)"
    }

    var body: some View {
        let ringSize: CGFloat = 44
        ZStack {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .frame(width: ringSize, height: ringSize)
            Rectangle()
                .frame(width: 18, height: 1.5)
            Rectangle()
                .frame(width: 1.5, height: 18)
            Circle()
                .frame(width: 4, height: 4)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 2)
        .overlay(alignment: .top) {
            if let coordinateText {
                Text(verbatim: coordinateText)
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.5))
                    .offset(y: ringSize + 6)
            }
        }
    }
}

/// Completes place queries via `MKLocalSearchCompleter` and resolves a chosen completion via `MKLocalSearch` without location permission.
@MainActor
@Observable
private final class PlaceSearchCompleter: NSObject, @MainActor MKLocalSearchCompleterDelegate {
    /// Set while the field is filled with the chosen place's name, which is not a new search.
    @ObservationIgnored private var isShowingChoice = false

    var query = "" {
        didSet {
            guard !isShowingChoice else { return }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                results = []
                completer.cancel()
            } else if completer.queryFragment != trimmed {
                completer.queryFragment = trimmed
            }
        }
    }

    private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        // Lakes, rivers and bays are "physical features", which the completer offers from iOS 18.
        if #available(iOS 18.0, *) {
            completer.resultTypes = [.address, .pointOfInterest, .physicalFeature]
        } else {
            completer.resultTypes = [.address, .pointOfInterest]
        }
        completer.delegate = self
    }

    func clear() {
        query = ""
        results = []
        completer.cancel()
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> MKCoordinateRegion? {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return nil }
        // The chosen name goes in the field without asking for suggestions again.
        completer.cancel()
        isShowingChoice = true
        query = completion.title
        isShowingChoice = false
        results = []
        if let item = response.mapItems.first {
            let coord = item.placemark.coordinate
            let span = response.boundingRegion.span.latitudeDelta > 0
                ? response.boundingRegion.span
                : MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            return MKCoordinateRegion(center: coord, span: span)
        }
        return response.boundingRegion
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        results = []
    }
}
