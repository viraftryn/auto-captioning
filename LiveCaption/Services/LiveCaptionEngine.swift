import Foundation
import Combine
import QuartzCore
import Accelerate

/// Turns the live capture streams into a running, speaker-attributed transcript —
/// the live counterpart of `AnalysisViewModel`.
///
/// The audio path feeds 16 kHz mono PCM (via `AudioResampler`) plus the VAD's
/// speech flag; the video path feeds per-speaker lip-activity. This engine slices
/// that continuous input into utterance-sized **chunks** using the VAD: a chunk
/// closes on a natural speech pause (`pauseToClose`) or at a hard cap
/// (`maxChunk`, just under the SepFormer window), so boundaries land in the gaps
/// between phrases — good for Whisper and giving exactly one SepFormer window per
/// overlap chunk.
///
/// Per chunk, mirroring the diagram's "Overlap detected?" branch:
///  • **No overlap** (≤1 face lip-active) → transcribe the chunk directly and
///    attribute it to the single most-active speaker.
///  • **Overlap** (2+ faces lip-active) → SepFormer separates the chunk into two
///    blind streams, `SourceAssignment` matches each stream to a face by
///    correlating its energy envelope against that face's lip activity, and each
///    stream is transcribed on its own → one attributed line per speaker.
///
/// Threading: `ingest*` is called from the capture queues and only touches
/// segmenter state on a private serial queue. Closed chunks flow through an
/// `AsyncStream` to a single `@MainActor` consumer, so transcription runs one at a
/// time, in order, and all `@Published` state is mutated on the main thread only.
/// SepFormer inference runs on its own background queue (awaited), never blocking
/// the main thread or the capture queues.
final class LiveCaptionEngine: ObservableObject {

    /// A closed chunk handed from the segmenter (background) to the transcriber (main).
    struct AudioChunk {
        let samples: [Float]                            // 16 kHz mono
        let start: Double                               // seconds since session start
        let end: Double
        let activity: [(t: Double, byId: [Int: Double])] // per-frame lip activity, chunk-local time
        let sawOverlap: Bool                            // sustained 2+ faces active during the chunk
    }

    // MARK: Published (main thread only)
    @Published private(set) var transcript: [AttributedUtterance] = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorText: String?
    /// Set once if an overlap chunk arrives but the SepFormer model isn't installed;
    /// overlaps then fall back to single-speaker until it's produced.
    @Published private(set) var separationUnavailable = false
    @Published var captioning = true { didSet { setEnabled(captioning) } }

    // MARK: Tuning
    private let sr: Double = 16_000
    /// Hard cap on chunk length. Kept just under the SepFormer 4.0s window so a
    /// near-cap overlap chunk (which overshoots by one audio buffer) still fits in
    /// one model pass rather than triggering the windowed path.
    private let maxChunk: Double = 3.8
    private let pauseToClose: Double = 0.35     // silence after speech that ends a chunk
    private let minChunk: Double = 0.4          // drop anything shorter than this
    private let preroll: Double = 0.2           // audio kept before speech onset
    private let overlapActivityFloor: Double = 0.006

    // MARK: Attribution tuning (cross-modal audio↔lip timing match)
    // Starting points — expect to tune against the live transcript.
    /// Need at least this many video frames in a chunk to trust a correlation;
    /// below it, fall back to the lip-only dominant-speaker heuristic.
    private let minCorrFrames = 8
    /// ±frames of audio/video slack the correlation may slide to align (≈100 ms).
    private let maxLagFrames = 3
    /// Below this correlation the audio↔lip match is untrustworthy → fall back.
    private let attrCorrFloor: Float = 0.15
    /// The winning face must beat the runner-up by this much, else it's a near-tie
    /// and we defer to the previous speaker (stickiness) instead of guessing.
    private let attrMargin: Float = 0.12

    // MARK: Segmenter state (segmentQueue only)
    private let segmentQueue = DispatchQueue(label: "com.aiml.livecaption.segment", qos: .userInitiated)
    private var running = false
    private var enabledFlag = true
    private var sessionStartWall: Double = 0
    private var backlog: [Float] = []
    private var pending: [Float] = []
    private var accumulating = false
    private var chunkStartWall: Double = 0       // speech onset (pause/cap timing)
    private var chunkAudioStartWall: Double = 0  // wall time of the chunk's first sample (incl. preroll)
    private var lastSpeechWall: Double = 0
    private var activityLog: [(wall: Double, byId: [Int: Double])] = []
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    // MARK: Transcription (main only) + separation (background)
    private var transcriber: Transcriber?
    private let sepRunner = SepFormerRunner()
    /// Last single-speaker attribution, for cross-chunk stickiness (main only).
    private var lastSpeaker: Int?

    // MARK: - Lifecycle

