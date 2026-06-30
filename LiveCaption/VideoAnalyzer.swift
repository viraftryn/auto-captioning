import AVFoundation
import Vision
import CoreMedia
import CoreImage
import AppKit

/// Runs the lip-activity pipeline over a recorded video file offline. It stores
/// the *raw* per-frame activity per speaker (not a thresholded decision) so the
/// active/overlap timeline can be re-derived instantly when the user changes the
/// sensitivity — no re-decoding the video.
enum VideoAnalyzer {

    struct Timeline {
        struct Frame { let t: Double; let activity: [Int: Double] }

        let frames: [Frame]
        let speakerIDs: [Int]
        let thumbnails: [Int: NSImage]

        var hasSpeakers: Bool { !speakerIDs.isEmpty }

        func activeSet(at t: Double, threshold: Double) -> Set<Int> {
            guard let frame = nearestFrame(t) else { return [] }
            return Set(frame.activity.compactMap { $0.value >= threshold ? $0.key : nil })
        }

        func overlapDuration(threshold: Double) -> Double {
            guard frames.count > 1 else { return 0 }
            var total = 0.0
            for i in 1..<frames.count {
                let count = frames[i - 1].activity.values.filter { $0 >= threshold }.count
                if count >= 2 { total += frames[i].t - frames[i - 1].t }
            }
            return total
        }

        /// The single most-active face at time `t` (above `threshold`), for
        /// attributing a transcribed word to a speaker.
        func dominantSpeaker(at t: Double, threshold: Double) -> Int? {
            guard let frame = nearestFrame(t) else { return nil }
            let best = frame.activity.filter { $0.value >= threshold }.max { $0.value < $1.value }
            return best?.key
        }

        private func nearestFrame(_ t: Double) -> Frame? {
            guard !frames.isEmpty else { return nil }
            if t <= frames[0].t { return frames[0] }
            if t >= frames[frames.count - 1].t { return frames[frames.count - 1] }
            var lo = 0, hi = frames.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if frames[mid].t < t { lo = mid + 1 } else { hi = mid }
            }
            let b = frames[lo], a = frames[lo - 1]
            return (t - a.t) <= (b.t - t) ? a : b
        }
    }

    private static let ciContext = CIContext()

    static func analyze(url: URL, progress: ((Double) -> Void)? = nil) throws -> Timeline {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return Timeline(frames: [], speakerIDs: [], thumbnails: [:])
        }
        let duration = asset.duration.seconds

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return Timeline(frames: [], speakerIDs: [], thumbnails: [:]) }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoAnalyzer", code: 1)
        }

        let faceProcessor = FaceLandmarkProcessor()
        let detector = LipActivityDetector()
        var frames: [Timeline.Frame] = []
        var speakerSet = Set<Int>()
        var thumbnails: [Int: NSImage] = [:]
        var frameIndex = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                       height: CVPixelBufferGetHeight(pixelBuffer))
                var faces: [TrackedFace] = []
                faceProcessor.detect(in: pixelBuffer) { observations in
                    faces = detector.update(observations: observations,
                                            imageSize: imageSize, now: pts).faces
                }
                var activity: [Int: Double] = [:]
                for face in faces {
                    activity[face.id] = face.activity
                    speakerSet.insert(face.id)
                    if thumbnails[face.id] == nil {
                        thumbnails[face.id] = thumbnail(from: pixelBuffer,
                                                        boundingBox: face.observation.boundingBox)
                    }
                }
                frames.append(.init(t: pts, activity: activity))
            }
            CMSampleBufferInvalidate(sampleBuffer)

            frameIndex += 1
            if frameIndex % 30 == 0, duration > 0 { progress?(min(1, pts / duration)) }
        }

        if reader.status == .failed {
            throw reader.error ?? NSError(domain: "VideoAnalyzer", code: 2)
        }
        return Timeline(frames: frames, speakerIDs: speakerSet.sorted(), thumbnails: thumbnails)
    }

    /// Crop the speaker's face (with a little margin) into a thumbnail.
    private static func thumbnail(from pixelBuffer: CVPixelBuffer, boundingBox: CGRect) -> NSImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = ci.extent.width, h = ci.extent.height
        // Vision bbox + CIImage share a bottom-left origin, so this lines up.
        var rect = CGRect(x: boundingBox.minX * w, y: boundingBox.minY * h,
                          width: boundingBox.width * w, height: boundingBox.height * h)
        rect = rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.12).intersection(ci.extent)
        guard !rect.isNull, rect.width > 1, rect.height > 1,
              let cg = ciContext.createCGImage(ci, from: rect) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: rect.width, height: rect.height))
    }
}
