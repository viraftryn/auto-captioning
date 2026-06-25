import AVFoundation
import CoreMedia
import Vision
import Combine
import QuartzCore

/// Owns the `AVCaptureSession` (video) and `AudioEngine` (audio), runs Vision
/// face-landmark detection on each frame, and publishes everything the UI needs.
///
/// This is the orchestration hub for Stage 1 — the "AVFoundation camera capture"
/// box that fans out into the audio path and the video path.
final class CaptureManager: NSObject, ObservableObject {

    // MARK: Published state
    @Published private(set) var faceObservations: [VNFaceObservation] = []
    @Published private(set) var faceCount: Int = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var isRunning = false
    @Published private(set) var cameraAuthorized = false
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var statusMessage = "Idle"

    // MARK: Capture plumbing
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.aiml.livecaption.session")
    private let videoQueue = DispatchQueue(label: "com.aiml.livecaption.video", qos: .userInitiated)
    private let faceProcessor = FaceLandmarkProcessor()
    private let audioEngine = AudioEngine()
    private var isConfigured = false

    // Rolling 1-second window of frame timestamps, for an FPS readout.
    private var frameTimes: [CFTimeInterval] = []

    override init() {
        super.init()
        audioEngine.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.audioLevel = level }
        }
    }

    // MARK: - Lifecycle

    func start() {
        requestAuthorization { [weak self] camera, microphone in
            guard let self else { return }
            DispatchQueue.main.async {
                self.cameraAuthorized = camera
                self.microphoneAuthorized = microphone
            }

            if camera {
                self.sessionQueue.async {
                    self.configureSessionIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    DispatchQueue.main.async {
                        self.isRunning = true
                        self.statusMessage = "Running"
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.statusMessage = "Camera denied — enable it in System Settings ▸ Privacy & Security ▸ Camera."
                }
            }

            if microphone {
                do { try self.audioEngine.start() }
                catch {
                    DispatchQueue.main.async {
                        self.statusMessage = "Audio error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        audioEngine.stop()
        DispatchQueue.main.async {
            self.isRunning = false
            self.audioLevel = 0
            self.faceObservations = []
            self.faceCount = 0
            self.fps = 0
            self.statusMessage = "Stopped"
        }
    }

    func toggle() { isRunning ? stop() : start() }

    // MARK: - Authorization

    private func requestAuthorization(completion: @escaping (_ camera: Bool, _ microphone: Bool) -> Void) {
        requestAccess(for: .video) { camera in
            self.requestAccess(for: .audio) { microphone in
                completion(camera, microphone)
            }
        }
    }

    private func requestAccess(for type: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: type, completionHandler: completion)
        default:
            completion(false)
        }
    }

    // MARK: - Session configuration

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        if let device = bestVideoDevice(),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        } else {
            DispatchQueue.main.async { self.statusMessage = "No camera found." }
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
        isConfigured = true
    }

    private func bestVideoDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

// MARK: - Video frame delegate

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        faceProcessor.detect(in: pixelBuffer) { [weak self] observations in
            guard let self else { return }
            DispatchQueue.main.async {
                self.faceObservations = observations
                self.faceCount = observations.count
            }
        }

        updateFPS()
    }

    /// Runs on `videoQueue`, so `frameTimes` needs no extra locking.
    private func updateFPS() {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1.0 }
        let count = frameTimes.count
        DispatchQueue.main.async { self.fps = Double(count) }
    }
}
