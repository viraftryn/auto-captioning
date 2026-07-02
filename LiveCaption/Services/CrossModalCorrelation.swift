import Accelerate

/// Cross-modal timing match: *does a face's lip movement rise and fall at the same
/// moments as an audio signal?* The face that is actually speaking is the one whose
/// mouth activity tracks the audio energy over time; a bystander who chews or smiles
/// moves their mouth at unrelated moments and scores low. This is the shared measure
/// behind speaker attribution — used both to pick the single speaker of a chunk
/// (`LiveCaptionEngine`) and to match blind SepFormer streams to faces
/// (`SourceAssignment`).
///
/// Everything works on short envelopes sampled on the video-frame grid, so the units
/// are tiny (a few dozen floats) and the whole thing is cheap.
enum CrossModalCorrelation {

    /// RMS energy of `signal` in a ±25 ms window centred on each video-frame time —
    /// the "loudness over time" envelope, on the same grid as the lip envelopes so
    /// the two can be correlated directly.
    static func energyEnvelope(_ signal: [Float], at times: [Double],
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

    /// Zero-mean, unit-variance normalise, so a dot product of two z-scored signals
    /// is their Pearson correlation. A flat/silent signal (zero variance) maps to all
    /// zeros, which correlates to 0 with anything → it can't win attribution.
    static func zscore(_ x: [Float]) -> [Float] {
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

    /// Best Pearson-like correlation of z-scored `a` vs `b`, allowing `b` to slide by
    /// up to ±`maxLag` frames. The camera and microphone arrive on separate queues
    /// with their own clocks, so a fixed zero-lag comparison underrates even the true
    /// speaker; searching a few frames of slack (≈100 ms at 30 fps) finds the real
    /// alignment and returns a sharper, more trustworthy peak. Result is ~[-1, 1].
    static func bestLaggedCorrelation(_ a: [Float], _ b: [Float], maxLag: Int) -> Float {
        guard a.count > 1, b.count > 1 else { return 0 }
        var best = -Float.greatestFiniteMagnitude
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                guard let baseA = pa.baseAddress, let baseB = pb.baseAddress else { return }
                for lag in -maxLag...maxLag {
                    // Pair a[i] with b[i - lag]; keep only in-bounds indices.
                    let start = max(0, lag)
                    let end = min(a.count, b.count + lag)
                    let count = end - start
                    guard count > 0 else { continue }
                    var sum: Float = 0
                    vDSP_dotpr(baseA + start, 1, baseB + (start - lag), 1, &sum, vDSP_Length(count))
                    let corr = sum / Float(count)
                    if corr > best { best = corr }
                }
            }
        }
        return best == -Float.greatestFiniteMagnitude ? 0 : best
    }
}
