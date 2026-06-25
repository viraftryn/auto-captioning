import AVFoundation

/// Captures microphone audio with `AVAudioEngine` and converts it to the
/// 16 kHz mono Float32 format Whisper expects.
///
/// For Stage 1 we only surface an RMS level (so we can prove capture works);
/// later stages will consume `onBuffer` for the spectral-gating + Whisper path.
final class AudioEngine {

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    /// RMS level in 0...1, delivered on the audio thread.
    var onLevel: ((Float) -> Void)?
    /// 16 kHz mono Float32 buffers, delivered on the audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private(set) var isRunning = false

    init() {
        // Force-unwrap is safe: this is a fixed, always-valid PCM format.
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 16_000,
                                     channels: 1,
                                     interleaved: false)!
    }

    func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No audio input device available."])
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(inputBuffer: buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    // MARK: - Private

    private func handle(inputBuffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(inputBuffer.frameLength) * ratio).rounded(.up)) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, outBuffer.frameLength > 0 else { return }
        onLevel?(Self.rmsLevel(outBuffer))
        onBuffer?(outBuffer)
    }

    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        // Scale a typical speaking level into a usable 0...1 meter range.
        return min(1, rms * 12)
    }
}
