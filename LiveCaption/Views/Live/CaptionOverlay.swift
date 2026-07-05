import SwiftUI

/// Live captions overlaid on the clean camera view: the last few lines of
/// transcript (plain text, no speaker labels) over a black gradient that fades up
/// from the bottom of the video so the text stays readable over any scene.
struct CaptionOverlay: View {
    @ObservedObject var engine: LiveCaptionEngine

    /// How many recent lines to keep on screen.
    private let visibleLines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine.transcript.isEmpty {
                Text(engine.captioning ? "Listening…" : "Captions paused")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ForEach(engine.transcript.suffix(visibleLines)) { line in
                    Text(line.text)
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
}
