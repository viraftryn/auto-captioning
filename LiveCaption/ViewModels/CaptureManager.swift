import AVFoundation
import CoreMedia
import Vision
import Combine
import QuartzCore

/// Owns a single `AVCaptureSession` for BOTH video and audio, runs Vision
/// face-landmark detection + lip-activity per frame, runs a VAD per audio
/// buffer, and publishes everything the UI needs.
///
/// Audio is captured through the capture session (not `AVAudioEngine`): on
/// macOS this reliably delivers mic sample buffers alongside the camera — even
/// with external / Continuity cameras — and keeps audio and video on one clock.
final class CaptureManager: NSObject, ObservableObject {

    // MARK: Published state
    @Published private(set) var trackedFaces: [TrackedFace] = []
    @Published private(set) var faceCount: Int = 0
    @Published private(set) var activeSpeakerCount: Int = 0
    @Published private(set) var overlapDetected: Bool = false
    @Published private(set) var fps: Double = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var audioSpeechActive: Bool = false
    @Published private(set) var speechLevel: Float = 0
    @Published private(set) var audioEnergyDB: Float = -90
    @Published private(set) var noiseFloorDB: Float = -60
    @Published private(set) var audioDeviceName: String = ""
    @Published private(set) var isRunning = false
    @Published private(set) var cameraAuthorized = false
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var statusMessage = "Idle"

    // MARK: Capture plumbing
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.aiml.livecaption.session")
    private let videoQueue = DispatchQueue(label: "com.aiml.livecaption.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.aiml.livecaption.audio", qos: .userInitiated)
    private let faceProcessor = FaceLandmarkProcessor()
    private let detector = LipActivityDetector()
    private let vad = VoiceActivityDetector()
    private var isConfigured = false

    // Latest evidence for cross-modal overlap (main-thread only).
    private var lastVisualOverlap = false
    private var lastAudioSpeech = false

    // Rolling 1-second window of frame timestamps, for an FPS readout.
    private var frameTimes: [CFTimeInterval] = []

    // MARK: - Lifecycle

    func start() {
        requestAuthorization { [weak self] camera, microphone in
            guard let self else { return }
            DispatchQueue.main.async {
                self.cameraAuthorized = camera
                self.microphoneAuthorized = microphone
            }
            guard camera else {
                DispatchQueue.main.async {
                    self.statusMessage = "Camera denied — enable it in System Settings ▸ Privacy & Security ▸ Camera."
                }
                return
            }
            self.sessionQueue.async {
                self.configureSessionIfNeeded(includeAudio: microphone)
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.statusMessage = microphone ? "Running" : "Running (no mic access)"
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        videoQueue.async { self.detector.reset() }
        audioQueue.async { self.vad.reset() }
        DispatchQueue.main.async {
            self.isRunning = false
            self.audioLevel = 0
            self.audioSpeechActive = false
            self.speechLevel = 0
            self.audioEnergyDB = -90
            self.noiseFloorDB = -60
            self.lastAudioSpeech = false
            self.lastVisualOverlap = false
            self.trackedFaces = []
            self.faceCount = 0
            self.activeSpeakerCount = 0
            self.overlapDetected = false
            self.fps = 0
            self.statusMessage = "Stopped"
        }
    }

    func toggle() { isRunning ? stop() : start() }

    /// Push tuning changes to the detector (applied on the video queue so it
    /// never races with frame processing).
    func setConfig(_ config: LipActivityConfig) {
        videoQueue.async { self.detector.config = config }
    }

    /// Adjust how many dB above the noise floor counts as speech (applied on the
    /// audio queue). Lower = more sensitive. `off` margin trails it for hysteresis.
    func setSpeechMargin(_ onMarginDB: Float) {
        audioQueue.async {
            self.vad.config.onMarginDB = onMarginDB
            self.vad.config.offMarginDB = max(1, onMarginDB - 3)
        }
    }

    /// Overlap requires BOTH cues: 2+ mouths moving (video) and speech actually
    /// present (audio). Recomputed on the main thread whenever either updates.
    private func recomputeOverlap() {
        overlapDetected = lastVisualOverlap && lastAudioSpeech
    }

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

    private func configureSessionIfNeeded(includeAudio: Bool) {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        // Video input + output.
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

        // Audio input + output (same session).
        if includeAudio {
            if let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
                audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
                let name = mic.localizedName
                DispatchQueue.main.async { self.audioDeviceName = name }
            } else {
                DispatchQueue.main.async { self.statusMessage = "No microphone found." }
            }
        }

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

// MARK: - Sample buffer delegate (video + audio share one selector)

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === audioOutput {
            handleAudio(sampleBuffer)   // on audioQueue
        } else {
            handleVideo(sampleBuffer)   // on videoQueue
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        let now = CACurrentMediaTime()

        faceProcessor.detect(in: pixelBuffer) { [weak self] observations in
            guard let self else { return }
            let result = self.detector.update(observations: observations,
                                               imageSize: imageSize,
                                               now: now)
            DispatchQueue.main.async {
                self.trackedFaces = result.faces
                self.faceCount = result.faces.count
                self.activeSpeakerCount = result.activeCount
                self.lastVisualOverlap = result.overlap
                self.recomputeOverlap()
            }
        }

        updateFPS()
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let meanSquare = AudioMetrics.meanSquare(of: sampleBuffer) else { return }
        vad.process(meanSquare: meanSquare, now: CACurrentMediaTime())

        let speech = vad.isSpeech
        let speechLvl = vad.speechLevel
        let energyDB = vad.energyDB
        let floorDB = vad.noiseFloorDB
        let linear = vad.linearLevel
        DispatchQueue.main.async {
            self.audioLevel = min(1, linear * 12)
            self.audioSpeechActive = speech
            self.speechLevel = speechLvl
            self.audioEnergyDB = energyDB
            self.noiseFloorDB = floorDB
            self.lastAudioSpeech = speech
            self.recomputeOverlap()
        }
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
