import Accelerate

/// Matches blind SepFormer outputs to video-detected speakers.
///
/// SepFormer separates a mixture into source waveforms but has no idea *whose*
/// voice each one is — the comb mask knew, because we handed it a speaker's F0.
/// We recover identity cross-modally: a stream carrying speaker S's voice has
/// acoustic energy exactly when S's lips are moving. So we build each stream's
/// short-time energy envelope on the video frame grid, build each face's
/// lip-activity envelope from the `Timeline`, and assign streams to faces by the
/// best correlation. This reuses the same `Timeline.activity` that drives
/// active-speaker detection and attribution.
enum SourceAssignment {

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
        let streamEnv = streams.map { zscore(energyEnvelope($0, at: times, sampleRate: sampleRate)) }
        let faceEnv: [Int: [Float]] = Dictionary(uniqueKeysWithValues: speakers.map { id in
            (id, zscore(timeline.frames.map { Float($0.activity[id] ?? 0) }))
        })

        // Correlation matrix: streams × speakers (z-scored dot ≈ Pearson r).
        let denom = Float(max(1, times.count))
        var corr = [[Float]](repeating: [Float](repeating: 0, count: speakers.count),
                             count: streams.count)
        for (i, env) in streamEnv.enumerated() {
            for (j, id) in speakers.enumerated() {
                corr[i][j] = dot(env, faceEnv[id]!) / denom
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

    /// RMS energy of `signal` in a ±25 ms window centred on each video frame time.
    private static func energyEnvelope(_ signal: [Float], at times: [Double],
                                       sampleRate: Double) -> [Float] {
        let half = max(1, Int(0.025 * sampleRate))
        var env = [Float](repeating: 0, count: times.count)
        signal.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for (k, t) in times.enumerated() {
                let c = Int(t * sampleRate)
                let lo = max(0, c - half), hi = min(signal.count, c + half)
                guard hi > lo else { continue }
                var ms: Float = 0
                vDSP_measqv(base + lo, 1, &ms, vDSP_Length(hi - lo))
                env[k] = ms.squareRoot()
            }
        }
        return env
    }

    /// Zero-mean, unit-variance normalise (so a dot product is a correlation).
    private static func zscore(_ x: [Float]) -> [Float] {
        let n = vDSP_Length(x.count)
        guard x.count > 1 else { return [Float](repeating: 0, count: x.count) }
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, n)
        var negMean = -mean
        var centered = [Float](repeating: 0, count: x.count)
        vDSP_vsadd(x, 1, &negMean, &centered, 1, n)
        var ms: Float = 0
        vDSP_measqv(centered, 1, &ms, n)          // variance of centred signal
        let sd = ms.squareRoot()
        guard sd > 1e-9 else { return [Float](repeating: 0, count: x.count) }
        var inv = 1 / sd
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsmul(centered, 1, &inv, &out, 1, n)
        return out
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }
}
