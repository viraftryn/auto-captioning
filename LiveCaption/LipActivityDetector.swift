import Vision
import CoreGraphics
import QuartzCore

/// One tracked face/speaker, as published to the UI each frame.
struct TrackedFace: Identifiable {
    let id: Int                       // stable "Speaker N" id
    let observation: VNFaceObservation
    let rawLAR: Double
    let smoothedLAR: Double
    let activity: Double              // short-term lip motion (stddev of LAR)
    let isActive: Bool
}

/// Tunable parameters for active-speaker detection. Defaults are starting
/// points — expect to tune `activityOn`/`activityOff` against the live readout.
struct LipActivityConfig {
    var smoothing: Double = 0.4           // EMA factor for LAR (0..1, higher = snappier)
    var window: TimeInterval = 0.6        // activity (variance) window
    var activityOn: Double = 0.030        // start "speaking" above this lip-motion
    var activityOff: Double = 0.018       // stop below this (hysteresis)
    var holdTime: TimeInterval = 0.35     // keep active this long after motion stops
    var matchIoU: CGFloat = 0.2           // min IoU to keep the same speaker id
    var staleTimeout: TimeInterval = 0.5  // drop a speaker unseen for this long
}

/// Associates faces across frames (stable Speaker ids), computes a smoothed Lip
/// Aperture Ratio per speaker, and flags active speakers + overlap.
///
/// Implements the "Active speaker detection · Smoothed LAR + hold time" and
/// "Overlap detected? (2+ lips active)" nodes of the pipeline.
///
/// Not thread-safe: call `update`/`reset`/`config` from a single serial queue.
final class LipActivityDetector {

    struct Result {
        let faces: [TrackedFace]
        let activeCount: Int
        var overlap: Bool { activeCount >= 2 }
    }

    var config = LipActivityConfig()

    private final class Track {
        let id: Int
        var box: CGRect
        var smoothedLAR: Double = 0
        var initializedLAR = false
        var samples: [(t: TimeInterval, lar: Double)] = []
        var activity: Double = 0
        var isActive = false
        var activeUntil: TimeInterval = 0
        var lastSeen: TimeInterval
        var matchedObs: Int?

        init(id: Int, box: CGRect, now: TimeInterval) {
            self.id = id
            self.box = box
            self.lastSeen = now
        }
    }

    private var tracks: [Track] = []

    func reset() { tracks.removeAll() }

    func update(observations: [VNFaceObservation],
                imageSize: CGSize,
                now: TimeInterval = CACurrentMediaTime()) -> Result {

        // 1. Associate observations to existing tracks by IoU (greedy, 1:1).
        tracks.forEach { $0.matchedObs = nil }
        var pairs: [(track: Track, obs: Int, iou: CGFloat)] = []
        for track in tracks {
            for i in observations.indices {
                let iou = Self.iou(track.box, observations[i].boundingBox)
                if iou >= config.matchIoU { pairs.append((track, i, iou)) }
            }
        }
        pairs.sort { $0.iou > $1.iou }
        var usedObs = Set<Int>()
        for pair in pairs {
            if pair.track.matchedObs != nil || usedObs.contains(pair.obs) { continue }
            pair.track.matchedObs = pair.obs
            usedObs.insert(pair.obs)
        }

        // 2. Spawn new tracks for any unmatched observation.
        for i in observations.indices where !usedObs.contains(i) {
            let track = Track(id: nextFreeID(), box: observations[i].boundingBox, now: now)
            track.matchedObs = i
            tracks.append(track)
        }

        // 3. Update matched tracks; keep recently-seen unmatched ones alive briefly.
        var faces: [TrackedFace] = []
        var activeCount = 0
        var survivors: [Track] = []

        for track in tracks {
            guard let i = track.matchedObs else {
                if now - track.lastSeen <= config.staleTimeout { survivors.append(track) }
                continue
            }
            let obs = observations[i]
            track.box = obs.boundingBox
            track.lastSeen = now

            let raw = LipGeometry.lipApertureRatio(for: obs, imageSize: imageSize) ?? 0
            if track.initializedLAR {
                track.smoothedLAR = config.smoothing * raw + (1 - config.smoothing) * track.smoothedLAR
            } else {
                track.smoothedLAR = raw
                track.initializedLAR = true
            }

            // Activity = how much the mouth opening is *changing* (talking),
            // not just how open it is.
            track.samples.append((now, raw))
            track.samples.removeAll { now - $0.t > config.window }
            track.activity = Self.stddev(track.samples.map(\.lar))

            // Hysteresis + hold time keep the flag from flickering between words.
            if track.isActive {
                if track.activity >= config.activityOff { track.activeUntil = now + config.holdTime }
                if now > track.activeUntil { track.isActive = false }
            } else if track.activity >= config.activityOn {
                track.isActive = true
                track.activeUntil = now + config.holdTime
            }

            if track.isActive { activeCount += 1 }
            faces.append(TrackedFace(id: track.id,
                                     observation: obs,
                                     rawLAR: raw,
                                     smoothedLAR: track.smoothedLAR,
                                     activity: track.activity,
                                     isActive: track.isActive))
            survivors.append(track)
        }

        tracks = survivors.sorted { $0.id < $1.id }
        faces.sort { $0.id < $1.id }
        return Result(faces: faces, activeCount: activeCount)
    }

    // MARK: - Helpers

    /// Smallest free positive integer, so labels stay "Speaker 1/2/3".
    private func nextFreeID() -> Int {
        let used = Set(tracks.map(\.id))
        var id = 1
        while used.contains(id) { id += 1 }
        return id
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }

    private static func stddev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        return variance.squareRoot()
    }
}
