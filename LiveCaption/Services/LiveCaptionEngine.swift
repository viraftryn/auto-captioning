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
        let sawOverlap: Bool                            // 2+ faces active during the chunk
        let leadingContext: [Float]                     // real audio just before the chunk (overlap only)
        let activityFloor: Double                       // "is speaking" threshold at close time
    }

    // MARK: Published (main thread only)
    @Published private(set) var transcript: [AttributedUtterance] = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorText: String?
    /// Set once if an overlap chunk arrives but the SepFormer model isn't installed;
    /// overlaps then fall back to single-speaker until it's produced.
    @Published private(set) var separationUnavailable = false
    @Published var model: WhisperModelSize = .large
    @Published var captioning = true { didSet { setEnabled(captioning) } }

    // MARK: Tuning
    private let sr: Double = 16_000
    /// Cap for a NORMAL (single / turn-taking) chunk -- just under the SepFormer 4.0s
    /// window so it fits one model pass. Overlap segments use `maxOverlapChunk`.
    private let maxChunk: Double = 3.8
    /// Cap for an overlap segment. Kept SHORT so overlaps are separated + captioned
    /// promptly and stream as they happen (a long cap made captions appear seconds
    /// late and, while one long segment was processing, dropped incoming speech).
    /// Being under 4s also leaves the SepFormer window room for real context, which
    /// improves the split. Continuous overlap therefore streams as consecutive
    /// ~3s pieces rather than one delayed block.
    private let maxOverlapChunk: Double = 3.0
    private let pauseToClose: Double = 0.35     // silence after speech that ends a chunk
    private let minChunk: Double = 0.4          // drop anything shorter than this
    private let preroll: Double = 0.2           // audio kept before speech onset
    private var overlapActivityFloor: Double = 0.006  // "is speaking" threshold; tracks the Talk slider
    private let overlapHold: Double = 0.3       // overlap stays "active" this long after the last 2-active frame
    private let overlapEndDelay: Double = 0.4   // close an overlap segment this long after overlap ends
    private let historySeconds: Double = 4.0    // rolling raw-audio kept as SepFormer context

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
    private var overlapActiveUntil: Double = 0   // simultaneous overlap "sticks" until this wall time
    private var overlapStreak: Int = 0           // consecutive 2+-active frames (single-frame glitch guard)
    private var sawOverlapInChunk = false        // simultaneous overlap occurred during the current chunk
    private var activityLog: [(wall: Double, byId: [Int: Double])] = []
    private var history: [Float] = []           // rolling last `historySeconds` of audio
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    // MARK: Transcription (main only) + separation (background)
    private var transcriber: Transcriber?
    private let sepRunner = SepFormerRunner()

    // Cross-chunk continuity for the overlap path (main only): keeps Speaker 1/2
    // labels stable across consecutive overlap chunks by blending an acoustic-tail
    // continuity term into the cross-modal (audio<->lip) assignment.
    private var faceTail: [Int: [Float]] = [:]   // recent energy-envelope tail per face
    private var lastOverlapEnd: Double = -1       // session time the previous overlap chunk ended
    private let tailSeconds: Double = 0.2         // overlap region compared for continuity
    private let overlapGapMax: Double = 0.6       // max gap to treat two overlap chunks as one episode
    private let continuityWeight: Float = 2.0     // weight of the continuity term vs cross-modal

    // MARK: - Lifecycle

    /// Begin a fresh captioning session: clears the transcript and starts the
    /// chunk consumer. Called when live capture starts.
    func start() {
        transcript = []
        errorText = nil
        faceTail = [:]
        lastOverlapEnd = -1
        sepRunner.warmUp()   // compile SepFormer now, not on the first overlap mid-talk
        segmentQueue.async {
            guard !self.running else { return }
            self.running = true
            self.enabledFlag = true
            self.resetChunkLocked()
            self.activityLog = []
            self.history = []
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
            self.history = []
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

    /// Keep the engine's "is speaking" threshold in step with the UI Talk slider, so
    /// overlap detection and per-speaker splitting use the same sensitivity the user
    /// tuned for active-speaker detection.
    func setActivityFloor(_ value: Double) {
        segmentQueue.async { self.overlapActivityFloor = max(0.001, value) }
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

            // Track sustained simultaneous overlap (2+ faces speaking). A short streak
            // guards against single-frame glitches; a hold keeps it "active" briefly.
            let activeCount = byId.values.filter { $0 >= self.overlapActivityFloor }.count
            if activeCount >= 2 {
                self.overlapStreak += 1
                if self.overlapStreak >= 2 { self.overlapActiveUntil = now + self.overlapHold }
            } else {
                self.overlapStreak = 0
            }

            self.activityLog.append((now, byId))
            let cutoff = now - 12
            if let idx = self.activityLog.firstIndex(where: { $0.wall >= cutoff }), idx > 0 {
                self.activityLog.removeFirst(idx)
            }
        }
    }

    // MARK: - Segmentation (segmentQueue only)

    private func appendAudioLocked(_ samples: [Float], now: Double, isSpeech: Bool) {
        // Rolling recent-audio buffer: gives SepFormer real audio from just before an
        // overlap chunk as context, instead of zero-padding a short window.
        history.append(contentsOf: samples)
        let maxHistory = Int(historySeconds * sr)
        if history.count > maxHistory { history.removeFirst(history.count - maxHistory) }

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
                sawOverlapInChunk = now < overlapActiveUntil
            }
            return
        }

        pending.append(contentsOf: samples)
        if isSpeech { lastSpeechWall = now }
        if now < overlapActiveUntil { sawOverlapInChunk = true }

        let pause = (now - lastSpeechWall) >= pauseToClose
        if sawOverlapInChunk {
            // Overlap segment: close promptly so it's separated + captioned without
            // delay -- on a real pause, shortly after the overlap actually ends (so a
            // brief interjection doesn't linger), or at the short overlap cap.
            // Continuous overlap therefore streams as consecutive short pieces.
            let overlapEnded = now >= overlapActiveUntil + overlapEndDelay
            if pause || overlapEnded || (now - chunkStartWall) >= maxOverlapChunk {
                closeChunkLocked(endWall: now)
            }
        } else if pause || (now - chunkStartWall) >= maxChunk {
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

        // Whether simultaneous overlap happened during this chunk, tracked live from
        // the activity stream (streak + hold guard). Overlap chunks were grown to
        // capture the whole exchange, so this is the whole segment.
        let sawOverlap = sawOverlapInChunk

        // For overlap chunks, hand the separator the real audio from just before the
        // chunk (drop the chunk's own tail from the rolling history) as context.
        let context: [Float] = sawOverlap
            ? Array(history.dropLast(min(history.count, samples.count)))
            : []

        continuation?.yield(AudioChunk(samples: samples, start: startRel,
                                       end: startRel + duration,
                                       activity: activity, sawOverlap: sawOverlap,
                                       leadingContext: context, activityFloor: overlapActivityFloor))
    }

    private func resetChunkLocked() {
        backlog = []
        pending = []
        accumulating = false
        chunkStartWall = 0
        chunkAudioStartWall = 0
        lastSpeechWall = 0
        overlapActiveUntil = 0
        overlapStreak = 0
        sawOverlapInChunk = false
    }

    // MARK: - Processing (main only)

    @MainActor
    private func process(_ chunk: AudioChunk) async {
        if transcriber == nil { transcriber = Transcriber(model: model) }
        guard let transcriber else { return }
        if transcriber.model != model { transcriber.model = model }

        isBusy = true
        defer { isBusy = false }

        if chunk.sawOverlap {
            do {
                let streams = try await sepRunner.separate(chunk.samples, context: chunk.leadingContext)
                if await transcribeOverlap(chunk, streams: streams, using: transcriber) { return }
                // No stream produced usable text → fall through to single-speaker.
            } catch let e as SepFormerSeparator.SeparationError {
                if case .modelMissing = e { separationUnavailable = true }
                else { errorText = e.errorDescription }
            } catch {
                errorText = Self.message(error)
            }
        }
        await transcribeSequential(chunk, using: transcriber)
    }

    /// Non-overlap path. A VAD chunk can still contain fast TURN-TAKING between two
    /// speakers (no pause, no simultaneous overlap); transcribing it whole would
    /// label both turns as one speaker. So if a second face was meaningfully active,
    /// split the chunk into per-speaker segments by dominant lip activity and
    /// transcribe each; otherwise transcribe the whole chunk as one speaker.
    @MainActor
    private func transcribeSequential(_ chunk: AudioChunk, using transcriber: Transcriber) async {
        var totals: [Int: Double] = [:]
        for f in chunk.activity {
            for (id, a) in f.byId where a >= chunk.activityFloor { totals[id, default: 0] += a }
        }
        let ranked = totals.sorted { $0.value > $1.value }
        let top = ranked.first

        // One (or zero) meaningful speaker -> single line (unchanged behaviour).
        let hasSecond = ranked.count >= 2 && ranked[1].value >= 0.35 * (top?.value ?? 1)
        let segments = hasSecond ? Self.dominantSegments(chunk) : []
        guard segments.count >= 2 else {
            await emitWhole(chunk, speaker: top?.key, using: transcriber)
            return
        }

        var lines: [AttributedUtterance] = []
        for seg in segments {
            let slice = Self.slice(chunk.samples, start: seg.start, end: seg.end, sr: sr)
            guard Self.rms(slice) > 1e-3 else { continue }
            let text = Self.joinText(await transcriber.transcribe(slice))
            if case .failed(let message) = transcriber.status { errorText = message; continue }
            if !text.isEmpty {
                lines.append(AttributedUtterance(speaker: seg.speaker, text: text,
                                                 start: chunk.start + seg.start,
                                                 end: chunk.start + seg.end))
            }
        }
        if lines.isEmpty {
            await emitWhole(chunk, speaker: top?.key, using: transcriber)
        } else {
            errorText = nil
            append(lines)
        }
    }

    /// Transcribe the whole chunk as one line for `speaker`.
    @MainActor
    private func emitWhole(_ chunk: AudioChunk, speaker: Int?, using transcriber: Transcriber) async {
        let segments = await transcriber.transcribe(chunk.samples)
        if case .failed(let message) = transcriber.status { errorText = message; return }
        let text = Self.joinText(segments)
        guard !text.isEmpty else { return }
        errorText = nil
        append([AttributedUtterance(speaker: speaker, text: text, start: chunk.start, end: chunk.end)])
    }

    /// Overlap path: match each separated stream to a face, transcribe each on its
    /// own, and emit one attributed line per speaker. Returns whether it produced
    /// any text (so the caller can fall back to single-speaker if not).
    @MainActor
    private func transcribeOverlap(_ chunk: AudioChunk, streams: [[Float]],
                                   using transcriber: Transcriber) async -> Bool {
        separationUnavailable = false
        let timeline = Self.miniTimeline(from: chunk)

        // Cross-modal (audio<->lip) correlation of each stream vs each face.
        let (cmCorr, faces) = SourceAssignment.correlations(streams: streams, timeline: timeline, sampleRate: sr)
        guard !cmCorr.isEmpty, !faces.isEmpty else { return false }

        // Cross-chunk continuity: if this overlap chunk is contiguous with the last
        // one, blend an acoustic-tail term into the correlation. Each stream's leading
        // ~0.2s overlaps the previous chunk's trailing ~0.2s (same audio), so the
        // matching voice's energy envelope lines up with the stored face tail. This
        // keeps Speaker 1/2 from flipping between chunks while still grounding identity
        // in the cross-modal assignment.
        var corr = cmCorr
        let contiguous = (chunk.start - lastOverlapEnd) < overlapGapMax && !faceTail.isEmpty
        if contiguous {
            let leadN = Int(tailSeconds * sr)
            let leads = streams.map { Self.envelope(Array($0.prefix(leadN))) }
            for i in streams.indices where i < corr.count {
                for (j, f) in faces.enumerated() where j < corr[i].count {
                    if let tail = faceTail[f] {
                        corr[i][j] += continuityWeight * Self.envelopeCorr(leads[i], tail)
                    }
                }
            }
        }
        let mapping = SourceAssignment.bestAssignment(corr, speakers: faces)

        // Skip only a near-silent stream (SepFormer emits two even when one voice is
        // present) so Whisper doesn't hallucinate from separation residue. The ratio
        // is kept low so a genuinely quieter second speaker still produces a line.
        let energies = streams.map { Self.rms($0) }
        let loudest = energies.max() ?? 0
        let tailN = Int(tailSeconds * sr)

        var lines: [AttributedUtterance] = []
        for (i, stream) in streams.enumerated() {
            guard i < mapping.count, let speaker = mapping[i], !stream.isEmpty else { continue }
            guard energies[i] > 1e-3, energies[i] > 0.08 * loudest else { continue }
            // Remember this face's recent audio tail for the next chunk's continuity
            // (only a stream that actually carried this speaker's voice).
            faceTail[speaker] = Self.envelope(Array(stream.suffix(tailN)))
            let segments = await transcriber.transcribe(stream)
            if case .failed(let message) = transcriber.status { errorText = message; continue }
            let text = Self.joinText(segments)
            if !text.isEmpty {
                lines.append(AttributedUtterance(speaker: speaker, text: text,
                                                 start: chunk.start, end: chunk.end))
            }
        }
        lastOverlapEnd = chunk.end

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

    /// Split a chunk into contiguous [speaker, start, end] runs by the per-frame
    /// dominant face. Silence gaps are filled with the surrounding speaker, runs
    /// shorter than `minSeg` are absorbed into the previous run (flicker guard), and
    /// adjacent same-speaker runs are merged. Times are chunk-local seconds.
    private static func dominantSegments(_ chunk: AudioChunk) -> [(speaker: Int, start: Double, end: Double)] {
        let frames = chunk.activity
        guard !frames.isEmpty else { return [] }
        let floor = chunk.activityFloor
        let minSeg = 0.3

        var dom: [Int?] = frames.map { frame in
            frame.byId.filter { $0.value >= floor }.max { $0.value < $1.value }?.key
        }
        var last: Int? = nil
        for i in dom.indices { if dom[i] == nil { dom[i] = last } else { last = dom[i] } }
        var next: Int? = nil
        for i in dom.indices.reversed() { if dom[i] == nil { dom[i] = next } else { next = dom[i] } }

        let times = frames.map { $0.t }
        let chunkEnd = Double(chunk.samples.count) / 16_000
        func frameEnd(_ k: Int) -> Double { k + 1 < times.count ? times[k + 1] : chunkEnd }

        var runs: [(spk: Int, start: Double, end: Double)] = []
        var i = 0
        while i < dom.count {
            guard let spk = dom[i] else { i += 1; continue }
            var j = i
            while j + 1 < dom.count && dom[j + 1] == spk { j += 1 }
            runs.append((spk, times[i], frameEnd(j)))
            i = j + 1
        }

        var merged: [(spk: Int, start: Double, end: Double)] = []
        for r in runs {
            if var lastRun = merged.last, lastRun.spk == r.spk || (r.end - r.start) < minSeg {
                lastRun.end = r.end
                merged[merged.count - 1] = lastRun
            } else {
                merged.append(r)
            }
        }
        return merged.map { (speaker: $0.spk, start: $0.start, end: $0.end) }
    }

    /// Extract `[start, end]` (chunk-local seconds) from the chunk samples, with a
    /// little padding so words at the split boundary aren't clipped.
    private static func slice(_ samples: [Float], start: Double, end: Double, sr: Double) -> [Float] {
        let pad = 0.1
        let lo = max(0, Int((start - pad) * sr))
        let hi = min(samples.count, Int((end + pad) * sr))
        guard hi > lo else { return [] }
        return Array(samples[lo..<hi])
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

    /// Coarse RMS energy envelope over ~10 ms frames — a shift-tolerant signal for
    /// matching the shared overlap region between consecutive chunks.
    private static func envelope(_ signal: [Float]) -> [Float] {
        let frame = 160   // 10 ms @ 16 kHz
        guard signal.count >= frame else { return [] }
        var env: [Float] = []
        env.reserveCapacity(signal.count / frame)
        signal.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            var i = 0
            while i + frame <= signal.count {
                var ms: Float = 0
                vDSP_measqv(base + i, 1, &ms, vDSP_Length(frame))
                env.append(ms.squareRoot())
                i += frame
            }
        }
        return env
    }

    /// Pearson correlation of two energy envelopes, in [-1, 1] (0 if too short).
    private static func envelopeCorr(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n >= 2 else { return 0 }
        let za = zscoreVec(Array(a.prefix(n)))
        let zb = zscoreVec(Array(b.prefix(n)))
        var r: Float = 0
        vDSP_dotpr(za, 1, zb, 1, &r, vDSP_Length(n))
        return r / Float(n)
    }

    private static func zscoreVec(_ x: [Float]) -> [Float] {
        let n = vDSP_Length(x.count)
        guard x.count > 1 else { return [Float](repeating: 0, count: x.count) }
        var mean: Float = 0; vDSP_meanv(x, 1, &mean, n)
        var neg = -mean
        var c = [Float](repeating: 0, count: x.count); vDSP_vsadd(x, 1, &neg, &c, 1, n)
        var ms: Float = 0; vDSP_measqv(c, 1, &ms, n)
        let sd = ms.squareRoot(); guard sd > 1e-9 else { return [Float](repeating: 0, count: x.count) }
        var inv = 1 / sd; var out = [Float](repeating: 0, count: x.count)
        vDSP_vsmul(c, 1, &inv, &out, 1, n); return out
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

    /// Separate a short (<= window) chunk into blind streams in one model pass, using
    /// `context` (real audio just before the chunk) to fill the window instead of
    /// zeros. Throws `SepFormerSeparator.SeparationError.modelMissing` if the model
    /// isn't installed.
    func separate(_ chunk: [Float], context: [Float]) async throws -> [[Float]] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    if self.separator == nil { self.separator = try SepFormerSeparator() }
                    continuation.resume(
                        returning: try self.separator!.separateChunk(chunk, leadingContext: context))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Compile + run one dummy inference off the critical path, so the first real
    /// overlap doesn't pay the model warm-up cost mid-conversation.
    func warmUp() {
        queue.async {
            guard self.separator == nil else { return }
            do {
                self.separator = try SepFormerSeparator()
                _ = try self.separator!.separateWindow([Float](repeating: 0, count: 64_000))
            } catch {
                self.separator = nil   // let the real call surface the error (e.g. modelMissing)
            }
        }
    }
}
