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

        // Greedy maximum assignment: repeatedly take the best remaining
        // (stream, speaker) pair. For 2 streams this is equivalent to choosing the
        // better of the two permutations; for >2 faces it assigns each of the 2
        // streams to its most-correlated face and leaves the rest unmatched.
        var result = [Int?](repeating: nil, count: streams.count)
        var usedStreams = Set<Int>(), usedFaces = Set<Int>()
        for _ in 0..<min(streams.count, speakers.count) {
            var best: (i: Int, j: Int, v: Float)?
            for i in streamEnv.indices where !usedStreams.contains(i) {
                for j in speakers.indices where !usedFaces.contains(j) {
                    if best == nil || corr[i][j] > best!.v { best = (i, j, corr[i][j]) }
                }
            }
            guard let pick = best else { break }
            result[pick.i] = speakers[pick.j]
            usedStreams.insert(pick.i)
            usedFaces.insert(pick.j)
        }
        return result
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
