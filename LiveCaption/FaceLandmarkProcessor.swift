import Vision
import CoreVideo
import CoreGraphics

/// Wraps Apple Vision's face-landmark detection so the rest of the app only
/// deals with `[VNFaceObservation]`.
///
/// This is the "Apple Vision · VNDetectFaceLandmarksRequest" node of the
/// pipeline. Later stages read the lip contours (`outerLips` / `innerLips`)
/// from these observations to compute the Lip Aperture Ratio.
final class FaceLandmarkProcessor {

    private let sequenceHandler = VNSequenceRequestHandler()

    /// Runs face + landmark detection on a single video frame.
    /// The completion handler is invoked synchronously on the calling queue.
    func detect(in pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation = .up,
                completion: ([VNFaceObservation]) -> Void) {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
            completion((request.results as? [VNFaceObservation]) ?? [])
        } catch {
            completion([])
        }
    }
}
