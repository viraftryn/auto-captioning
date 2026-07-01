import Foundation
import Combine
import QuartzCore

/// Turns the live capture streams into a running, speaker-attributed transcript —
/// the live counterpart of `AnalysisViewModel`.
///
/// The audio path feeds 16 kHz mono PCM (via `AudioResampler`) plus the VAD's
/// speech flag; the video path feeds per-speaker lip-activity. This engine slices
/// that continuous input into utterance-sized **chunks** using the VAD: a chunk
/// closes on a natural speech pause (`pauseToClose`) or at a hard cap
/// (`maxChunk`, matched to the SepFormer window), so boundaries land in the gaps
/// between phrases — good for Whisper and, later, exactly one SepFormer window per
/// overlap chunk.
///
/// **STEP 1 (this version): single-speaker path only.** Each chunk is attributed
/// to the speaker whose lips moved most during it and transcribed directly (no
/// separation). STEP 2 will branch chunks where `sawOverlap` is true through
/// SepFormer + per-stream transcription — the `activity` timeline captured here is
/// already what `SourceAssignment` needs.
///
/// Threading: `ingest*` is called from the capture queues and only touches
/// segmenter state on a private serial queue. Closed chunks flow through an
/// `AsyncStream` to a single `@MainActor` consumer, so transcription runs one at a
/// time, in order, and all `@Published` state is mutated on the main thread only.
final class LiveCaptionEngine: ObservableObject {

    /// A closed chunk handed from the segmenter (background) to the transcriber (main).
    struct AudioChunk {
        let samples: [Float]                            // 16 kHz mono
        let start: Double                               // seconds since session start
        let end: Double
        let activity: [(t: Double, byId: [Int: Double])] // per-frame lip activity in-chunk
        let sawOverlap: Bool                            // 2+ faces active during the chunk
    }

    // MARK: Published (main thread only)
    @Published private(set) var transcript: [AttributedUtterance] = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorText: String?
    @Published var model: WhisperModelSize = .small
    @Published var captioning = true { didSet { setEnabled(captioning) } }

    // MARK: Tuning
    private let sr: Double = 16_000
    private let maxChunk: Double = 4.0          // hard cap == SepFormer window length
    private let pauseToClose: Double = 0.35     // silence after speech that ends a chunk
    private let minChunk: Double = 0.4          // drop anything shorter than this
    private let preroll: Double = 0.2           // audio kept before speech onset
    private let overlapActivityFloor: Double = 0.006

    // MARK: Segmenter state (segmentQueue only)
    private let segmentQueue = DispatchQueue(label: "com.aiml.livecaption.segment", qos: .userInitiated)
    private var running = false
    private var enabledFlag = true
    private var sessionStartWall: Double = 0
    private var backlog: [Float] = []
    private var pending: [Float] = []
    private var accumulating = false
    private var chunkStartWall: Double = 0
    private var lastSpeechWall: Double = 0
    private var activityLog: [(wall: Double, byId: [Int: Double])] = []
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    // MARK: Transcription (main only)
    private var transcriber: Transcriber?

    // MARK: - Lifecycle

    /// Begin a fresh captioning session: clears the transcript and starts the
    /// chunk consumer. Called when live capture starts.
    func start() {
        transcript = []
        errorText = nil
        segmentQueue.async {
            guard !self.running else { return }
            self.running = true
            self.enabledFlag = true
            self.resetChunkLocked()
            self.activityLog = []
            self.sessionStartWall = CACurrentMediaTime()
            let (stream, cont) = AsyncStream.makeStream(of: AudioChunk.self,
                                                        bufferingPolicy: .bufferingNewest(6))
            self.continuation = cont
            Task { @MainActor [weak self] in
                for await chunk in stream {
                    guard let self else { break }
                    await self.process(chunk)
                }
            }
        }
    }

    /// Tear down the session (called when live capture stops).
    func stop() {
        segmentQueue.async {
            self.running = false
            self.continuation?.finish()
            self.continuation = nil
            self.resetChunkLocked()
            self.activityLog = []
        }
        isBusy = false
    }

    /// Pause / resume captioning without tearing down the session.
    private func setEnabled(_ on: Bool) {
        segmentQueue.async {
            self.enabledFlag = on
            if !on { self.resetChunkLocked() }
        }
    }

