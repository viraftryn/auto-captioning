import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Development "lab" for evaluating the spectral gating on a recorded file:
/// load a video/audio file, view its spectrogram, and play it back.
/// (Stage 3a — masking + A/B separated playback is added next.)
struct AnalysisView: View {
    @StateObject private var model = AnalysisViewModel()
    @State private var importing = false

    var body: some View {
        VStack(spacing: 12) {
            header
            content
            Spacer(minLength: 0)
        }
        .padding()
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.movie, .audiovisualContent, .audio],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.load(url: url)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { importing = true } label: {
                Label("Load video / audio…", systemImage: "square.and.arrow.down")
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
                description: Text("Pick a video or audio file to analyze its spectrum."))
                .frame(maxHeight: .infinity)
        case .loading:
            ProgressView("Analyzing…").frame(maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                description: Text(message))
                .frame(maxHeight: .infinity)
        case .ready:
            readyContent
        }
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Original spectrogram").font(.caption).foregroundStyle(.secondary)
            if let img = model.spectrogram {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Button { model.playOriginal() } label: { Label("Play original", systemImage: "play.fill") }
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                Spacer()
                Text(model.durationText).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

/// Loads + analyzes a media file off the main thread.
final class AnalysisViewModel: ObservableObject {
    enum State: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var spectrogram: NSImage?
    @Published private(set) var fileName = ""
    @Published private(set) var durationText = ""

    let player = AudioPlayer()
    private(set) var samples: [Float] = []

    func load(url: URL) {
        state = .loading
        spectrogram = nil
        let accessing = url.startAccessingSecurityScopedResource()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let audio = try MediaLoader.loadAudio(url: url)
                let stft = STFTProcessor(fftSize: 1024, hopSize: 256)
                let spec = stft.forward(audio)
                let image = SpectrogramImage.make(from: spec)
                let seconds = Double(audio.count) / MediaLoader.sampleRate
                DispatchQueue.main.async {
                    self.samples = audio
                    self.spectrogram = image
                    self.fileName = url.lastPathComponent
                    self.durationText = String(format: "%.1fs · %d samples", seconds, audio.count)
                    self.state = .ready
                }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    func playOriginal() { player.play(samples) }
    func stop() { player.stop() }
}
