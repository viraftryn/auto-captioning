import Accelerate

/// Short-Time Fourier Transform with overlap-add inverse, built on vDSP.
///
/// Uses a **full complex FFT** per frame (not the packed real FFT) so spectral
/// masks can be applied bin-by-bin without fighting vDSP's packed DC/Nyquist
/// layout. Analysis and synthesis both use a sqrt-Hann window with 75% overlap,
/// and the inverse divides by the overlap-added window product — so with no mask
/// the round trip reconstructs the input almost exactly.
///
/// This is the "STFT → spectral mask → ISTFT" engine of the video-guided gating
/// stage.
final class STFTProcessor {

    let fftSize: Int
    let hopSize: Int

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let analysisWindow: [Float]   // sqrt-Hann
    private let synthesisWindow: [Float]  // sqrt-Hann

    init(fftSize: Int = 1024, hopSize: Int = 256) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.log2n = vDSP_Length(round(log2(Double(fftSize))))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        let sqrtHann = hann.map { $0.squareRoot() }
        self.analysisWindow = sqrtHann
        self.synthesisWindow = sqrtHann
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Complex spectrogram: `real[frame]` / `imag[frame]` each have `fftSize` bins.
    struct Spectrogram {
        let frameCount: Int
        let bins: Int
        let originalLength: Int
        var real: [[Float]]
        var imag: [[Float]]
    }

    // MARK: - Forward

    func forward(_ signal: [Float]) -> Spectrogram {
        let n = fftSize
        let frames = max(1, Int(ceil(Double(max(signal.count, 1)) / Double(hopSize))))
        let paddedLen = (frames - 1) * hopSize + n
        var padded = signal
        if paddedLen > padded.count {
            padded.append(contentsOf: [Float](repeating: 0, count: paddedLen - padded.count))
        }

        var realFrames = [[Float]](); realFrames.reserveCapacity(frames)
        var imagFrames = [[Float]](); imagFrames.reserveCapacity(frames)

        for f in 0..<frames {
            let start = f * hopSize
            var re = [Float](repeating: 0, count: n)
            var im = [Float](repeating: 0, count: n)
            padded.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + start, 1, analysisWindow, 1, &re, 1, vDSP_Length(n))
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            realFrames.append(re)
            imagFrames.append(im)
        }

        return Spectrogram(frameCount: frames, bins: n,
                           originalLength: signal.count,
                           real: realFrames, imag: imagFrames)
    }

    // MARK: - Inverse (overlap-add)

    func inverse(_ spec: Spectrogram) -> [Float] {
        let n = fftSize
        let frames = spec.frameCount
        let outLen = (frames - 1) * hopSize + n
        var output = [Float](repeating: 0, count: outLen)
        var norm = [Float](repeating: 0, count: outLen)
        let winProd = zip(analysisWindow, synthesisWindow).map(*)
        let invN = 1.0 / Float(n)

        for f in 0..<frames {
            var re = spec.real[f]
            var im = spec.imag[f]
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                }
            }
            let start = f * hopSize
            for i in 0..<n {
                output[start + i] += re[i] * invN * synthesisWindow[i]
                norm[start + i] += winProd[i]
            }
        }

        for i in 0..<outLen where norm[i] > 1e-6 { output[i] /= norm[i] }
        return Array(output.prefix(spec.originalLength))
    }

    // MARK: - Helpers

    /// Per-bin magnitude for one frame (length `fftSize`).
    static func magnitude(real: [Float], imag: [Float]) -> [Float] {
        let count = real.count
        var mag = [Float](repeating: 0, count: count)
        real.withUnsafeBufferPointer { rp in
            imag.withUnsafeBufferPointer { ip in
                var split = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: ip.baseAddress!))
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(count))
            }
        }
        return mag
    }
}