    // MARK: - Ingest (called from capture queues)

    /// Feed a block of 16 kHz mono samples with the VAD's speech decision for it.
    func ingestAudio(_ samples: [Float], now: Double, isSpeech: Bool) {
        guard !samples.isEmpty else { return }
        segmentQueue.async {
            guard self.running, self.enabledFlag else { return }
            if self.sessionStartWall == 0 { self.sessionStartWall = now }
            self.appendAudioLocked(samples, now: now, isSpeech: isSpeech)
        }
    }

    /// Feed a video frame's per-speaker lip activity (used to attribute chunks).
    func ingestActivity(_ byId: [Int: Double], overlap: Bool, now: Double) {
        segmentQueue.async {
            guard self.running, self.enabledFlag else { return }
            if self.sessionStartWall == 0 { self.sessionStartWall = now }
            self.activityLog.append((now, byId))
            let cutoff = now - 12
            if let idx = self.activityLog.firstIndex(where: { $0.wall >= cutoff }), idx > 0 {
                self.activityLog.removeFirst(idx)
            }
        }
    }

    // MARK: - Segmentation (segmentQueue only)

    private func appendAudioLocked(_ samples: [Float], now: Double, isSpeech: Bool) {
        // Between chunks: keep a short rolling backlog so the next chunk includes a
        // little audio from just before the speech onset (avoids clipped first words).
        if !accumulating {
            backlog.append(contentsOf: samples)
            let maxBack = Int(preroll * sr)
            if backlog.count > maxBack { backlog.removeFirst(backlog.count - maxBack) }
            if isSpeech {
                accumulating = true
                pending = backlog
                backlog = []
                chunkStartWall = now
                lastSpeechWall = now
            }
            return
        }

        pending.append(contentsOf: samples)
        if isSpeech { lastSpeechWall = now }
        if (now - lastSpeechWall) >= pauseToClose || (now - chunkStartWall) >= maxChunk {
            closeChunkLocked(endWall: now)
        }
    }

    private func closeChunkLocked(endWall: Double) {
        let samples = pending
        accumulating = false
        pending = []
        backlog = []

        let duration = Double(samples.count) / sr
        guard duration >= minChunk, sessionStartWall > 0 else { return }

        let startRel = max(0, chunkStartWall - sessionStartWall)
        let lo = chunkStartWall - 0.15, hi = endWall + 0.15
        let activity = activityLog
            .filter { $0.wall >= lo && $0.wall <= hi }
            .map { (t: $0.wall - sessionStartWall, byId: $0.byId) }
        let sawOverlap = activity.contains {
            $0.byId.values.filter { $0 >= overlapActivityFloor }.count >= 2
        }

        continuation?.yield(AudioChunk(samples: samples, start: startRel,
                                       end: startRel + duration,
                                       activity: activity, sawOverlap: sawOverlap))
    }

    private func resetChunkLocked() {
        backlog = []
        pending = []
        accumulating = false
        chunkStartWall = 0
        lastSpeechWall = 0
    }

    // MARK: - Transcription (main only)

    @MainActor
    private func process(_ chunk: AudioChunk) async {
        if transcriber == nil { transcriber = Transcriber(model: model) }
        guard let transcriber else { return }
        if transcriber.model != model { transcriber.model = model }

        isBusy = true
        let segments = await transcriber.transcribe(chunk.samples)
        isBusy = false

        if case .failed(let message) = transcriber.status {
            errorText = message
            return
        }
        errorText = nil

        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let speaker = Self.dominantSpeaker(chunk)
        transcript.append(AttributedUtterance(speaker: speaker, text: text,
                                              start: chunk.start, end: chunk.end))
        if transcript.count > 300 { transcript.removeFirst(transcript.count - 300) }
    }

    /// The speaker whose lips moved most across the chunk — the single-speaker
    /// attribution. `nil` if no face was active (e.g. an off-screen speaker).
    private static func dominantSpeaker(_ chunk: AudioChunk) -> Int? {
        var sum: [Int: Double] = [:]
        for frame in chunk.activity {
            for (id, a) in frame.byId { sum[id, default: 0] += a }
        }
        guard let best = sum.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return best.key
    }
}
