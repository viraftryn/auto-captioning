import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Development "lab" for evaluating neural speaker separation on a recorded file:
/// load a clip, see each detected speaker (face), then compare the original vs the
/// SepFormer-separated target (spectrogram + A/B playback). SepFormer is blind, so
/// its output streams are matched back to faces via lip-activity correlation.
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

    /// Separated output: a spectrogram, or a notice when the model isn't available
    /// or the chosen speaker isn't one of the two separated voices.
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

/// Orchestrates the offline pipeline off the main thread. SepFormer separation is
/// blind and runs **once** per clip (independent of target/threshold); switching
/// the target speaker or moving the slider only re-picks + re-gates the cached
/// streams, which is cheap.
final class AnalysisViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready, failed(String) }
    struct SpeakerInfo: Identifiable { let id: Int; let thumbnail: NSImage? }

    @Published private(set) var state: State = .idle
    @Published private(set) var progress = ""
    @Published private(set) var fileName = ""
    @Published private(set) var summary = ""
    @Published private(set) var speakers: [SpeakerInfo] = []
    @Published private(set) var originalSpectrogram: NSImage?
    @Published private(set) var separatedSpectrogram: NSImage?
    @Published private(set) var separating = false
    @Published private(set) var separationError: String?
    @Published private(set) var targetNote: String?
    @Published var target: Int = 0 { didSet { if oldValue != target { recompute() } } }
    @Published var sensitivity: Double = 0.005
    @Published var gateToTarget: Bool = true
    @Published private(set) var attributedTranscript: [AttributedUtterance] = []

    let player = AudioPlayer()
    private let stft = STFTProcessor()
    private let sr = MediaLoader.sampleRate

    private var audio: [Float] = []
    private var separated: [Float] = []
    private var separatedStreams: [[Float]] = []      // SepFormer's 2 outputs, full length
    private var streamForSpeaker: [Int: [Float]] = [:] // assignment: face id → stream
    private var separator: SepFormerSeparator?         // touched only on main
    private var timeline = VideoAnalyzer.Timeline(frames: [], speakerIDs: [], thumbnails: [:])

    var overlapText: String {
        guard timeline.hasSpeakers else { return "" }
        return String(format: "overlap %.1fs", timeline.overlapDuration(threshold: sensitivity))
    }

    func load(url: URL) {
        state = .loading
        progress = "Reading audio…"
        originalSpectrogram = nil
        separatedSpectrogram = nil
        separated = []
        separatedStreams = []
        streamForSpeaker = [:]
        speakers = []
        attributedTranscript = []
        separationError = nil
        targetNote = nil
        let accessing = url.startAccessingSecurityScopedResource()

        DispatchQueue.global(qos: .userInitiated).async {
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let audio = try MediaLoader.loadAudio(url: url)
                DispatchQueue.main.async { self.progress = "Analyzing video…" }
                let timeline = try VideoAnalyzer.analyze(url: url) { frac in
                    DispatchQueue.main.async { self.progress = "Analyzing video… \(Int(frac * 100))%" }
                }
                let originalImage = SpectrogramImage.make(from: self.stft.forward(audio))
                let infos = timeline.speakerIDs.map { SpeakerInfo(id: $0, thumbnail: timeline.thumbnails[$0]) }

                DispatchQueue.main.async {
                    self.audio = audio
                    self.timeline = timeline
                    self.originalSpectrogram = originalImage
                    self.speakers = infos
                    self.fileName = url.lastPathComponent
                    self.summary = timeline.hasSpeakers ? "" :
                        "No speakers detected in the video — needs detected, moving faces (check the clip isn't rotated)."
                    self.state = .ready
                    if let first = timeline.speakerIDs.first { self.target = first }
                    self.separateAll()
                }
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    /// Heavy: run SepFormer once on the whole clip, then assign each blind output
    /// stream to a face by lip-activity correlation. Results are cached.
    private func separateAll() {
        guard !audio.isEmpty, timeline.hasSpeakers else { return }
        separating = true
        separationError = nil
        let audioBuf = audio
        let tl = timeline
        let sr = self.sr
        let existing = self.separator

        DispatchQueue.global(qos: .userInitiated).async {
            let sep: SepFormerSeparator
            if let existing {
                sep = existing
            } else {
                do { sep = try SepFormerSeparator() }
                catch { self.finishSeparation(error: Self.message(error)); return }
            }
            do {
                let streams = try sep.separate(audioBuf)
                let mapping = SourceAssignment.assign(streams: streams, timeline: tl, sampleRate: sr)
                var bySpeaker: [Int: [Float]] = [:]
                for (i, spk) in mapping.enumerated() { if let spk { bySpeaker[spk] = streams[i] } }
                DispatchQueue.main.async {
                    self.separator = sep
                    self.separatedStreams = streams
                    self.streamForSpeaker = bySpeaker
                    self.separating = false
                    self.refreshTarget()
                }
            } catch {
                self.finishSeparation(error: Self.message(error))
            }
        }
    }

    private func finishSeparation(error: String) {
        DispatchQueue.main.async {
            self.separationError = error
            self.separating = false
            self.separated = []
            self.separatedStreams = []
            self.streamForSpeaker = [:]
            self.separatedSpectrogram = nil
        }
    }

    /// Cheap: re-pick the target's stream, optionally gate it to when the target's
    /// lips move, and render its spectrogram. No CoreML re-run.
    func recompute() { refreshTarget() }

    private func refreshTarget() {
        guard !separatedStreams.isEmpty else { return }      // not separated yet / failed
        guard let stream = streamForSpeaker[target] else {
            separated = []
            separatedSpectrogram = nil
            targetNote = "Speaker \(target) isn't one of the 2 voices SepFormer separated "
                       + "(this model handles 2 speakers — pick one of the matched faces)."
            return
        }
        targetNote = nil
        separating = true
        let target = self.target
        let threshold = self.sensitivity
        let gate = self.gateToTarget
        let tl = self.timeline
        let sr = self.sr
        DispatchQueue.global(qos: .userInitiated).async {
            let result = gate ? Self.gate(stream, target: target, timeline: tl, threshold: threshold, sr: sr)
                              : stream
            let image = SpectrogramImage.make(from: self.stft.forward(result))
            DispatchQueue.main.async {
                self.separated = result
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

    /// Zero the stream wherever the target's lips aren't moving (the old hard gate),
    /// to suppress residual leakage from the other speaker.
    private static func gate(_ stream: [Float], target: Int,
                             timeline: VideoAnalyzer.Timeline, threshold: Double, sr: Double) -> [Float] {
        guard !timeline.frames.isEmpty else { return stream }
        var out = stream
        let frames = timeline.frames
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<frames.count {
                if (frames[i].activity[target] ?? 0) >= threshold { continue }
                let tStart = frames[i].t
                let tEnd = (i + 1 < frames.count) ? frames[i + 1].t : tStart + 0.05
                let s = max(0, Int(tStart * sr))
                let e = min(o.count, Int(tEnd * sr))
                if e > s { for k in s..<e { o[k] = 0 } }
            }
        }
        return out
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
