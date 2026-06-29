import AVFoundation

/// Plays an in-memory mono Float buffer (used for A/B comparison of original vs
/// separated audio in the analysis lab).
final class AudioPlayer: ObservableObject {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    @Published private(set) var isPlaying = false

    init(sampleRate: Double = 16_000) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: sampleRate,
                               channels: 1,
                               interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ samples: [Float]) {
        stop()
        guard !samples.isEmpty, let buffer = makeBuffer(samples) else { return }
        do {
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
                DispatchQueue.main.async { self?.isPlaying = false }
            }
            player.play()
            isPlaying = true
        } catch {
            print("AudioPlayer start error: \(error)")
        }
    }

    func stop() {
        if player.isPlaying { player.stop() }
        isPlaying = false
    }

    private func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}
