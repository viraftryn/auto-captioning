import Foundation

/// Lightweight energy-based Voice Activity Detector with an adaptive noise
/// floor, hysteresis, and hangover. Driven one call per audio buffer with the
/// buffer's mean-square energy (see `AudioMetrics.meanSquare`).
///
/// This is the audio half of cross-modal overlap detection: the video path says
/// *how many* mouths are moving, this says *whether speech is actually present*.
/// It deliberately does NOT try to count voices acoustically — that's a separate,
/// model-heavy problem, and it's unnecessary here because faces already provide
/// speaker identity.
final class VoiceActivityDetector {

    struct Config {
        var onMarginDB: Float = 6          // dB above noise floor to start speech
        var offMarginDB: Float = 3         // dB above floor to keep speech (hysteresis)
        var hangover: TimeInterval = 0.30  // keep "speech" this long after it drops
        var floorFall: Float = 0.05        // floor follows quieter ambient (moderate)
        var floorRise: Float = 0.005       // floor creeps up slowly (speech won't drag it)
        var minFloorDB: Float = -80
        var maxFloorDB: Float = -20
    }

    var config = Config()
    private(set) var energyDB: Float = -90
    private(set) var linearLevel: Float = 0
    private(set) var noiseFloorDB: Float = -55
    private(set) var isSpeech = false
    private(set) var speechLevel: Float = 0
    private var speechUntil: TimeInterval = 0
    private var initialized = false

    func process(meanSquare: Float, now: TimeInterval) {
        let rms = max(meanSquare, 0).squareRoot()
        linearLevel = rms
        let db = 20 * log10f(max(rms, 1e-7))
        energyDB = db

        // Adapt the noise floor toward the ongoing ambient level. Seeding it from
        // the first sample (instead of a fixed guess) and always allowing a slow
        // rise prevents the "stuck floor → permanent speech" deadlock.
        if !initialized {
            noiseFloorDB = db
            initialized = true
        } else if db < noiseFloorDB {
            noiseFloorDB += config.floorFall * (db - noiseFloorDB)
        } else {
            noiseFloorDB += config.floorRise * (db - noiseFloorDB)
        }
        noiseFloorDB = min(max(noiseFloorDB, config.minFloorDB), config.maxFloorDB)

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
        linearLevel = 0
        noiseFloorDB = -55
        energyDB = -90
        speechUntil = 0
        initialized = false
    }
}
