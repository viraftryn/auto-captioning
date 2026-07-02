/// Matches blind SepFormer outputs to video-detected speakers.
///
/// SepFormer separates a mixture into source waveforms but has no idea *whose*
/// voice each one is. We recover identity cross-modally: a stream carrying speaker
/// S's voice has acoustic energy exactly when S's lips are moving. So we build each
/// stream's energy envelope on the video frame grid, build each face's lip-activity
/// envelope from the `Timeline`, and assign streams to faces by the best timing
/// correlation (see `CrossModalCorrelation`) — the same measure that drives
/// single-speaker attribution in `LiveCaptionEngine`.
enum SourceAssignment {

    /// A stream→face assignment plus how trustworthy it is.
    struct Assignment {
        /// `mapping[i]` = the speaker id stream `i` best matches (or `nil` if no face
        /// correlates / there are fewer faces than streams).
        let mapping: [Int?]
        /// How much the chosen pairing beats the next-best injective pairing, in
        /// summed-correlation units. Small = the streams matched two faces almost
        /// equally well, so the pairing (which is which) is a coin-flip — callers
        /// should treat a low value as "don't trust this separation."
        let confidence: Float
    }

    /// Lag search width for stream↔face correlation: ±3 frames ≈ ±100 ms at 30 fps,
    /// enough to absorb audio/video capture offset without matching unrelated motion.
    private static let maxLagFrames = 3

    /// `result[i]` = the speaker id that stream `i` best matches (or `nil`). Thin
    /// wrapper over `resolve` for callers that don't need the confidence.
    static func assign(streams: [[Float]],
                       timeline: VideoAnalyzer.Timeline,
                       sampleRate: Double) -> [Int?] {
        resolve(streams: streams, timeline: timeline, sampleRate: sampleRate).mapping
    }

    /// Full result: the best injective stream→face assignment and its confidence.
    static func resolve(streams: [[Float]],
                        timeline: VideoAnalyzer.Timeline,
                        sampleRate: Double) -> Assignment {
        let speakers = timeline.speakerIDs
        guard !streams.isEmpty, !speakers.isEmpty, !timeline.frames.isEmpty else {
            return Assignment(mapping: Array(repeating: nil, count: streams.count), confidence: 0)
        }

        let times = timeline.frames.map { $0.t }
        let streamEnv = streams.map {
            CrossModalCorrelation.zscore(
                CrossModalCorrelation.energyEnvelope($0, at: times, sampleRate: sampleRate))
        }
        let faceEnv: [Int: [Float]] = Dictionary(uniqueKeysWithValues: speakers.map { id in
            (id, CrossModalCorrelation.zscore(timeline.frames.map { Float($0.activity[id] ?? 0) }))
        })

        // Lag-tolerant correlation matrix: streams × speakers.
        var corr = [[Float]](repeating: [Float](repeating: 0, count: speakers.count),
                             count: streams.count)
        for (i, env) in streamEnv.enumerated() {
            for (j, id) in speakers.enumerated() {
                corr[i][j] = CrossModalCorrelation.bestLaggedCorrelation(env, faceEnv[id]!,
                                                                         maxLag: maxLagFrames)
            }
        }

        // Assign a DISTINCT face to each stream maximising the *total* correlation.
        // A greedy pick-the-best-pair-first can lock in a locally-best pair that
        // forces the other stream onto the wrong face (→ swapped speakers); the
        // globally-best pairing avoids that and is cheap here (2 streams).
        return bestAssignment(corr, speakers: speakers)
    }

    /// Injective stream→face assignment (a distinct face per stream) that maximises
    /// the summed correlation, plus the margin to the next-best pairing. Any streams
    /// beyond the number of faces get `nil`. Exhaustive, but the counts are tiny
    /// (2 streams; a handful of faces).
    private static func bestAssignment(_ corr: [[Float]], speakers: [Int]) -> Assignment {
        let streamCount = corr.count
        let faceCount = speakers.count
        var current = [Int](repeating: -1, count: streamCount)
        var used = [Bool](repeating: false, count: faceCount)
        var scored: [(score: Float, pick: [Int])] = []

        func search(_ s: Int, _ score: Float) {
            if s == streamCount {
                scored.append((score, current))
                return
            }
            var placed = false
            for j in 0..<faceCount where !used[j] {
                used[j] = true; current[s] = j
                search(s + 1, score + corr[s][j])
                used[j] = false; current[s] = -1
                placed = true
            }
            if !placed { search(s + 1, score) }   // more streams than faces → leave nil
        }
        search(0, 0)

        guard let best = scored.max(by: { $0.score < $1.score }) else {
            return Assignment(mapping: Array(repeating: nil, count: streamCount), confidence: 0)
        }
        let runnerUp = scored.filter { $0.pick != best.pick }.map(\.score).max()
        let confidence = max(0, runnerUp.map { best.score - $0 } ?? best.score)
        let mapping = best.pick.map { $0 >= 0 ? speakers[$0] : nil }
        return Assignment(mapping: mapping, confidence: confidence)
    }
}
