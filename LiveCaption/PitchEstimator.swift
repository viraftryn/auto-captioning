import Accelerate

/// Estimates a speaker's fundamental frequency (F0 / pitch) from a chunk of
/// their solo speech, using normalized autocorrelation. This builds the "voice
/// fingerprint" the harmonic mask targets.
enum PitchEstimator {

    /// Median F0 (Hz) over voiced frames, or `nil` if the signal is too short or
    /// has no clearly voiced content.
    static func estimateF0(_ signal: [Float],
                           sampleRate: Double,
                           minF0: Double = 75,
                           maxF0: Double = 350) -> Double? {
        let frameSize = 1024
        let hop = 512
        guard signal.count >= frameSize else { return nil }

        let minLag = max(1, Int(sampleRate / maxF0))
        let maxLag = min(frameSize - 1, Int(sampleRate / minF0))
        guard maxLag > minLag else { return nil }

        var f0s: [Double] = []
        var start = 0
        while start + frameSize <= signal.count {
            let frame = Array(signal[start ..< start + frameSize])
            if let (lag, clarity) = bestLag(frame, minLag: minLag, maxLag: maxLag), clarity > 0.5 {
                f0s.append(sampleRate / Double(lag))
            }
            start += hop
        }

        guard !f0s.isEmpty else { return nil }
        f0s.sort()
        return f0s[f0s.count / 2]
    }

    /// Returns (lag, voicing-clarity). Picks the *smallest* lag whose normalized
    /// autocorrelation is near the global max, to avoid octave-down errors.
    private static func bestLag(_ frame: [Float], minLag: Int, maxLag: Int) -> (Int, Float)? {
        let n = frame.count
        return frame.withUnsafeBufferPointer { p -> (Int, Float)? in
            guard let base = p.baseAddress else { return nil }
            var nccs = [Float](repeating: 0, count: maxLag + 1)
            var globalMax: Float = 0
            for lag in minLag...maxLag {
                let m = vDSP_Length(n - lag)
                var corr: Float = 0, e1: Float = 0, e2: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &corr, m)
                vDSP_dotpr(base, 1, base, 1, &e1, m)
                vDSP_dotpr(base + lag, 1, base + lag, 1, &e2, m)
                let ncc = corr / ((e1 * e2).squareRoot() + 1e-9)
                nccs[lag] = ncc
                if ncc > globalMax { globalMax = ncc }
            }
            guard globalMax > 0 else { return nil }
            let threshold = 0.9 * globalMax
            for lag in minLag...maxLag where nccs[lag] >= threshold {
                return (lag, globalMax)
            }
            return nil
        }
    }
}
