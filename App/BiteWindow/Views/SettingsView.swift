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
                Section("BiteWindow Pro") {
                    if entitlements.isPro {
                        Label("Pro is active", systemImage: "checkmark.seal")
                    } else {
                        Button("See Pro plans") { showPaywall = true }
                    }
                }

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

                Section {
                    NavigationLink("How the score works") { HowItWorksView() }
                }

                Section {
                    Link("Privacy Policy", destination: Legal.privacy)
                    Link("Terms of Use", destination: Legal.terms)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }
}

struct PaywallView: View {
    @Environment(EntitlementManager.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SubscriptionStoreView(productIDs: EntitlementManager.subscriptionIDs) {
            VStack(spacing: 8) {
                Image(systemName: "fish").font(.largeTitle)
                Text("BiteWindow Pro").font(.title2.bold())
                Text("Hourly bite curve, tide curve, expected catch tuned to your log, 10-day outlook and unlimited spots.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
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

struct HowItWorksView: View {
    var body: some View {
        List {
            Section {
                Text("The bite index combines light, water temperature, wind, pressure trend, moon position and tide into a 0–100 score. 50 is neutral. It is an estimate, not a guarantee.")
            }
            Section("What the evidence supports") {
                Text("Low light at dawn and dusk, suitable water temperature and moderate wind have the best support in fisheries studies, so they carry the most weight.")
                Text("Barometric pressure is used only as a sign of passing weather fronts. Studies have not shown that pressure itself makes fish feed.")
                Text("Solunar tables failed to predict trout catch rates in a six-year study and showed modest effects for muskellunge. The moon gets a small weight.")
            }
            Section("Weights") {
                Text("The starting weights are estimates. Your trip log, blank trips included, already scales the expected catch at each spot. Tuning the weights themselves to your waters is not built yet.")
            }
        }
        .navigationTitle("How the score works")
    }
}

/// Legal pages linked from Settings and the paywall. The same privacy URL goes
/// in App Store Connect; terms are Apple's standard EULA.
enum Legal {
    static let privacy = URL(string: "https://dautovri.com/bitewindow-privacy")!
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
