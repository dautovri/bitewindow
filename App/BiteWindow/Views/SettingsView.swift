import StoreKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(EntitlementManager.self) private var entitlements
    @Environment(PressureSampler.self) private var sampler
    @State private var showPaywall = false
    /// Sampling itself is started and stopped by `RootView`, which observes the same key.
    @AppStorage(PressureSampler.enabledKey) private var livePressure = false
    @AppStorage(ForecastService.lastPrefetchKey) private var lastPrefetch = 0.0
    @State private var downloading = false
    @State private var downloadResult: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if entitlements.isPro {
                        ProActiveCard()
                    } else {
                        ProBannerCard { showPaywall = true }
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Section {
                    Toggle("Live pressure from my phone", isOn: $livePressure)
                        .disabled(!sampler.isAvailable)
                    if let hPa = sampler.latestHPa {
                        LabeledContent("Station pressure", value: Measurement(value: hPa, unit: UnitPressure.hectopascals).formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1)))))
                    }
                } footer: {
                    if sampler.isAvailable {
                        Text("Samples are stored on this device only, while the app is open, and deleted after three days. During a trip they replace the forecast pressure trend at that spot.")
                    } else {
                        Text("This device has no barometer.")
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    Button {
                        downloading = true
                        Task {
                            let result = await OfflineStore.refresh()
                            downloadResult = String(localized: "Saved \(result.saved) of \(result.total) spots")
                            downloading = false
                        }
                    } label: {
                        if downloading {
                            HStack {
                                ProgressView()
                                Text("Downloading…")
                            }
                        } else {
                            Label("Download forecasts for all spots", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(downloading)
                    if let downloadResult {
                        Text(verbatim: downloadResult).foregroundStyle(.secondary)
                    }
                    if lastPrefetch > 0 {
                        Text("Last download: \(Date(timeIntervalSince1970: lastPrefetch).formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Offline")
                } footer: {
                    Text("Forecasts for your spots are saved on this device and stay usable for about 10 days. Open the app or tap the button while you still have signal. With no saved forecast, the score uses sun, moon and tide only.")
                }
                .listRowBackground(Theme.card)

                Section {
                    NavigationLink("How the score works") { HowItWorksView() }
                }
                .listRowBackground(Theme.card)

                Section {
                    Link("Support", destination: Legal.support)
                    Link("Privacy Policy", destination: Legal.privacy)
                    Link("Terms of Use", destination: Legal.terms)
                }
                .listRowBackground(Theme.card)
            }
            .frame(maxWidth: Theme.readableWidth)
            .frame(maxWidth: .infinity)
            .screenBackground()
            .tint(Theme.accent)
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }
}

private struct ProBannerCard: View {
    let onSeePlans: () -> Void

    private static let symbols = ["chart.xyaxis.line", "water.waves", "fish.fill", "calendar"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack(spacing: 10) {
                Image(systemName: "fish.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("BiteCurve Pro")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }

            Text("Hourly bite curve, tide curve, expected catch tuned to your log, 10-day outlook and unlimited spots.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.1), in: .rect(cornerRadius: Theme.wellRadius, style: .continuous))
                }
            }
            .accessibilityHidden(true)

            Button(action: onSeePlans) {
                Text("See Pro plans")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.deepWater, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }
}

private struct ProActiveCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Pro is active")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .card()
    }
}

struct PaywallView: View {
    @Environment(EntitlementManager.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @State private var loadFailed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if loadFailed {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "fish")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("BiteCurve Pro").font(.title2.bold())
                    Text("Could not load subscription plans.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        loadFailed = false
                        attempt += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    Button("Restore Purchases") {
                        Task {
                            try? await AppStore.sync()
                            await entitlements.refresh()
                            if entitlements.isPro { dismiss() }
                        }
                    }
                    Spacer()
                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: Legal.terms)
                        Link("Privacy Policy", destination: Legal.privacy)
                    }
                    .font(.footnote)
                }
                .padding()
                .frame(maxWidth: Theme.readableWidth)
                .frame(maxWidth: .infinity)
            } else {
                SubscriptionStoreView(productIDs: EntitlementManager.subscriptionIDs) {
                    VStack(spacing: 8) {
                        Image(systemName: "fish")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                        // Resolved here, in the app's language: inside the store view the locale is
                        // the App Store storefront's, so a plain key came out in English.
                        Text(verbatim: String(localized: "BiteCurve Pro")).font(.title2.bold())
                        // Scannable rows instead of a paragraph.
                        VStack(alignment: .leading, spacing: 10) {
                            ProBenefit(symbol: "chart.xyaxis.line", text: String(localized: "Hourly bite and tide curves"))
                            ProBenefit(symbol: "calendar", text: String(localized: "10-day outlook for every spot"))
                            ProBenefit(symbol: "fish.fill", text: String(localized: "Expected catch tuned to your log"))
                            ProBenefit(symbol: "mappin.and.ellipse", text: String(localized: "Unlimited spots"))
                        }
                        .padding(.top, 6)
                    }
                    .padding()
                    .frame(maxWidth: Theme.readableWidth)
                }
                .id(attempt)
                .backgroundStyle(Theme.card)
                .tint(Theme.accent)
                .scrollContentBackground(.hidden)
                .storeButton(.visible, for: .restorePurchases)
                // Required on auto-renewable subscription paywalls (App Review 3.1.2).
                .subscriptionStorePolicyDestination(url: Legal.privacy, for: .privacyPolicy)
                .subscriptionStorePolicyDestination(url: Legal.terms, for: .termsOfService)
                .onInAppPurchaseCompletion { _, _ in
                    await entitlements.refresh()
                    if entitlements.isPro { dismiss() }
                }
            }
        }
        .tint(Theme.accent)
        .background(Theme.background.ignoresSafeArea())
        .task(id: attempt) {
            await verifyProductsLoad()
        }
    }

    private func verifyProductsLoad() async {
        loadFailed = false
        let loaded = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                guard let products = try? await Product.products(for: EntitlementManager.subscriptionIDs) else {
                    return false
                }
                return !products.isEmpty
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(15))
                    return false
                } catch {
                    return true
                }
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !Task.isCancelled && !loaded {
            loadFailed = true
        }
    }
}

