import SwiftUI

/// First launch: what the app does in three lines, then straight to finding a water. The
/// point is a real forecast for the angler's own spot within the first minute.
struct WelcomeView: View {
    enum Choice { case locate, search, skip }

    /// UserDefaults flag: offer the Pro trial once, after the first spot has a forecast.
    static let offerTrialKey = "offerTrialAfterFirstSpot"

    let onChoice: (Choice) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image(systemName: "fish.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Theme.accent)
                        .padding(22)
                        .background(Theme.accent.opacity(0.14), in: .circle)
                        .accessibilityHidden(true)
                    Text("Know when the fish bite")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text("A bite forecast for your own lake, river or stretch of coast.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 36)

                VStack(alignment: .leading, spacing: 18) {
                    WelcomePoint(symbol: "clock.fill", title: "The best two hours of the day",
                                 detail: "A 0–100 bite index from light, wind, pressure, water temperature, moon and tide.")
                    WelcomePoint(symbol: "mappin.and.ellipse", title: "For the water you fish",
                                 detail: "Drop a pin on any lake or sea. No account needed.")
                    WelcomePoint(symbol: "checkmark.seal.fill", title: "Honest about what it knows",
                                 detail: "It is an estimate from published fisheries research, and it says so.")
                }
                .padding(.horizontal, 4)

                VStack(spacing: 12) {
                    Button {
                        onChoice(.locate)
                    } label: {
                        Label("Use my location", systemImage: "location.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Theme.accent)

                    Button {
                        onChoice(.search)
                    } label: {
                        Label("Search for a lake or sea", systemImage: "magnifyingglass")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(Theme.accent)

                    Button("Look around first") { onChoice(.skip) }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background.ignoresSafeArea())
    }
}

private struct WelcomePoint: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
