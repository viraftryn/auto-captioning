import Vision
import CoreGraphics
import QuartzCore

/// One tracked face/speaker, as published to the UI each frame.
struct TrackedFace: Identifiable {
    let id: Int                       // stable "Speaker N" id
    let observation: VNFaceObservation
    let rawLAR: Double                // mouth openness (display)
    let smoothedLAR: Double
    let activity: Double              // articulation: lip motion minus head motion
    let isActive: Bool
}

/// Tunable parameters for active-speaker detection. Defaults are starting
/// points — expect to tune `activityOn`/`activityOff` against the live readout.
struct LipActivityConfig {
    var smoothing: Double = 0.4           // EMA factor for LAR + activity
    var activityOn: Double = 0.008        // start "speaking" above this articulation
    var activityOff: Double = 0.006       // stop below this when there's NO speech (hysteresis)
    var activitySustain: Double = 0.002   // while the VAD hears speech, this tiny motion keeps the mover active
    var holdTime: TimeInterval = 0.8      // keep active this long after motion stops (generous grace)
    var matchIoU: CGFloat = 0.2           // min IoU to keep the same speaker id
    var staleTimeout: TimeInterval = 30   // keep a speaker id this long while unseen (stable labels)
}

/// Associates faces across frames (stable Speaker ids), measures lip
/// articulation per speaker, and flags active speakers + overlap.
///
/// Articulation is computed as **lip-landmark motion minus the motion of stable
/// reference landmarks (eyes + nose)**. Head/body movement shifts every landmark
/// together, so subtracting the reference cancels it and leaves only true mouth
/// movement — this is what stops fast body motion from reading as "speaking."
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
        var prevLip: [CGPoint]?
        var prevRef: [CGPoint]?
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

    // Landmark groups for the differential-motion measure.
    private static let lipRegions: [KeyPath<VNFaceLandmarks2D, VNFaceLandmarkRegion2D?>] =
        [\.outerLips, \.innerLips]
    private static let refRegions: [KeyPath<VNFaceLandmarks2D, VNFaceLandmarkRegion2D?>] =
        [\.leftEye, \.rightEye, \.nose, \.noseCrest]

    func reset() { tracks.removeAll() }

    func update(observations: [VNFaceObservation],
                imageSize: CGSize,
                now: TimeInterval = CACurrentMediaTime(),
                speechPresent: Bool = false) -> Result {

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

            // Mouth openness (display only).
            let raw = LipGeometry.lipApertureRatio(for: obs, imageSize: imageSize) ?? 0
            if track.initializedLAR {
                track.smoothedLAR = config.smoothing * raw + (1 - config.smoothing) * track.smoothedLAR
            } else {
                track.smoothedLAR = raw
                track.initializedLAR = true
            }

            // Articulation = lip motion minus reference (head) motion.
            let lip = Self.points(obs.landmarks, Self.lipRegions)
            let ref = Self.points(obs.landmarks, Self.refRegions)
            if let prevLip = track.prevLip, let prevRef = track.prevRef,
               prevLip.count == lip.count, prevRef.count == ref.count, !lip.isEmpty {
                let lipMotion = Self.meanDisplacement(lip, prevLip)
                let refMotion = ref.isEmpty ? 0 : Self.meanDisplacement(ref, prevRef)
                let net = max(0, lipMotion - refMotion)
                track.activity = config.smoothing * net + (1 - config.smoothing) * track.activity
            }
            track.prevLip = lip
            track.prevRef = ref

            // Onset by lips, sustained by voice: a face activates on real lip motion,
            // then -- crucially -- stays active as long as the VAD hears speech and the
            // lips still show a little movement, so a still-headed talker doesn't
            // flicker off between syllables. With no speech it falls back to the
            // motion-only hysteresis.
            if track.isActive {
                let stillMoving = track.activity >= config.activityOff
                let voiceSustained = speechPresent && track.activity >= config.activitySustain
                if stillMoving || voiceSustained { track.activeUntil = now + config.holdTime }
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

    /// Concatenated, face-box-normalized points for the given regions. Because
    /// the points are box-relative, head translation and scale are already
    /// factored out; only rotation + jitter + articulation remain.
    private static func points(_ landmarks: VNFaceLandmarks2D?,
                               _ keyPaths: [KeyPath<VNFaceLandmarks2D, VNFaceLandmarkRegion2D?>]) -> [CGPoint] {
        guard let landmarks else { return [] }
        var result: [CGPoint] = []
        for keyPath in keyPaths {
            if let region = landmarks[keyPath: keyPath] {
                result.append(contentsOf: region.normalizedPoints)
            }
        }
        return result
    }

    private static func meanDisplacement(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum = 0.0
        for i in a.indices {
            let dx = Double(a[i].x - b[i].x)
            let dy = Double(a[i].y - b[i].y)
            sum += (dx * dx + dy * dy).squareRoot()
        }
        return sum / Double(a.count)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