/// One line of what Pro adds, on the paywall. Text is resolved by the caller (see PaywallView).
private struct ProBenefit: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HowItWorksView: View {
    var body: some View {
        List {
            Section {
                Text("The bite index combines light, water temperature, wind, pressure trend, moon position and tide into a 0–100 score. 50 is neutral. It is an estimate, not a guarantee.")
            }
            .listRowBackground(Theme.card)

            Section("What the evidence supports") {
                Text("Low light at dawn and dusk, suitable water temperature and moderate wind have the best support in fisheries studies, so they carry the most weight.")
                Text("Barometric pressure is used only as a sign of passing weather fronts. Studies have not shown that pressure itself makes fish feed.")
                Text("Solunar tables failed to predict trout catch rates in a six-year study and showed modest effects for muskellunge. The moon gets a small weight.")
            }
            .listRowBackground(Theme.card)

            Section("Weights") {
                Text("The starting weights are estimates. Your trip log, blank trips included, already scales the expected catch at each spot. Tuning the weights themselves to your waters is not built yet.")
            }
            .listRowBackground(Theme.card)
        }
        .frame(maxWidth: Theme.readableWidth)
        .frame(maxWidth: .infinity)
        .screenBackground()
        .navigationTitle("How the score works")
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Legal pages linked from Settings and the paywall. The same privacy URL goes
/// in App Store Connect; terms are Apple's standard EULA.
enum Legal {
    static let support = URL(string: "https://apps.dautov.dev/bitecurve/")!
    static let privacy = URL(string: "https://apps.dautov.dev/bitecurve/privacy/")!
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
