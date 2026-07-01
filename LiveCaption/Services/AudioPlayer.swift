import AVFoundation

/// Plays an in-memory mono Float buffer by writing a short temp file and using
/// `AVAudioPlayer`. This is far more robust than driving an `AVAudioEngine`
/// output graph right after the capture session held the audio device.
final class AudioPlayer: NSObject, ObservableObject {

    private var player: AVAudioPlayer?
    private let sampleRate: Double

    @Published private(set) var isPlaying = false

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
        super.init()
    }

    func play(_ samples: [Float]) {
        stop()
        guard !samples.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try Self.writeTempCAF(samples, sampleRate: self.sampleRate)
                DispatchQueue.main.async {
                    do {
                        let player = try AVAudioPlayer(contentsOf: url)
                        player.delegate = self
                        player.prepareToPlay()
                        player.play()
                        self.player = player
                        self.isPlaying = true
                    } catch {
                        print("AudioPlayer play error: \(error)")
                        self.isPlaying = false
                    }
                }
            } catch {
                print("AudioPlayer write error: \(error)")
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    private static func writeTempCAF(_ samples: [Float], sampleRate: Double) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("livecaption_\(UUID().uuidString).caf")

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "AudioPlayer", code: 1)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
        return url
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.isPlaying = false }
    }
}
