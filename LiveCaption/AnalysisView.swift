import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Development "lab" for evaluating video-guided spectral gating on a recorded
/// file: load a clip, see each speaker (face + pitch), tune the overlap
/// sensitivity, then compare original vs the separated target (spectrogram + A/B).
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
                    if let warning = model.pitchWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    controls
                    spectrogram("Original", model.originalSpectrogram)
                    spectrogram(model.separating ? "Separated · computing…" : "Separated · Speaker \(model.target)",
                                model.separatedSpectrogram)
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
                        Text(speaker.f0 != nil ? "\(Int(speaker.f0!)) Hz" : "—")
                            .font(.caption2).foregroundStyle(.secondary)
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
                Text("Overlap sensitivity: \(String(format: "%.3f", model.sensitivity))").font(.caption)
                Spacer()
                Text(model.overlapText).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: $model.sensitivity, in: 0.001...0.020) { editing in
                if !editing { model.recompute() }
            }
            Toggle("Mask whenever the speaker is active (not just overlaps)", isOn: $model.alwaysMask)
                .font(.caption)
                .onChange(of: model.alwaysMask) { model.recompute() }
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

/// Orchestrates the offline pipeline off the main thread.
final class AnalysisViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready, failed(String) }
    struct SpeakerInfo: Identifiable { let id: Int; let f0: Double?; let thumbnail: NSImage? }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress = ""
    @Published private(set) var fileName = ""
    @Published private(set) var summary = ""
    @Published private(set) var speakers: [SpeakerInfo] = []
    @Published private(set) var originalSpectrogram: NSImage?
    @Published private(set) var separatedSpectrogram: NSImage?
    @Published private(set) var separating = false
    @Published var target: Int = 0 { didSet { if oldValue != target { recompute() } } }
    @Published var sensitivity: Double = 0.005
    @Published var alwaysMask: Bool = false
    @Published private(set) var attributedTranscript: [AttributedUtterance] = []

    let player = AudioPlayer()
    private let engine = SeparationEngine()
    private let sr = MediaLoader.sampleRate

    private var audio: [Float] = []
    private var separated: [Float] = []
    private var timeline = VideoAnalyzer.Timeline(frames: [], speakerIDs: [], thumbnails: [:])
    private var f0: [Int: Double] = [:]
    private var f0Threshold: Double?

    var overlapText: String {
        guard timeline.hasSpeakers else { return "" }
        return String(format: "overlap %.1fs", timeline.overlapDuration(threshold: sensitivity))
    }

    /// Warn when two speakers' pitches are too close for harmonic separation.
    var pitchWarning: String? {
        let pitches = speakers.compactMap { $0.f0 }.sorted()
        guard pitches.count >= 2 else { return nil }
        for i in 1..<pitches.count where pitches[i] - pitches[i - 1] < 20 {
            return "Two speakers have nearly identical pitch — harmonic masking can't separate those (only pitch-distinct voices)."
        }
        return nil
    }

    func load(url: URL) {
        state = .loading
        progress = "Reading audio…"
        originalSpectrogram = nil
        separatedSpectrogram = nil
        separated = []
        speakers = []
        attributedTranscript = []
        f0Threshold = nil
        let accessing = url.startAccessingSecurityScopedResource()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let audio = try MediaLoader.loadAudio(url: url)
                DispatchQueue.main.async { self.progress = "Analyzing video…" }
                let timeline = try VideoAnalyzer.analyze(url: url) { frac in
                    DispatchQueue.main.async { self.progress = "Analyzing video… \(Int(frac * 100))%" }
                }
                let originalImage = SpectrogramImage.make(from: self.engine.spectrogram(of: audio))
                let infos = timeline.speakerIDs.map {
                    SpeakerInfo(id: $0, f0: nil, thumbnail: timeline.thumbnails[$0])
                }

                DispatchQueue.main.async {
                    self.audio = audio
                    self.timeline = timeline
                    self.originalSpectrogram = originalImage
                    self.speakers = infos
                    self.fileName = url.lastPathComponent
                    self.summary = timeline.hasSpeakers ? "" :
                        "No speakers detected in the video — needs detected, moving faces (check the clip isn't rotated)."
                    self.state = .ready
                    if let first = timeline.speakerIDs.first {
                        if self.target == first { self.recompute() } else { self.target = first }
                    }
                }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// Re-derive F0 (only if sensitivity changed) + re-run separation. Cheap —
    /// no video decoding, so it's fine on every slider release / target switch.
    func recompute() {
        guard !audio.isEmpty, timeline.hasSpeakers else { return }
        separating = true
        let target = self.target
        let audioBuf = self.audio
        let tl = self.timeline
        let threshold = self.sensitivity
        let always = self.alwaysMask
        let sr = self.sr
        let needF0 = (f0Threshold != threshold)
        let existingF0 = self.f0

        DispatchQueue.global(qos: .userInitiated).async {
            var f0 = existingF0
            if needF0 {
                f0 = [:]
                for id in tl.speakerIDs {
                    let solo = Self.soloAudio(for: id, audio: audioBuf, timeline: tl, threshold: threshold, sr: sr)
                    if let pitch = PitchEstimator.estimateF0(solo, sampleRate: sr) { f0[id] = pitch }
                }
            }
            let (samples, spec) = self.engine.separate(audio: audioBuf, timeline: tl, target: target,
                                                       f0: f0[target], threshold: threshold, alwaysMask: always)
            let image = SpectrogramImage.make(from: spec)
            DispatchQueue.main.async {
                if needF0 {
                    self.f0 = f0
                    self.f0Threshold = threshold
                    self.speakers = self.speakers.map {
                        SpeakerInfo(id: $0.id, f0: f0[$0.id], thumbnail: $0.thumbnail)
                    }
                }
                self.separated = samples
                self.separatedSpectrogram = image
                self.separating = false
            }
        }
    }

    func playOriginal() { player.play(audio) }
    func playSeparated() { if !separated.isEmpty { player.play(separated) } }
    func stop() { player.stop() }

    var originalAudio: [Float] { audio }

    func buildAttribution(from words: [TranscriptWord]) {
        attributedTranscript = Attribution.attribute(words: words, timeline: timeline, threshold: sensitivity)
    }

    private static func soloAudio(for speaker: Int, audio: [Float],
                                  timeline: VideoAnalyzer.Timeline, threshold: Double, sr: Double) -> [Float] {
        var result: [Float] = []
        let frames = timeline.frames
        for i in 0..<frames.count {
            let active = Set(frames[i].activity.compactMap { $0.value >= threshold ? $0.key : nil })
            if active == [speaker] {
                let tStart = frames[i].t
                let tEnd = (i + 1 < frames.count) ? frames[i + 1].t : tStart + 0.05
                let s = max(0, Int(tStart * sr))
                let e = min(audio.count, Int(tEnd * sr))
                if e > s { result.append(contentsOf: audio[s..<e]) }
            }
        }
        return result
    }
}
