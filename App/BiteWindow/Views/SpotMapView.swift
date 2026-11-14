import BiteCore
import MapKit
import Observation
import SwiftData
import SwiftUI

/// Spots on a map. A spot is dropped at the map centre, so no location
/// permission is needed.
struct SpotMapView: View {
    @Query private var spots: [Spot]
    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementManager.self) private var entitlements
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
    @State private var appearances = 0
    @State private var searchCompleter = PlaceSearchCompleter()
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(spots) { spot in
                    let index = indices[spot.id]
                    Annotation(spot.name, coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)) {
                        SpotAnnotationPin(name: spot.name, index: index)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(isHybrid ? .hybrid : .standard)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                center = context.region.center
            }
            .overlay {
                CrosshairReticle(center: center)
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
            .task(id: "\(appearances)|\(lastPrefetch)|\(spots.map { "\($0.id)\($0.waterRaw)\($0.speciesRaw)\($0.waterTempC ?? -999)\($0.timeZoneID ?? "")" }.joined())") {
                var fresh: [UUID: Double] = [:]
                for spot in spots {
                    // The tide counts at saltwater spots, as on the Forecast tab (saved station first).
                    let tide = spot.isSalt
                        ? await ForecastService.shared.tideStation(latitude: spot.latitude, longitude: spot.longitude) : nil
                    fresh[spot.id] = currentIndex(for: spot, tide: tide)
                }
                indices = fresh
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Name this spot", isPresented: $showNamePrompt) {
                TextField("Name", text: $newName)
                Button("Save") { addSpot() }
                Button("Cancel", role: .cancel) {}
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
        Button {
            if !entitlements.isPro && spots.count >= EntitlementManager.freeSpotLimit {
                showPaywall = true
            } else {
                newName = ""
                showNamePrompt = true
            }
        } label: {
            Label("Add spot at crosshair", systemImage: "mappin.and.ellipse")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .tint(Theme.accent)
        .controlSize(.large)
        // The crosshair position is known once the map has reported its camera.
        .disabled(center == nil)
        .frame(maxWidth: Theme.readableWidth)
        .padding()
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

    private func addSpot() {
        guard let center else { return }
        // Checked again here: the count can change while the name prompt is open.
        guard entitlements.isPro || spots.count < EntitlementManager.freeSpotLimit else {
            showPaywall = true
            return
        }
        let name = newName.trimmingCharacters(in: .whitespaces)
        let spot = Spot(name: name.isEmpty ? String(localized: "Spot \(spots.count + 1)") : name,
                        latitude: center.latitude, longitude: center.longitude)
        modelContext.insert(spot)
        // Saved at once: the system's own save can come seconds later, and a spot must not be
        // lost if the app is closed right after it was added.
        try? modelContext.save()
        Task { await SpotTimeZone.resolveIfNeeded(spot) }
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

/// Custom annotation pin for a saved spot on the map.
private struct SpotAnnotationPin: View {
    let name: String
    let index: Double?

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
