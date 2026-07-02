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

    /// Lag search width for stream↔face correlation: ±3 frames ≈ ±100 ms at 30 fps,
    /// enough to absorb audio/video capture offset without matching unrelated motion.
    private static let maxLagFrames = 3

    /// `result[i]` = the speaker id that stream `i` best matches (or `nil` if no
    /// face correlates / there are fewer faces than streams).
    static func assign(streams: [[Float]],
                       timeline: VideoAnalyzer.Timeline,
                       sampleRate: Double) -> [Int?] {
        let speakers = timeline.speakerIDs
        guard !streams.isEmpty, !speakers.isEmpty, !timeline.frames.isEmpty else {
            return Array(repeating: nil, count: streams.count)
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
    /// the summed correlation. Any streams beyond the number of faces get `nil`.
    /// Exhaustive, but the counts are tiny (2 streams; a handful of faces).
    private static func bestAssignment(_ corr: [[Float]], speakers: [Int]) -> [Int?] {
        let streamCount = corr.count
        let faceCount = speakers.count
        var current = [Int](repeating: -1, count: streamCount)
        var used = [Bool](repeating: false, count: faceCount)
        var best: (score: Float, pick: [Int])?

        func search(_ s: Int, _ score: Float) {
            if s == streamCount {
                if best == nil || score > best!.score { best = (score, current) }
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

        guard let best else { return Array(repeating: nil, count: streamCount) }
        return best.pick.map { $0 >= 0 ? speakers[$0] : nil }
    }
}
