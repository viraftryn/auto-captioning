import Accelerate

/// Video-guided audio gating: STFT → spectral mask → ISTFT.
///
/// For a chosen target speaker, each STFT frame is gated using the video
/// timeline:
///  • target not active  → silence (hard gate, removes the other speaker's solo)
///  • target solo        → keep as-is (it's their voice)
///  • overlap (2+ active) → multiply by a harmonic comb built from the target's
///    F0, keeping bins near n·F0 and attenuating the rest to a small floor.
final class SeparationEngine {

    private let stft: STFTProcessor
    let sampleRate: Double

    init(fftSize: Int = 1024, hopSize: Int = 256, sampleRate: Double = MediaLoader.sampleRate) {
        stft = STFTProcessor(fftSize: fftSize, hopSize: hopSize)
        self.sampleRate = sampleRate
    }

    func spectrogram(of audio: [Float]) -> STFTProcessor.Spectrogram { stft.forward(audio) }

    func separate(audio: [Float],
                  timeline: VideoAnalyzer.Timeline,
                  target: Int,
                  f0: Double?,
                  threshold: Double,
                  alwaysMask: Bool,
                  floor: Float = 0.08) -> (samples: [Float], spec: STFTProcessor.Spectrogram) {
        var spec = stft.forward(audio)
        let n = stft.fftSize
        let hop = stft.hopSize
        let comb = f0.map { combMask(f0: $0, floor: floor, size: n) }

        for f in 0..<spec.frameCount {
            let centerTime = (Double(f * hop) + Double(n) / 2) / sampleRate
            let active = timeline.activeSet(at: centerTime, threshold: threshold)

            if !active.contains(target) {
                spec.real[f] = Self.scaled(spec.real[f], 0)
                spec.imag[f] = Self.scaled(spec.imag[f], 0)
            } else if let comb, alwaysMask || active.count >= 2 {
                spec.real[f] = Self.masked(spec.real[f], comb)
                spec.imag[f] = Self.masked(spec.imag[f], comb)
            }
            // target solo (and not always-mask) → leave the frame untouched.
        }

        return (stft.inverse(spec), spec)
    }

    /// Symmetric comb mask: Gaussian bumps centered on each harmonic of `f0`.
    private func combMask(f0: Double, floor: Float, size n: Int) -> [Float] {
        var mask = [Float](repeating: floor, count: n)
        let half = n / 2
        let f0f = Float(f0)
        let sigma = Float(max(20.0, f0 * 0.18))   // Hz; widened so pitch drift still passes

        for k in 0...half {
            let freq = Float(Double(k) * sampleRate / Double(n))
            let harmonic = (freq / f0f).rounded()
            var gain = floor
            if harmonic >= 1 {
                let dist = abs(freq - harmonic * f0f)
                gain = floor + (1 - floor) * expf(-(dist * dist) / (2 * sigma * sigma))
            }
            mask[k] = gain
            if k > 0 { mask[n - k] = gain }        // mirror → keeps output real
        }
        return mask
    }

    private static func scaled(_ a: [Float], _ g: Float) -> [Float] {
        var out = a, gain = g
        out.withUnsafeMutableBufferPointer { p in
            vDSP_vsmul(p.baseAddress!, 1, &gain, p.baseAddress!, 1, vDSP_Length(p.count))
        }
        return out
    }

    private static func masked(_ a: [Float], _ m: [Float]) -> [Float] {
        var out = a
        out.withUnsafeMutableBufferPointer { p in
            m.withUnsafeBufferPointer { mp in
                vDSP_vmul(p.baseAddress!, 1, mp.baseAddress!, 1, p.baseAddress!, 1, vDSP_Length(p.count))
            }
        }
        return out
    }
}
