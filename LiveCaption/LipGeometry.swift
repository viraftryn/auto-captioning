import Vision
import CoreGraphics

/// Pure geometry: turns a face's lip landmarks into a scale-invariant
/// Lip Aperture Ratio (LAR). This is the "Lip aperture ratio · innerLips +
/// outerLips contour" node of the pipeline.
enum LipGeometry {

    /// LAR = inner-lip vertical opening ÷ outer-lip width, measured in image
    /// pixels so the ratio is invariant to how far the face is from the camera.
    ///
    /// - A closed mouth collapses the inner-lip contour → LAR ≈ 0.
    /// - An open mouth grows the inner opening → LAR rises toward ~0.4+.
    ///
    /// Returns `nil` when the lip landmarks are missing or degenerate.
    static func lipApertureRatio(for face: VNFaceObservation,
                                 imageSize: CGSize) -> Double? {
        guard let landmarks = face.landmarks,
              let outer = landmarks.outerLips,
              let inner = landmarks.innerLips else { return nil }

        let outerPts = pixelPoints(outer, face: face, imageSize: imageSize)
        let innerPts = pixelPoints(inner, face: face, imageSize: imageSize)
        guard outerPts.count >= 2, innerPts.count >= 2 else { return nil }

        let width = horizontalExtent(outerPts)   // mouth corner-to-corner
        let aperture = verticalExtent(innerPts)   // inner opening height
        guard width > 1 else { return nil }       // guard divide-by-zero / noise

        return Double(aperture / width)
    }

    // MARK: - Helpers

    /// Lip points are normalized *within the face bounding box*; map them through
    /// the box and the image size to get true pixel coordinates.
    private static func pixelPoints(_ region: VNFaceLandmarkRegion2D,
                                    face: VNFaceObservation,
                                    imageSize: CGSize) -> [CGPoint] {
        let bb = face.boundingBox
        return region.normalizedPoints.map { p in
            CGPoint(x: (bb.minX + p.x * bb.width) * imageSize.width,
                    y: (bb.minY + p.y * bb.height) * imageSize.height)
        }
    }

    private static func horizontalExtent(_ pts: [CGPoint]) -> CGFloat {
        let xs = pts.map(\.x)
        return (xs.max() ?? 0) - (xs.min() ?? 0)
    }

    private static func verticalExtent(_ pts: [CGPoint]) -> CGFloat {
        let ys = pts.map(\.y)
        return (ys.max() ?? 0) - (ys.min() ?? 0)
    }
}
