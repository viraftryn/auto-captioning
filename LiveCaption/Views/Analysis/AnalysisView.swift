import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AnalysisView: View {
    @StateObject private var model = AnalysisViewModel()
    @StateObject private var transcriber = Transcriber()
    @State private var importing = false

    var body: some View {
        VStack(spacing: 12) {
            header
            content
        }
        .padding()
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.movie, .audiovisualContent, .audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.load(url: url) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { importing = true } label: {
                Label("Load video…", systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            if !model.fileName.isEmpty {
                Text(model.fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView("Load a recording", systemImage: "waveform",
                description: Text("Pick a video with overlapping speakers to test the separation."))
                .frame(maxHeight: .infinity)
        case .loading:
            VStack(spacing: 8) { ProgressView(); Text(model.progress).foregroundStyle(.secondary) }
                .frame(maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                description: Text(message))
                .frame(maxHeight: .infinity)
        case .ready:
            ready
        }
    }

    private var ready: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.speakers.isEmpty {
                    Text(model.summary).font(.callout).foregroundStyle(.secondary)
                } else {
                    speakerCards
                    controls
                    spectrogram("Original", model.originalSpectrogram)
                    separatedPanel
                    playback
                    transcriptSection
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var speakerCards: some View {
        HStack(spacing: 10) {
            ForEach(model.speakers) { speaker in
                Button { model.target = speaker.id } label: {
                    VStack(spacing: 4) {
                        Group {
                            if let thumb = speaker.thumbnail {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "person.fill").font(.title)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Speaker \(speaker.id)").font(.caption.weight(.semibold))
                    }
                    .padding(6)
                    .background(model.target == speaker.id ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity threshold: \(String(format: "%.3f", model.sensitivity))").font(.caption)
                Spacer()
                Text(model.overlapText).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: $model.sensitivity, in: 0.001...0.020) { editing in
                if !editing { model.recompute() }
            }
            Toggle("Silence the target when their lips aren't moving", isOn: $model.gateToTarget)
                .font(.caption)
                .onChange(of: model.gateToTarget) { model.recompute() }
        }
    }

    @ViewBuilder private var separatedPanel: some View {
        if let error = model.separationError {
            modelNotice(error, systemImage: "cpu", tint: .orange)
        } else if let note = model.targetNote {
            modelNotice(note, systemImage: "person.fill.questionmark", tint: .secondary)
        } else {
            spectrogram(model.separating ? "Separated · running SepFormer…" : "Separated · Speaker \(model.target)",
                        model.separatedSpectrogram)
        }
    }

    private func modelNotice(_ message: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Separated").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(message).font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var playback: some View {
        HStack(spacing: 10) {
            Button { model.playOriginal() } label: { Label("Play original", systemImage: "play.fill") }
            Button { model.playSeparated() } label: { Label("Play separated", systemImage: "play.circle.fill") }
                .disabled(model.separatedSpectrogram == nil || model.separating)
            Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            Spacer()
        }
        .controlSize(.large)
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 4)
            HStack(spacing: 10) {
                Button {
                    Task {
                        await transcriber.transcribe(model.originalAudio)
                        model.buildAttribution(from: transcriber.allWords)
                    }
                } label: {
                    Label("Transcribe original (Indonesian)", systemImage: "text.bubble")
                }
                .controlSize(.large)
                .disabled(transcriber.isBusy || model.originalAudio.isEmpty)

                switch transcriber.status {
                case .loadingModel:
                    ProgressView().controlSize(.small)
                    Text("Loading model…").font(.caption).foregroundStyle(.secondary)
                case .transcribing:
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                default:
                    EmptyView()
                }
                Spacer()
            }

            if !model.attributedTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.attributedTranscript) { utterance in
                        HStack(alignment: .top, spacing: 8) {
                            Text(utterance.speaker != nil ? "Speaker \(utterance.speaker!)" : "?")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(speakerColor(utterance.speaker), in: Capsule())
                                .foregroundStyle(.white)
                            Text(utterance.text).font(.callout).textSelection(.enabled)
                            Spacer()
                            Text(String(format: "%.1f", utterance.start))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func spectrogram(_ title: String, _ image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black)
                if let image { Image(nsImage: image).resizable().interpolation(.none).padding(1) }
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func speakerColor(_ id: Int?) -> Color {
        guard let id else { return .gray }
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
        return palette[(id - 1) % palette.count]
    }
}