    /// Begin a fresh captioning session: clears the transcript and starts the
    /// chunk consumer. Called when live capture starts.
    func start() {
        transcript = []
        errorText = nil
        lastSpeaker = nil
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

    /// Feed a video frame's per-speaker lip activity (used to attribute chunks and,
    /// on overlap, to match separated streams to faces).
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
                let prerollSec = Double(backlog.count) / sr
                pending = backlog
                backlog = []
                chunkStartWall = now
                chunkAudioStartWall = now - prerollSec
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

        // Activity timestamps are made **chunk-local** (0 = first sample) because
        // SourceAssignment indexes the separated streams by `t * sampleRate`.
        let startRel = max(0, chunkAudioStartWall - sessionStartWall)
        let lo = chunkAudioStartWall - 0.05, hi = endWall + 0.05
        let activity = activityLog
            .filter { $0.wall >= lo && $0.wall <= hi }
            .map { (t: max(0, $0.wall - chunkAudioStartWall), byId: $0.byId) }

        // Require sustained overlap (not one stray frame) before paying for SepFormer.
        let overlapFrames = activity.filter {
            $0.byId.values.filter { $0 >= overlapActivityFloor }.count >= 2
        }.count
        let sawOverlap = overlapFrames >= max(3, activity.count / 10)

        continuation?.yield(AudioChunk(samples: samples, start: startRel,
                                       end: startRel + duration,
                                       activity: activity, sawOverlap: sawOverlap))
    }

    private func resetChunkLocked() {
        backlog = []
        pending = []
        accumulating = false
        chunkStartWall = 0
        chunkAudioStartWall = 0
        lastSpeechWall = 0
    }

    // MARK: - Processing (main only)

    @MainActor
    private func process(_ chunk: AudioChunk) async {
        if transcriber == nil { transcriber = Transcriber() }
        guard let transcriber else { return }

        isBusy = true
        defer { isBusy = false }

        if chunk.sawOverlap {
            do {
                let streams = try await sepRunner.separate(chunk.samples)
                if await transcribeOverlap(chunk, streams: streams, using: transcriber) { return }
                // No stream produced usable text → fall through to single-speaker.
            } catch let e as SepFormerSeparator.SeparationError {
                if case .modelMissing = e { separationUnavailable = true }
                else { errorText = e.errorDescription }
            } catch {
                errorText = Self.message(error)
            }
        }
        await transcribeSingle(chunk, using: transcriber)
    }

    /// Single-speaker path: transcribe the chunk directly and attribute it to the
    /// speaker whose lips best track the audio during it (`nil` if no face was
    /// active) — see `attributedSpeaker`.
    @MainActor
    private func transcribeSingle(_ chunk: AudioChunk, using transcriber: Transcriber) async {
        let segments = await transcriber.transcribe(chunk.samples)
        if case .failed(let message) = transcriber.status { errorText = message; return }
        let text = Self.joinText(segments)
        guard !text.isEmpty else { return }
        errorText = nil
        append([AttributedUtterance(speaker: attributedSpeaker(for: chunk), text: text,
                                    start: chunk.start, end: chunk.end)])
    }

    /// Overlap path: match each separated stream to a face, transcribe each on its
    /// own, and emit one attributed line per speaker. Returns whether it produced
    /// any text (so the caller can fall back to single-speaker if not).
    @MainActor
    private func transcribeOverlap(_ chunk: AudioChunk, streams: [[Float]],
                                   using transcriber: Transcriber) async -> Bool {
        separationUnavailable = false
        let timeline = Self.miniTimeline(from: chunk)
        let mapping = SourceAssignment.assign(streams: streams, timeline: timeline, sampleRate: sr)

        // Skip a near-silent stream (SepFormer emits two even when only one voice is
        // present) so Whisper doesn't hallucinate a spurious line from separation
        // residue: drop anything essentially silent or far quieter than the loudest.
        let energies = streams.map { Self.rms($0) }
        let loudest = energies.max() ?? 0

        var lines: [AttributedUtterance] = []
        for (i, stream) in streams.enumerated() {
            guard i < mapping.count, let speaker = mapping[i], !stream.isEmpty else { continue }
            guard energies[i] > 1e-3, energies[i] > 0.15 * loudest else { continue }
            let segments = await transcriber.transcribe(stream)
            if case .failed(let message) = transcriber.status { errorText = message; continue }
            let text = Self.joinText(segments)
            if !text.isEmpty {
                lines.append(AttributedUtterance(speaker: speaker, text: text,
                                                 start: chunk.start, end: chunk.end))
            }
        }

        guard !lines.isEmpty else { return false }
        errorText = nil
        lines.sort { ($0.speaker ?? .max) < ($1.speaker ?? .max) }
        append(lines)
        return true
    }

