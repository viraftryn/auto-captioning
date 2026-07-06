import SwiftUI

/// Streaming speaker-attributed transcript shown under the live camera. Observes
/// the `LiveCaptionEngine`'s published `transcript` and appends a line each time a
/// chunk finishes transcribing, auto-scrolling to the newest.
struct LiveTranscriptView: View {
    @ObservedObject var engine: LiveCaptionEngine

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Live captions", systemImage: "captions.bubble")
                .font(.subheadline.weight(.semibold))

            Toggle("", isOn: $engine.captioning)
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Pause or resume live captions")

            Picker("Model", selection: $engine.model) {
                ForEach(WhisperModelSize.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(engine.isBusy)

            if engine.isBusy {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
            } else if let error = engine.errorText {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
            }

            Spacer()

            if engine.separationUnavailable {
                Label("overlap model missing", systemImage: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Overlapping speech was detected, but the SepFormer model isn't installed. "
                          + "Run tools/sepformer/convert_sepformer.py and rebuild; until then overlaps "
                          + "fall back to single-speaker.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if engine.transcript.isEmpty {
                        Text(engine.captioning
                             ? "Listening… captions will appear here."
                             : "Captions paused.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    ForEach(engine.transcript) { row($0) }
                }
                .padding(12)
            }
            .onChange(of: engine.transcript.count) {
                if let last = engine.transcript.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ utterance: AttributedUtterance) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(utterance.speaker != nil ? "Speaker \(utterance.speaker!)" : "Off-Cam Speaker")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(speakerColor(utterance.speaker), in: Capsule())
                .foregroundStyle(.white)
            Text(utterance.text)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(String(format: "%.1f", utterance.start))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .id(utterance.id)
    }

    private func speakerColor(_ id: Int?) -> Color {
        guard let id else { return .gray }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        return palette[(id - 1) % palette.count]
    }
}
