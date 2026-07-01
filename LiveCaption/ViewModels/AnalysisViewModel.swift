import Foundation
import AppKit

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
    private var separatedStreams: [[Float]] = []
    private var streamForSpeaker: [Int: [Float]] = [:]
    private var separator: SepFormerSeparator?
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

    func recompute() { refreshTarget() }

    private func refreshTarget() {
        guard !separatedStreams.isEmpty else { return }
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
