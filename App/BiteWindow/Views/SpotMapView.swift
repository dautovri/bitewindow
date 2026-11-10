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
                    Marker(spot.name, coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude))
                }
            }
            .onMapCameraChange { context in center = context.region.center }
            .overlay { Image(systemName: "plus").font(.title2).allowsHitTesting(false) }
            .safeAreaInset(edge: .bottom) {
                Button("Add spot at crosshair") {
                    if !entitlements.isPro && spots.count >= EntitlementManager.freeSpotLimit {
                        showPaywall = true
                    } else {
                        newName = ""
                        showNamePrompt = true
                    }
                }
                .buttonStyle(.borderedProminent)
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
        let name = newName.trimmingCharacters(in: .whitespaces)
        modelContext.insert(Spot(name: name.isEmpty ? "Spot \(spots.count + 1)" : name,
                                 latitude: center.latitude, longitude: center.longitude))
    }
}
