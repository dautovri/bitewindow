import StoreKit
import SwiftUI

/// Houby, the developer's mushroom forecast app, shown in Settings and once on a good day.
/// Nothing is collected or sent: the App Store sheet carries only the campaign and provider
/// tokens, which App Store Connect uses to count downloads that came from here.
enum CrossPromo {
    static let houbyAppID = "6829188074"
    static let campaignToken = "app-bitecurve"
    static let providerToken = "127464313"

    /// UserDefaults: how many times the app has been started.
    static let launchCountKey = "launchCount"
    /// UserDefaults: the one-time card on a spot was dismissed or tapped; it never comes back.
    static let promoDoneKey = "houbyPromoDone"
    /// The one-time card waits for the third launch, so a first run never sees it.
    static let minimumLaunches = 3

    /// The App Store sheet for Houby, shown inside the app.
    static var overlayConfiguration: SKOverlay.Configuration {
        let configuration = SKOverlay.AppConfiguration(appIdentifier: houbyAppID, position: .bottom)
        configuration.campaignToken = campaignToken
        configuration.providerToken = providerToken
        return configuration
    }

    /// Whether the one-time card belongs on a spot's forecast: a good window (the bite alerts'
    /// default "Strong bite" bar) is on screen, the app was started at least three times, the
    /// welcome screen is behind the angler, and the card was never dismissed or tapped.
    static func offersOnSpot(windowIndex: Double?, launches: Int, didOnboard: Bool, done: Bool) -> Bool {
        guard let windowIndex, !done, didOnboard else { return false }
        return launches >= minimumLaunches && windowIndex >= goodWindowIndex
    }

    /// `-BCHoubyAnyWindow YES` lets any window count as good in Debug builds (UI checks on
    /// days without a strong bite).
    private static var goodWindowIndex: Double {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "BCHoubyAnyWindow") { return 0 }
        #endif
        return BiteAlerts.defaultThreshold
    }

    /// Counts one start of the app.
    static func recordLaunch(in defaults: UserDefaults = .standard) {
        defaults.set(defaults.integer(forKey: launchCountKey) + 1, forKey: launchCountKey)
    }
}

/// The Houby card: a symbol, the name and one line. Tapping it calls `onOpen`; with
/// `onDismiss` set, a close button hides it for good.
struct HoubyPromoCard: View {
    let onOpen: () -> Void
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    HoubySymbol()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Houby")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Mushroom forecast for forests near you")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if onDismiss == nil {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Houby"))
            .accessibilityValue(Text("Mushroom forecast for forests near you"))
            .accessibilityHint(Text("Shows Houby in the App Store"))
            .accessibilityAddTraits(.isButton)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Theme.well, in: .circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Hide"))
            }
        }
    }
}

/// A forest-green tile with a leaf, standing in for the app's icon (no copied artwork).
private struct HoubySymbol: View {
    @ScaledMetric(relativeTo: .headline) private var side: CGFloat = 44

    var body: some View {
        Image(systemName: "leaf.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Color(red: 0.24, green: 0.45, blue: 0.27), in: .rect(cornerRadius: side * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The one-time card on a spot's forecast, with its heading.
struct HoubySpotPromo: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "More from the developer")
            HoubyPromoCard(onOpen: onOpen, onDismiss: onDismiss)
                .card(padding: 12)
        }
        .transition(.opacity)
    }
}
