import BiteCore
import CoreTransferable
import SwiftUI
import UIKit

/// A day's forecast at a spot as a picture to send to a fishing partner: the index, the best
/// window and the date on a card, drawn only when the share sheet asks for it.
struct ForecastShare: Transferable {
    let spotName: String
    let day: Date
    let window: BiteWindow
    let timeZone: TimeZone

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { share in
            try await share.png()
        }
        .suggestedFileName { "BiteCurve \($0.spotName)" }
    }

    enum RenderError: Error { case failed }

    @MainActor
    private func png() throws -> Data {
        guard let data = uiImage(scale: 3)?.pngData() else { throw RenderError.failed }
        return data
    }

    @MainActor
    func uiImage(scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: ForecastShareCard(share: self).environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.uiImage
    }

    /// A small copy of the card for the share sheet's header.
    @MainActor
    var thumbnail: Image {
        uiImage(scale: 1).map(Image.init(uiImage:)) ?? Image(systemName: "fish.fill")
    }
}

/// The picture itself. Always the dark palette: it has to read in any chat.
struct ForecastShareCard: View {
    let share: ForecastShare

    var body: some View {
        let index = share.window.meanIndex
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "fish.fill").foregroundStyle(Theme.accent)
                Text(verbatim: "BiteCurve").font(.headline)
                Spacer()
                Text(verbatim: share.day.formatted(.dateTime.weekday(.wide).month().day(), in: share.timeZone))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: share.spotName)
                .font(.title.bold())
                .lineLimit(2)
            HStack(spacing: 18) {
                IndexGauge(index: index, size: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Best window").font(.subheadline).foregroundStyle(.secondary)
                    Text(verbatim: "\(share.window.start.clock(in: share.timeZone)) – \(share.window.end.clock(in: share.timeZone))")
                        .font(.title2.bold())
                        .monospacedDigit()
                    Text(verbatim: BiteScale.label(index))
                        .font(.headline)
                        .foregroundStyle(BiteScale.color(index))
                }
            }
            Text("Bite index 0–100. An estimate, not a guarantee.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 380, alignment: .leading)
        .foregroundStyle(.white)
        .background(Color(red: 0.027, green: 0.067, blue: 0.102))
    }
}
