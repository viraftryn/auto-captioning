import SwiftUI
import AppKit
import AVFoundation
import Vision
import QuartzCore

/// SwiftUI wrapper around an AppKit view that shows the live camera feed and
/// draws each tracked face's landmarks — coloured by whether that speaker is
/// currently active — plus a "Speaker N · LAR" label.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var faces: [TrackedFace]

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session: session)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.attach(session: session)
        nsView.render(faces)
    }
}

/// AppKit view hosting an `AVCaptureVideoPreviewLayer` plus overlay layers.
/// Active vs. inactive speakers are drawn into separate shape layers so each
/// can have its own colour; per-face labels live in a small `CATextLayer` pool.
final class PreviewView: NSView {

    let previewLayer = AVCaptureVideoPreviewLayer()
    private let activeBox = CAShapeLayer()
    private let inactiveBox = CAShapeLayer()
    private let activeLandmarks = CAShapeLayer()
    private let inactiveLandmarks = CAShapeLayer()
    private var labelLayers: [CATextLayer] = []
    private var faces: [TrackedFace] = []
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

        configure(inactiveLandmarks, color: .systemGray, width: 1.2, alpha: 0.7)
        configure(activeLandmarks, color: .systemGreen, width: 1.8, alpha: 0.95)
        configure(inactiveBox, color: .systemGray, width: 1.5, alpha: 0.8)
        configure(activeBox, color: .systemGreen, width: 2.5, alpha: 1.0)
        [inactiveBox, activeBox, inactiveLandmarks, activeLandmarks].forEach { root.addSublayer($0) }
    }

    private func configure(_ shape: CAShapeLayer, color: NSColor, width: CGFloat, alpha: CGFloat) {
        shape.fillColor = NSColor.clear.cgColor
        shape.strokeColor = color.withAlphaComponent(alpha).cgColor
        shape.lineWidth = width
        shape.lineJoin = .round
    }

    func attach(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
            didConfigureConnection = false
        }
        configureConnectionIfNeeded()
    }

    /// Keep Vision's (un-mirrored) coordinate space aligned with what's on screen
    /// by disabling preview mirroring.
    private func configureConnectionIfNeeded() {
        guard !didConfigureConnection, let connection = previewLayer.connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        didConfigureConnection = true
    }

    func render(_ faces: [TrackedFace]) {
        self.faces = faces
        configureConnectionIfNeeded()
        redraw()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        [activeBox, inactiveBox, activeLandmarks, inactiveLandmarks].forEach { $0.frame = bounds }
        redraw()
        CATransaction.commit()
    }

    private func label(_ index: Int) -> CATextLayer {
        if index < labelLayers.count { return labelLayers[index] }
        let text = CATextLayer()
        text.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        text.fontSize = 12
        text.alignmentMode = .center
        text.cornerRadius = 4
        text.masksToBounds = true
        text.foregroundColor = NSColor.black.cgColor
        layer?.addSublayer(text)
        labelLayers.append(text)
        return text
    }

    private func redraw() {
        // On-screen rectangle the video occupies (accounts for letterboxing).
        let videoRect = previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard videoRect.width > 0, videoRect.height > 0 else {
            [activeBox, inactiveBox, activeLandmarks, inactiveLandmarks].forEach { $0.path = nil }
            labelLayers.forEach { $0.isHidden = true }
            return
        }
        let scale = window?.backingScaleFactor ?? 2

        let activeBoxPath = CGMutablePath()
        let inactiveBoxPath = CGMutablePath()
        let activeLmPath = CGMutablePath()
        let inactiveLmPath = CGMutablePath()

        for (index, face) in faces.enumerated() {
            let obs = face.observation
            let bb = obs.boundingBox
            let rect = CGRect(x: videoRect.minX + bb.minX * videoRect.width,
                              y: videoRect.minY + bb.minY * videoRect.height,
                              width: bb.width * videoRect.width,
                              height: bb.height * videoRect.height)

            let boxPath = face.isActive ? activeBoxPath : inactiveBoxPath
            let lmPath = face.isActive ? activeLmPath : inactiveLmPath
            boxPath.addRect(rect)

            if let landmarks = obs.landmarks {
                func mapped(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                    guard let region else { return [] }
                    return region.normalizedPoints.map { p in
                        let ix = bb.minX + p.x * bb.width
                        let iy = bb.minY + p.y * bb.height
                        return CGPoint(x: videoRect.minX + ix * videoRect.width,
                                       y: videoRect.minY + iy * videoRect.height)
                    }
                }
                let open = [landmarks.faceContour, landmarks.noseCrest, landmarks.medianLine,
                            landmarks.leftEyebrow, landmarks.rightEyebrow, landmarks.nose]
                let closed = [landmarks.leftEye, landmarks.rightEye,
                              landmarks.outerLips, landmarks.innerLips]

                for region in open {
                    let pts = mapped(region)
                    guard let first = pts.first else { continue }
                    lmPath.move(to: first)
                    for p in pts.dropFirst() { lmPath.addLine(to: p) }
                }
                for region in closed {
                    let pts = mapped(region)
                    guard let first = pts.first else { continue }
                    lmPath.move(to: first)
                    for p in pts.dropFirst() { lmPath.addLine(to: p) }
                    lmPath.closeSubpath()
                }
                for pupil in [landmarks.leftPupil, landmarks.rightPupil] {
                    guard let p = mapped(pupil).first else { continue }
                    lmPath.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                }
            }

            let tag = label(index)
            tag.isHidden = false
            tag.contentsScale = scale
            tag.string = "S\(face.id) · \(String(format: "%.2f", face.smoothedLAR))"
            tag.frame = CGRect(x: rect.minX, y: rect.maxY + 3, width: 92, height: 18)
            tag.backgroundColor = (face.isActive ? NSColor.systemGreen : NSColor.systemGray)
                .withAlphaComponent(0.9).cgColor
        }
        for unused in faces.count..<labelLayers.count { labelLayers[unused].isHidden = true }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activeBox.path = activeBoxPath
        inactiveBox.path = inactiveBoxPath
        activeLandmarks.path = activeLmPath
        inactiveLandmarks.path = inactiveLmPath
        CATransaction.commit()
    }
}