    private func append(_ utterances: [AttributedUtterance]) {
        transcript.append(contentsOf: utterances)
        if transcript.count > 300 { transcript.removeFirst(transcript.count - 300) }
    }

    // MARK: - Helpers

    /// Pick the speaker for a single-speaker chunk by **cross-modal timing match**:
    /// the face whose lip activity best tracks the chunk's audio energy over time
    /// (see `CrossModalCorrelation`), not merely the face that moved its lips most —
    /// so a silent bystander's mouth movement can't steal the caption. Guards keep
    /// it honest:
    ///  • too few frames / no faces → fall back to the lip-only dominant speaker;
    ///  • best correlation below `attrCorrFloor` (voice likely off-screen) → same;
    ///  • a near-tie with a rival (< `attrMargin`) → keep the previous speaker
    ///    rather than guess, which is what stops labels flip-flopping line to line.
    /// Returns `nil` only when no face is a plausible source.
    @MainActor
    private func attributedSpeaker(for chunk: AudioChunk) -> Int? {
        let times = chunk.activity.map { $0.t }
        let faces = Set(chunk.activity.flatMap { $0.byId.keys }).sorted()
        guard !faces.isEmpty, times.count >= minCorrFrames else {
            return stick(Self.dominantSpeaker(chunk))
        }

        let audioEnv = CrossModalCorrelation.zscore(
            CrossModalCorrelation.energyEnvelope(chunk.samples, at: times, sampleRate: sr))
        var scored = faces.map { id -> (id: Int, corr: Float) in
            let lip = CrossModalCorrelation.zscore(chunk.activity.map { Float($0.byId[id] ?? 0) })
            return (id, CrossModalCorrelation.bestLaggedCorrelation(audioEnv, lip, maxLag: maxLagFrames))
        }
        scored.sort { $0.corr > $1.corr }

        guard let top = scored.first, top.corr >= attrCorrFloor else {
            return stick(Self.dominantSpeaker(chunk))
        }
        let runnerUp = scored.count > 1 ? scored[1].corr : -.greatestFiniteMagnitude
        if faces.count == 1 || (top.corr - runnerUp) >= attrMargin {
            lastSpeaker = top.id
            return top.id
        }
        // Near-tie: defer to the previous speaker if they're still a close contender.
        if let last = lastSpeaker, scored.prefix(2).contains(where: { $0.id == last }) {
            return last
        }
        lastSpeaker = top.id
        return top.id
    }

    /// Remember a non-nil attribution for cross-chunk stickiness, then return it.
    @MainActor
    private func stick(_ id: Int?) -> Int? {
        if let id { lastSpeaker = id }
        return id
    }

    /// Lip-only fallback attribution: the speaker whose lips moved most across the
    /// chunk. Used when there aren't enough frames to correlate, or the audio↔lip
    /// match is too weak to trust. `nil` if no face was active (off-screen speaker).
    private static func dominantSpeaker(_ chunk: AudioChunk) -> Int? {
        var sum: [Int: Double] = [:]
        for frame in chunk.activity {
            for (id, a) in frame.byId { sum[id, default: 0] += a }
        }
        guard let best = sum.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return best.key
    }

    /// A per-chunk `Timeline` for `SourceAssignment`, using the chunk's local-time
    /// lip-activity frames. Thumbnails aren't needed for stream→face matching.
    private static func miniTimeline(from chunk: AudioChunk) -> VideoAnalyzer.Timeline {
        let frames = chunk.activity.map { VideoAnalyzer.Timeline.Frame(t: $0.t, activity: $0.byId) }
        let ids = Set(chunk.activity.flatMap { $0.byId.keys }).sorted()
        return VideoAnalyzer.Timeline(frames: frames, speakerIDs: ids, thumbnails: [:])
    }

    private static func joinText(_ segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rms(_ x: [Float]) -> Float {
        var ms: Float = 0
        x.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress, p.count > 0 else { return }
            vDSP_measqv(base, 1, &ms, vDSP_Length(p.count))
        }
        return ms.squareRoot()
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Serializes SepFormer inference on a background queue and lazily loads the model
/// once. `@unchecked Sendable` is sound because the model is only ever created and
/// used inside `queue` (serial), so it's never touched concurrently.
private final class SepFormerRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aiml.livecaption.sepformer", qos: .userInitiated)
    private var separator: SepFormerSeparator?

    /// Separate a short (≤ window) clip into blind streams in one model pass. Throws
    /// `SepFormerSeparator.SeparationError.modelMissing` if the model isn't installed.
    func separate(_ samples: [Float]) async throws -> [[Float]] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.separator == nil { self.separator = try SepFormerSeparator() }
                    continuation.resume(returning: try self.separator!.separateWindow(samples))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
