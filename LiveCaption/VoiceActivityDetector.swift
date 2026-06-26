import AVFoundation
import Accelerate

/// Lightweight energy-based Voice Activity Detector with an adaptive noise
/// floor, hysteresis, and hangover. Runs on the audio thread, one call per
/// 16 kHz buffer.
///
/// This is the audio half of cross-modal overlap detection: the video path says
/// *how many* mouths are moving, this says *whether speech is actually present*.
/// It deliberately does NOT try to count voices acoustically — that's a separate,
/// model-heavy problem (overlapped-speech detection / diarization), and it's
/// unnecessary here because faces already provide speaker identity.
final class VoiceActivityDetector {

    struct Config {
        var onMarginDB: Float = 9          // dB above noise floor to start speech
        var offMarginDB: Float = 6         // dB above floor to keep speech (hysteresis)
        var hangover: TimeInterval = 0.25  // keep "speech" this long after it drops
        var floorRise: Float = 0.02        // noise floor adapts up slowly…
        var floorFall: Float = 0.25        // …and down quickly
        var minFloorDB: Float = -60
    }

    var config = Config()
    private(set) var energyDB: Float = -90
    private(set) var noiseFloorDB: Float = -50
    private(set) var isSpeech = false
    private(set) var speechLevel: Float = 0   // 0…1 confidence, for the meter
    private var speechUntil: TimeInterval = 0

    func process(buffer: AVAudioPCMBuffer, now: TimeInterval) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var meanSquare: Float = 0
        vDSP_measqv(channel, 1, &meanSquare, vDSP_Length(count))
        let db = 20 * log10f(max(meanSquare.squareRoot(), 1e-7))
        energyDB = db

        // Adapt the noise floor: follow quiet backgrounds quickly, resist speech.
        if db < noiseFloorDB {
            noiseFloorDB += config.floorFall * (db - noiseFloorDB)
        } else if !isSpeech {
            noiseFloorDB += config.floorRise * (db - noiseFloorDB)
        }
        noiseFloorDB = max(noiseFloorDB, config.minFloorDB)

        // Hysteresis + hangover so the flag doesn't chatter between words.
        let over = db - noiseFloorDB
        if isSpeech {
            if over >= config.offMarginDB { speechUntil = now + config.hangover }
            if now > speechUntil { isSpeech = false }
        } else if over >= config.onMarginDB {
            isSpeech = true
            speechUntil = now + config.hangover
        }

        speechLevel = max(0, min(1, over / (config.onMarginDB * 1.5)))
    }

    func reset() {
        isSpeech = false
        speechLevel = 0
        noiseFloorDB = -50
        energyDB = -90
        speechUntil = 0
    }
}
