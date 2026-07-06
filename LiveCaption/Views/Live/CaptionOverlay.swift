import SwiftUI

/// Live captions overlaid on the clean camera view: the last few lines of
/// transcript over a black gradient that fades up from the bottom of the video so
/// the text stays readable over any scene. When more than one speaker is present in
/// the visible lines, each line is prefixed with a plain-white "[Speaker N]" /
/// "[Off-Cam Speaker]" tag; a single speaker stays clean text.
struct CaptionOverlay: View {
    @ObservedObject var engine: LiveCaptionEngine

    /// How many recent lines to keep on screen.
    private let visibleLines = 3

    private var recentLines: [AttributedUtterance] { Array(engine.transcript.suffix(visibleLines)) }

    /// Show the speaker tag only when the visible lines involve more than one speaker.
    private var showSpeakerTag: Bool { Set(recentLines.map(\.speaker)).count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine.transcript.isEmpty {
                Text(engine.captioning ? "Listening…" : "Captions paused")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ForEach(recentLines) { line in
                    Text(showSpeakerTag ? "\(speakerTag(line.speaker)) \(line.text)" : line.text)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 60)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        )
        .animation(.easeOut(duration: 0.2), value: engine.transcript.count)
    }

    private func speakerTag(_ id: Int?) -> String {
        id != nil ? "[Speaker \(id!)]" : "[Off-Cam Speaker]"
    }
}
