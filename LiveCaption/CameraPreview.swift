import SwiftUI
import AppKit
import AVFoundation
import Vision
import QuartzCore

/// SwiftUI wrapper around an AppKit view that shows the live camera feed and
/// draws the detected face landmarks on top of it.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var observations: [VNFaceObservation]

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session: session)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.attach(session: session)
        nsView.render(observations)
    }
}

/// AppKit view hosting an `AVCaptureVideoPreviewLayer` plus two overlay layers:
/// a yellow face bounding box and the green landmark contours.
final class PreviewView: NSView {

    let previewLayer = AVCaptureVideoPreviewLayer()
    private let boxLayer = CAShapeLayer()
    private let landmarkLayer = CAShapeLayer()
    private var observations: [VNFaceObservation] = []
    private var didConfigureConnection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root

        previewLayer.videoGravity = .resizeAspect
        root.addSublayer(previewLayer)

        boxLayer.fillColor = NSColor.clear.cgColor
        boxLayer.strokeColor = NSColor.systemYellow.cgColor
        boxLayer.lineWidth = 2
        root.addSublayer(boxLayer)

        landmarkLayer.fillColor = NSColor.clear.cgColor
        landmarkLayer.strokeColor = NSColor.systemGreen.withAlphaComponent(0.9).cgColor
        landmarkLayer.lineWidth = 1.5
        root.addSublayer(landmarkLayer)
    }

    func attach(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
            didConfigureConnection = false
        }
        configureConnectionIfNeeded()
    }

    /// Keep Vision's (un-mirrored) coordinate space aligned with what's on
    /// screen by disabling preview mirroring. We can add a mirror toggle later
    /// by flipping both the preview connection and the overlay's X axis.
    private func configureConnectionIfNeeded() {
        guard !didConfigureConnection, let connection = previewLayer.connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        didConfigureConnection = true
    }

    func render(_ observations: [VNFaceObservation]) {
        self.observations = observations
        configureConnectionIfNeeded()
        redraw()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        boxLayer.frame = bounds
        landmarkLayer.frame = bounds
        redraw()
        CATransaction.commit()
    }

    private func redraw() {
        // The on-screen rectangle the video actually occupies (accounts for
        // letterboxing from `.resizeAspect`).
        let videoRect = previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard videoRect.width > 0, videoRect.height > 0 else {
            boxLayer.path = nil
            landmarkLayer.path = nil
            return
        }

        let boxPath = CGMutablePath()
        let landmarkPath = CGMutablePath()

        for face in observations {
            let bb = face.boundingBox // normalized, bottom-left origin
            let rect = CGRect(x: videoRect.minX + bb.minX * videoRect.width,
                              y: videoRect.minY + bb.minY * videoRect.height,
                              width: bb.width * videoRect.width,
                              height: bb.height * videoRect.height)
            boxPath.addRect(rect)

            guard let landmarks = face.landmarks else { continue }

            // Landmark points are normalized *within the face bounding box*, so
            // map them through the box and then into the on-screen video rect.
            func mapped(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                guard let region else { return [] }
                return region.normalizedPoints.map { p in
                    let ix = bb.minX + p.x * bb.width
                    let iy = bb.minY + p.y * bb.height
                    return CGPoint(x: videoRect.minX + ix * videoRect.width,
                                   y: videoRect.minY + iy * videoRect.height)
                }
            }

            let openRegions = [landmarks.faceContour, landmarks.noseCrest, landmarks.medianLine,
                               landmarks.leftEyebrow, landmarks.rightEyebrow, landmarks.nose]
            let closedRegions = [landmarks.leftEye, landmarks.rightEye,
                                 landmarks.outerLips, landmarks.innerLips]

            for region in openRegions {
                let pts = mapped(region)
                guard let first = pts.first else { continue }
                landmarkPath.move(to: first)
                for p in pts.dropFirst() { landmarkPath.addLine(to: p) }
            }
            for region in closedRegions {
                let pts = mapped(region)
                guard let first = pts.first else { continue }
                landmarkPath.move(to: first)
                for p in pts.dropFirst() { landmarkPath.addLine(to: p) }
                landmarkPath.closeSubpath()
            }
            for pupil in [landmarks.leftPupil, landmarks.rightPupil] {
                guard let p = mapped(pupil).first else { continue }
                landmarkPath.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boxLayer.path = boxPath
        landmarkLayer.path = landmarkPath
        CATransaction.commit()
    }
}
