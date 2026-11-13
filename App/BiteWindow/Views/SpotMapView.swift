import MapKit
import SwiftData
import SwiftUI

/// Spots on a map. A spot is dropped at the map centre, so no location
/// permission is needed. Bathymetry tile overlays and offline packs are not built yet.
struct SpotMapView: View {
    @Query private var spots: [Spot]
    @Environment(\.modelContext) private var modelContext
    @Environment(EntitlementManager.self) private var entitlements

    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var newName = ""
    @State private var showNamePrompt = false
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(spots) { spot in
                    Marker(spot.name, systemImage: "fish.fill",
                           coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude))
                        .tint(.teal)
                }
            }
            .mapStyle(.hybrid)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange { context in center = context.region.center }
            .overlay {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .safeAreaInset(edge: .bottom) {
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
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // The crosshair position is known once the map has reported its camera.
                .disabled(center == nil)
                .padding()
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

    private func addSpot() {
        guard let center else { return }
        // Checked again here: the count can change while the name prompt is open.
        guard entitlements.isPro || spots.count < EntitlementManager.freeSpotLimit else {
            showPaywall = true
            return
        }
        let name = newName.trimmingCharacters(in: .whitespaces)
        modelContext.insert(Spot(name: name.isEmpty ? String(localized: "Spot \(spots.count + 1)") : name,
                                 latitude: center.latitude, longitude: center.longitude))
    }
}
