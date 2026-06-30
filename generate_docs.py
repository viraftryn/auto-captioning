#!/usr/bin/env python3
"""Generate a PDF documentation of the LiveCaption pipeline (Stages 1-5)."""

from fpdf import FPDF

class DocPDF(FPDF):
    def __init__(self):
        super().__init__()
        self.set_auto_page_break(auto=True, margin=25)

    def header(self):
        if self.page_no() > 1:
            self.set_font("Helvetica", "I", 8)
            self.set_text_color(130, 130, 130)
            self.cell(0, 6, "LiveCaption - Technical Documentation", align="L")
            self.cell(0, 6, f"Page {self.page_no()}", align="R")
            self.ln(10)
            self.set_draw_color(200, 200, 200)
            self.line(10, self.get_y(), 200, self.get_y())
            self.ln(4)

    def footer(self):
        pass

    def title_page(self):
        self.add_page()
        self.ln(50)
        self.set_font("Helvetica", "B", 28)
        self.set_text_color(30, 30, 30)
        self.cell(0, 14, "LiveCaption", align="C", new_x="LMARGIN", new_y="NEXT")
        self.ln(4)
        self.set_font("Helvetica", "", 16)
        self.set_text_color(80, 80, 80)
        self.cell(0, 10, "Speaker-Attributed Live Captioning System", align="C", new_x="LMARGIN", new_y="NEXT")
        self.ln(6)
        self.set_draw_color(0, 120, 200)
        self.set_line_width(0.8)
        self.line(60, self.get_y(), 150, self.get_y())
        self.ln(10)
        self.set_font("Helvetica", "", 12)
        self.set_text_color(100, 100, 100)
        self.cell(0, 8, "Technical Documentation", align="C", new_x="LMARGIN", new_y="NEXT")
        self.cell(0, 8, "Implementation Details  |  Stages 1-5", align="C", new_x="LMARGIN", new_y="NEXT")
        self.ln(30)
        self.set_font("Helvetica", "", 10)
        self.cell(0, 7, "Platform: macOS 14.0+ (SwiftUI + AVFoundation + Vision + Accelerate)", align="C", new_x="LMARGIN", new_y="NEXT")
        self.cell(0, 7, "Language: Swift 5  |  Build: XcodeGen + Xcode", align="C", new_x="LMARGIN", new_y="NEXT")
        self.cell(0, 7, "ML Frameworks: Apple Vision, WhisperKit (CoreML), vDSP (Accelerate)", align="C", new_x="LMARGIN", new_y="NEXT")
        self.ln(20)
        self.set_font("Helvetica", "I", 9)
        self.set_text_color(140, 140, 140)
        self.cell(0, 7, "AIML Institute - Challenge 1: Audio Auto-Captioning", align="C", new_x="LMARGIN", new_y="NEXT")
        self.cell(0, 7, "June 2026", align="C", new_x="LMARGIN", new_y="NEXT")

    def chapter_title(self, num, title):
        self.add_page()
        self.set_font("Helvetica", "B", 20)
        self.set_text_color(0, 90, 180)
        self.cell(0, 12, f"{num}. {title}", new_x="LMARGIN", new_y="NEXT")
        self.set_draw_color(0, 90, 180)
        self.set_line_width(0.6)
        self.line(10, self.get_y() + 2, 200, self.get_y() + 2)
        self.ln(8)
        self.set_text_color(30, 30, 30)

    def section(self, title):
        self.ln(4)
        self.set_font("Helvetica", "B", 13)
        self.set_text_color(50, 50, 50)
        self.cell(0, 8, title, new_x="LMARGIN", new_y="NEXT")
        self.ln(2)
        self.set_text_color(30, 30, 30)

    def subsection(self, title):
        self.ln(2)
        self.set_font("Helvetica", "B", 11)
        self.set_text_color(70, 70, 70)
        self.cell(0, 7, title, new_x="LMARGIN", new_y="NEXT")
        self.ln(1)
        self.set_text_color(30, 30, 30)

    def body(self, text):
        self.set_font("Helvetica", "", 10)
        self.multi_cell(0, 5.5, text)
        self.ln(1)

    def bullet(self, text):
        self.set_font("Helvetica", "", 10)
        x = self.get_x()
        self.cell(6, 5.5, "-")
        self.multi_cell(0, 5.5, text)
        self.ln(0.5)

    def code_block(self, text):
        self.set_fill_color(240, 240, 245)
        self.set_font("Courier", "", 9)
        y_start = self.get_y()
        self.set_x(14)
        self.multi_cell(182, 5, text, fill=True)
        self.ln(2)
        self.set_font("Helvetica", "", 10)

    def key_value(self, key, value):
        self.set_font("Helvetica", "B", 10)
        self.cell(45, 5.5, f"  {key}:", new_x="END")
        self.set_font("Helvetica", "", 10)
        self.cell(0, 5.5, value, new_x="LMARGIN", new_y="NEXT")

    def file_ref(self, filename, desc):
        self.set_font("Courier", "", 9)
        self.set_text_color(0, 90, 180)
        self.cell(0, 5.5, f"  {filename}", new_x="LMARGIN", new_y="NEXT")
        self.set_font("Helvetica", "", 9)
        self.set_text_color(80, 80, 80)
        self.cell(0, 5.5, f"      {desc}", new_x="LMARGIN", new_y="NEXT")
        self.set_text_color(30, 30, 30)
        self.ln(1)

    def info_box(self, text):
        self.set_fill_color(230, 242, 255)
        self.set_draw_color(0, 120, 200)
        self.set_line_width(0.3)
        x, y = self.get_x(), self.get_y()
        self.set_font("Helvetica", "I", 10)
        self.set_x(14)
        self.multi_cell(182, 5.5, text, fill=True, border=1)
        self.ln(3)
        self.set_font("Helvetica", "", 10)

    def warn_box(self, text):
        self.set_fill_color(255, 248, 230)
        self.set_draw_color(200, 160, 0)
        self.set_line_width(0.3)
        self.set_font("Helvetica", "I", 10)
        self.set_x(14)
        self.multi_cell(182, 5.5, text, fill=True, border=1)
        self.ln(3)
        self.set_font("Helvetica", "", 10)

    def table_header(self, cols, widths):
        self.set_font("Helvetica", "B", 9)
        self.set_fill_color(230, 235, 245)
        for c, w in zip(cols, widths):
            self.cell(w, 7, c, border=1, fill=True, align="C")
        self.ln()

    def table_row(self, cols, widths):
        self.set_font("Helvetica", "", 9)
        max_h = 7
        for c, w in zip(cols, widths):
            self.cell(w, 7, c, border=1)
        self.ln()


def build():
    pdf = DocPDF()

    # ---- TITLE PAGE ----
    pdf.title_page()

    # ---- TABLE OF CONTENTS ----
    pdf.add_page()
    pdf.set_font("Helvetica", "B", 18)
    pdf.set_text_color(30, 30, 30)
    pdf.cell(0, 12, "Table of Contents", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(6)
    toc = [
        ("1", "System Overview"),
        ("2", "Architecture & Pipeline Diagram"),
        ("3", "Stage 1 - Audio-Visual Capture & Face Detection"),
        ("4", "Stage 2 - Active Speaker Detection (LAR + Differential Motion)"),
        ("5", "Stage 3 - Video-Guided Spectral Separation"),
        ("6", "Stage 4 - Speech Transcription (WhisperKit)"),
        ("7", "Stage 5 - Speaker Attribution (Word-to-Face Mapping)"),
        ("8", "Offline Analysis Lab (Analyze File Mode)"),
        ("9", "Current Limitations & Known Issues"),
        ("10", "Improvement Opportunities"),
        ("11", "Performance Evaluation & Comparison Ideas"),
        ("12", "Source File Reference"),
    ]
    for num, title in toc:
        pdf.set_font("Helvetica", "", 11)
        pdf.cell(12, 7, num + ".")
        pdf.cell(0, 7, title, new_x="LMARGIN", new_y="NEXT")

    # ============================================================
    # CHAPTER 1: SYSTEM OVERVIEW
    # ============================================================
    pdf.chapter_title("1", "System Overview")

    pdf.section("What is LiveCaption?")
    pdf.body(
        "LiveCaption is a macOS desktop application that provides real-time, speaker-attributed captioning "
        "from a single camera and microphone. It watches a video feed, detects who is talking by analyzing "
        "lip movements, and transcribes their speech using an on-device AI model (WhisperKit with CoreML). "
        "Each transcribed line is labeled with the speaker's identity (e.g., Speaker 1, Speaker 2), "
        "creating a full conversation transcript with speaker turns."
    )

    pdf.section("Key Features")
    pdf.bullet("Real-time face detection and landmark tracking (Apple Vision framework)")
    pdf.bullet("Active speaker detection via lip motion analysis (no audio diarization needed)")
    pdf.bullet("Cross-modal overlap detection: combines visual (lip) and audio (VAD) cues")
    pdf.bullet("Video-guided spectral separation for overlapping speech (STFT + harmonic masking)")
    pdf.bullet("On-device Indonesian speech transcription (WhisperKit, CoreML + Neural Engine)")
    pdf.bullet("Word-level speaker attribution using video timeline alignment")
    pdf.bullet("Offline analysis lab for evaluating separation quality on recorded files")
    pdf.bullet("Fully on-device processing - no cloud APIs, works offline after model download")

    pdf.section("Technology Stack")
    pdf.key_value("Platform", "macOS 14.0+ (Sonoma)")
    pdf.key_value("Language", "Swift 5.0 (SwiftUI + AppKit)")
    pdf.key_value("Build System", "XcodeGen (project.yml) + Xcode")
    pdf.key_value("Face Detection", "Apple Vision (VNDetectFaceLandmarksRequest Rev3)")
    pdf.key_value("Audio Capture", "AVFoundation (AVCaptureSession, shared video+audio)")
    pdf.key_value("Signal Processing", "Accelerate / vDSP (STFT, FFT, vector math)")
    pdf.key_value("Transcription", "WhisperKit 0.18.0 (CoreML + Neural Engine)")
    pdf.key_value("ASR Model", "openai_whisper-small (multilingual, Indonesian)")

    # ============================================================
    # CHAPTER 2: ARCHITECTURE
    # ============================================================
    pdf.chapter_title("2", "Architecture & Pipeline Diagram")

    pdf.section("End-to-End Pipeline")
    pdf.body(
        "The system processes data through five sequential stages, each building on the previous. "
        "The pipeline runs in two modes: Live (real-time from camera/mic) and Analyze File (offline "
        "on recorded video). The offline mode runs stages 1-5 in batch; the live mode currently "
        "runs stages 1-2 in real-time with stages 3-5 available in the analysis lab."
    )

    pdf.ln(2)
    pdf.set_font("Courier", "", 9)
    pipeline = (
        "PIPELINE FLOW:\n"
        "\n"
        "[Camera + Mic]                          (AVCaptureSession)\n"
        "      |\n"
        "      v\n"
        "[Face Landmark Detection]               (Apple Vision, Stage 1)\n"
        "      |\n"
        "      v\n"
        "[Lip Aperture Ratio + Differential      (LipGeometry +\n"
        " Motion -> Active Speaker Detection]     LipActivityDetector, Stage 2)\n"
        "      |                    |\n"
        "      v                    v\n"
        "[Audio VAD]          [Visual Overlap]\n"
        "      \\                  /\n"
        "       v                v\n"
        "      [Cross-Modal Fusion]              (2+ lips AND speech)\n"
        "            |\n"
        "            v\n"
        "[STFT -> Harmonic Comb Mask -> ISTFT]   (SpectralGate, Stage 3)\n"
        "            |\n"
        "            v\n"
        "[WhisperKit Transcription]              (CoreML, Stage 4)\n"
        "            |\n"
        "            v\n"
        "[Word -> Face Attribution]              (Attribution, Stage 5)\n"
        "            |\n"
        "            v\n"
        "[Speaker-Attributed Transcript]         (UI Output)\n"
    )
    pdf.code_block(pipeline)
    pdf.set_font("Helvetica", "", 10)

    pdf.section("Data Flow Summary")
    pdf.body(
        "1. AVCaptureSession delivers video frames and audio buffers simultaneously.\n"
        "2. Each video frame goes through Vision face landmark detection.\n"
        "3. Lip landmarks are analyzed for motion (differential: lip minus head movement).\n"
        "4. Audio is analyzed with an energy-based VAD (adaptive noise floor).\n"
        "5. Overlap = (2+ faces with active lips) AND (audio VAD detects speech).\n"
        "6. When overlap is detected, spectral masking isolates the target speaker's harmonics.\n"
        "7. The (optionally separated) audio is transcribed by WhisperKit.\n"
        "8. Each transcribed word is assigned to the dominant active face at that timestamp.\n"
        "9. Consecutive words from the same speaker merge into utterances."
    )

    # ============================================================
    # CHAPTER 3: STAGE 1
    # ============================================================
    pdf.chapter_title("3", "Stage 1 - Audio-Visual Capture & Face Detection")

    pdf.section("Purpose")
    pdf.body(
        "Capture synchronized video and audio from the device's camera and microphone, and detect "
        "faces with full landmark geometry in each video frame. This is the foundation that all "
        "later stages build upon."
    )

    pdf.section("How It Works")

    pdf.subsection("A. Unified AVCaptureSession")
    pdf.body(
        "A single AVCaptureSession handles both video and audio capture. This is a deliberate design "
        "choice - an earlier version used a separate AVAudioEngine for audio, but it failed to deliver "
        "buffers when an external/Continuity camera was connected (the camera hijacked the audio route). "
        "By using one session for both, audio always flows alongside video."
    )
    pdf.body(
        "The session runs on a dedicated serial queue (sessionQueue). Video frames are processed on "
        "videoQueue, audio buffers on audioQueue. Both share the same AVCaptureOutput delegate, with "
        "routing determined by checking which output produced the sample buffer."
    )

    pdf.subsection("B. Face Landmark Detection")
    pdf.body(
        "Each video frame (as a CVPixelBuffer) is passed to Apple Vision's VNDetectFaceLandmarksRequest "
        "(Revision 3) via a VNSequenceRequestHandler. This returns VNFaceObservation objects containing:"
    )
    pdf.bullet("Bounding box: normalized rectangle of the face in the image")
    pdf.bullet("68 facial landmarks grouped into regions: outerLips, innerLips, leftEye, rightEye, "
               "nose, noseCrest, leftEyebrow, rightEyebrow, faceContour, medianLine, pupils")
    pdf.bullet("All landmark points are normalized within the face bounding box (0-1 range)")

    pdf.body(
        "The detection runs synchronously on the video processing queue. Vision's Revision 3 is the "
        "most accurate landmark model available on macOS 14, running efficiently on the Neural Engine."
    )

    pdf.subsection("C. Camera Preview with Overlays")
    pdf.body(
        "CameraPreview wraps an AVCaptureVideoPreviewLayer in an NSView (via NSViewRepresentable for "
        "SwiftUI). On top, CAShapeLayer overlays draw face bounding boxes and landmark contours. "
        "Active speakers get green outlines (thick), inactive get gray (thin). Each face has a floating "
        "'S1 . 0.15' label showing the speaker ID and current LAR value.\n\n"
        "Important: preview mirroring is disabled so that Vision's coordinate space matches the "
        "on-screen display. Without this, face overlay boxes would appear flipped."
    )

    pdf.subsection("D. Audio Metrics")
    pdf.body(
        "AudioMetrics reads raw PCM data directly from CMSampleBuffer - it handles both Float32 and "
        "Int16 formats. For Float32, it uses vDSP_measqv (hardware-accelerated mean-square). This "
        "gives a single energy value per audio buffer that feeds the Voice Activity Detector."
    )

    pdf.section("Source Files")
    pdf.file_ref("CaptureManager.swift", "Unified session for video + audio, delegates, lifecycle")
    pdf.file_ref("FaceLandmarkProcessor.swift", "Wraps VNDetectFaceLandmarksRequest (Rev3)")
    pdf.file_ref("CameraPreview.swift", "NSViewRepresentable + overlay CAShapeLayers")
    pdf.file_ref("AudioMetrics.swift", "CMSampleBuffer -> mean-square energy (vDSP)")
    pdf.file_ref("LiveCaptionApp.swift", "App entry point, window configuration")
    pdf.file_ref("ContentView.swift", "Live/Analyze mode switch, owns CaptureManager")

    # ============================================================
    # CHAPTER 4: STAGE 2
    # ============================================================
    pdf.chapter_title("4", "Stage 2 - Active Speaker Detection")

    pdf.section("Purpose")
    pdf.body(
        "Determine which detected faces are actively speaking at any moment. This uses two independent "
        "signals - visual lip motion and audio energy - fused together to reduce false positives."
    )

    pdf.section("How It Works")

    pdf.subsection("A. Lip Aperture Ratio (LAR)")
    pdf.body(
        "For each detected face, the Lip Aperture Ratio is computed as:\n\n"
        "    LAR = vertical_extent(innerLips) / horizontal_extent(outerLips)\n\n"
        "This is the inner lip opening height divided by the mouth width. The ratio is:\n"
        "- Scale-invariant: computed in pixel space, so it works regardless of face distance\n"
        "- Near 0 when the mouth is closed\n"
        "- Rises toward 0.3-0.5 when speaking\n\n"
        "LAR is used for display only (the 'LAR' meter in the sidebar). The actual activity "
        "detection uses differential motion (described below) because LAR alone can't distinguish "
        "a static open mouth from active speech articulation."
    )

    pdf.subsection("B. Face Tracking (IoU-based)")
    pdf.body(
        "To maintain stable 'Speaker 1', 'Speaker 2' identities across frames, faces are tracked "
        "using Intersection-over-Union (IoU) matching between their bounding boxes:\n\n"
        "    IoU = area(intersection) / area(union)\n\n"
        "Each new frame's face observations are greedily matched to existing tracks (highest IoU first). "
        "A minimum IoU of 0.2 is required. Unmatched observations spawn new tracks with the next "
        "available ID. Tracks unseen for 0.5 seconds are dropped. This is simple but effective for "
        "faces that stay roughly in place (typical for video calls or seated conversations)."
    )

    pdf.subsection("C. Differential Motion (the Key Innovation)")
    pdf.body(
        "The activity signal is NOT simply 'how much the mouth moves.' That would trigger on head "
        "shaking, body movement, or any camera jitter. Instead, we measure:\n\n"
        "    activity = lip_landmark_displacement - reference_landmark_displacement\n\n"
        "Where:\n"
        "- Lip landmarks = outerLips + innerLips (the parts that move during speech)\n"
        "- Reference landmarks = leftEye + rightEye + nose + noseCrest (stable during speech)\n\n"
        "Both sets use normalized points (within the face bounding box), so head translation and "
        "scale changes are already canceled. The subtraction further cancels head rotation and jitter. "
        "What remains is pure mouth articulation."
    )
    pdf.body(
        "The motion is computed as mean Euclidean displacement between the current and previous "
        "frame's landmark positions, EMA-smoothed (factor 0.4). The net value (lip minus reference, "
        "clamped to >= 0) becomes the 'activity' signal."
    )

    pdf.subsection("D. Hysteresis + Hold Time")
    pdf.body(
        "To prevent the active/inactive flag from flickering between words (natural pauses in speech), "
        "two mechanisms are used:\n\n"
        "1. Hysteresis: Different thresholds for turning ON (0.008) vs turning OFF (0.005). The "
        "speaker must exceed the higher threshold to start 'speaking' but only needs to drop below "
        "the lower threshold to stop.\n\n"
        "2. Hold time: Once active, the flag stays on for at least 0.35 seconds even if motion stops. "
        "This bridges the brief pauses between syllables and words.\n\n"
        "Both values are tunable via the live sidebar sliders."
    )

    pdf.subsection("E. Voice Activity Detection (VAD)")
    pdf.body(
        "A separate energy-based VAD runs on the audio stream to answer: 'Is anyone speaking at all?' "
        "This operates independently of the visual system.\n\n"
        "The VAD computes energy in dB from each audio buffer's mean-square value, and maintains an "
        "adaptive noise floor:\n\n"
        "- Seeded from the first audio sample (not a fixed guess)\n"
        "- Falls toward quieter ambient at rate 0.05 (tracks silence quickly)\n"
        "- Rises toward louder ambient at rate 0.005 (creeps up slowly)\n"
        "- Both directions always adapt (no speech gate - this prevents a deadlock where a false "
        "trigger freezes the floor)\n"
        "- Clamped to [-80, -20] dB\n\n"
        "Speech is detected when energy exceeds noise floor by onMarginDB (default 6 dB), with "
        "hysteresis (offMargin 3 dB) and 0.30s hangover."
    )

    pdf.subsection("F. Cross-Modal Overlap Fusion")
    pdf.body(
        "The final overlap decision combines both modalities:\n\n"
        "    overlapDetected = (2+ faces lip-active) AND (audio VAD says speech)\n\n"
        "This means overlap requires BOTH visual evidence (multiple mouths moving) and audio evidence "
        "(sound actually present). This dramatically reduces false positives compared to using either "
        "signal alone - body movement without sound won't trigger, and ambient noise without lip "
        "motion won't trigger."
    )
    pdf.info_box(
        "Design Decision: We deliberately chose NOT to add acoustic speaker diarization (like "
        "pyannote). Faces already provide speaker identity for free. Adding an audio diarization "
        "model would add seconds of latency and computational cost for redundant information. "
        "Audio diarization would only help for off-screen speakers (no face visible), which is "
        "out of scope for this camera-based system."
    )

    pdf.section("Tunable Parameters")
    pdf.table_header(["Parameter", "Default", "Range", "Effect"], [45, 25, 30, 90])
    pdf.table_row(["Talk threshold", "0.008", "0.002-0.030", "Activity level to start speaking"], [45, 25, 30, 90])
    pdf.table_row(["Hold time", "0.35s", "0.1-1.0s", "Keep active after motion stops"], [45, 25, 30, 90])
    pdf.table_row(["Speech margin", "6 dB", "2-15 dB", "dB above noise floor for VAD"], [45, 25, 30, 90])
    pdf.table_row(["EMA smoothing", "0.4", "fixed", "Smoothing factor for LAR + activity"], [45, 25, 30, 90])
    pdf.table_row(["IoU threshold", "0.2", "fixed", "Min overlap to keep same speaker ID"], [45, 25, 30, 90])

    pdf.section("Source Files")
    pdf.file_ref("LipGeometry.swift", "LAR computation from inner/outer lip landmarks")
    pdf.file_ref("LipActivityDetector.swift", "Face tracking, differential motion, hysteresis")
    pdf.file_ref("VoiceActivityDetector.swift", "Energy VAD with adaptive noise floor")
    pdf.file_ref("AudioMetrics.swift", "CMSampleBuffer -> mean-square energy")

    # ============================================================
    # CHAPTER 5: STAGE 3
    # ============================================================
    pdf.chapter_title("5", "Stage 3 - Video-Guided Spectral Separation")

    pdf.section("Purpose")
    pdf.body(
        "When two or more speakers talk simultaneously (overlap), attempt to isolate a target "
        "speaker's voice using their pitch profile. The video timeline tells us WHEN overlap occurs "
        "and WHO is speaking; the audio processing removes frequency components that don't match "
        "the target speaker."
    )

    pdf.section("How It Works")

    pdf.subsection("A. Short-Time Fourier Transform (STFT)")
    pdf.body(
        "The STFT converts a time-domain audio signal into a time-frequency representation:\n\n"
        "Parameters:\n"
        "  - FFT size: 1024 samples (64ms at 16kHz)\n"
        "  - Hop size: 256 samples (16ms) = 75% overlap between frames\n"
        "  - Window: sqrt-Hann (both analysis and synthesis)\n\n"
        "Each frame is windowed, then transformed using vDSP_fft_zip (full complex FFT). This "
        "produces a Spectrogram with real and imaginary components per frequency bin per time frame.\n\n"
        "The inverse STFT (ISTFT) reconstructs the time-domain signal via overlap-add: each frame "
        "is inverse-FFT'd, scaled by 1/N, multiplied by the synthesis window, and added into the "
        "output buffer. A normalization array tracks the accumulated window product per sample to "
        "ensure perfect reconstruction.\n\n"
        "Round-trip accuracy (STFT -> ISTFT with no modification): maximum error 2.4e-7, "
        "essentially perfect reconstruction."
    )

    pdf.subsection("B. Pitch Estimation (F0)")
    pdf.body(
        "Each speaker's fundamental frequency (F0) is estimated from their SOLO speech segments "
        "(times when only they are speaking, identified from the video timeline).\n\n"
        "Algorithm: Normalized Autocorrelation\n"
        "1. Process 1024-sample frames with 512-sample hop\n"
        "2. For each frame, compute normalized cross-correlation at lags corresponding to 75-350 Hz\n"
        "3. Find the lag with highest correlation (voicing clarity)\n"
        "4. Use smallest lag near global maximum (avoids octave-down errors)\n"
        "5. Only accept frames with voicing clarity > 0.5\n"
        "6. Return median F0 across all voiced frames\n\n"
        "The result is a single F0 estimate per speaker (e.g., 'Speaker 1: 135 Hz, Speaker 2: 225 Hz')."
    )

    pdf.subsection("C. Harmonic Comb Masking")
    pdf.body(
        "During overlap, a spectral mask is applied that keeps frequency bins near the target "
        "speaker's harmonics and attenuates everything else:\n\n"
        "For each frequency bin k:\n"
        "  freq = k * sampleRate / fftSize\n"
        "  nearestHarmonic = round(freq / F0) * F0\n"
        "  distance = |freq - nearestHarmonic|\n"
        "  gain = floor + (1 - floor) * exp(-distance^2 / (2 * sigma^2))\n\n"
        "Where:\n"
        "  - floor = 0.08 (minimum gain, prevents total silence)\n"
        "  - sigma = max(20, 0.18 * F0) Hz (Gaussian width, allows for pitch drift)\n\n"
        "The mask is applied symmetrically (mirror at Nyquist) to keep the output real-valued. "
        "The real and imaginary parts of each STFT frame are multiplied by the same mask."
    )

    pdf.subsection("D. Three-Way Gating Logic")
    pdf.body(
        "For each STFT frame, the video timeline determines the action:\n\n"
        "1. TARGET NOT ACTIVE: Multiply all bins by 0 (silence). The target isn't speaking, so "
        "remove everything - it's another speaker's solo.\n\n"
        "2. TARGET SOLO: Keep frame untouched. Only the target is speaking, so no separation needed.\n\n"
        "3. OVERLAP (or 'always mask' mode): Apply the harmonic comb mask. Keep the target's "
        "pitch harmonics, attenuate the rest."
    )

    pdf.warn_box(
        "Known Limitation: Harmonic masking is a classical DSP approach with inherent limitations. "
        "It cannot separate speakers with similar pitches (e.g., two males at 130/135 Hz). It "
        "damages unvoiced consonants (s, sh, f, t) which have no harmonic structure. It may "
        "introduce musical noise artifacts. This is a demonstrator - production quality would "
        "require a neural separation model like Conv-TasNet."
    )

    pdf.section("Source Files")
    pdf.file_ref("STFTProcessor.swift", "Full-complex STFT/ISTFT via vDSP, sqrt-Hann windows")
    pdf.file_ref("PitchEstimator.swift", "Normalized autocorrelation F0 estimation")
    pdf.file_ref("SpectralGate.swift", "Harmonic comb mask, 3-way gating logic")
    pdf.file_ref("SpectrogramView.swift", "Log-magnitude spectrogram rendering to NSImage")
    pdf.file_ref("MediaLoader.swift", "AVAssetReader -> 16kHz mono Float32 audio")
    pdf.file_ref("AudioPlayer.swift", "Temp .caf file + AVAudioPlayer for A/B playback")

    # ============================================================
    # CHAPTER 6: STAGE 4
    # ============================================================
    pdf.chapter_title("6", "Stage 4 - Speech Transcription (WhisperKit)")

    pdf.section("Purpose")
    pdf.body(
        "Convert the audio signal into text using an on-device speech recognition model, with "
        "word-level timestamps that enable speaker attribution in the next stage."
    )

    pdf.section("How It Works")

    pdf.subsection("A. WhisperKit Integration")
    pdf.body(
        "WhisperKit is an open-source Swift framework that runs OpenAI's Whisper models natively "
        "on Apple Silicon using CoreML and the Neural Engine. The integration:\n\n"
        "- Added as an SPM dependency (pinned to >= 0.9.0, < 1.0.0 to avoid v1.0.0 API changes)\n"
        "- Resolved version: 0.18.0\n"
        "- Model: openai_whisper-small (multilingual, 244M parameters)\n"
        "- Language: forced to Indonesian ('id') via DecodingOptions\n"
        "- Word timestamps: enabled for per-word timing\n\n"
        "On first use, the CoreML model is downloaded from HuggingFace (~500MB). Subsequent runs "
        "use the cached model. The app is not sandboxed, so network access works without entitlements."
    )

    pdf.subsection("B. Transcription Pipeline")
    pdf.body(
        "1. Audio is provided as [Float] at 16kHz mono (from MediaLoader)\n"
        "2. WhisperKit.transcribe(audioArray:decodeOptions:) runs the full encoder-decoder pipeline\n"
        "3. Results include segments (sentences) and words (individual tokens with timestamps)\n"
        "4. Special tokens (<|startoftranscript|>, <|id|>, <|3.20|>) are stripped via regex\n"
        "5. Empty segments/words after cleaning are filtered out\n"
        "6. Output: [TranscriptSegment] each containing [TranscriptWord] with start/end times"
    )

    pdf.subsection("C. Token Cleaning")
    pdf.body(
        "Whisper's raw output includes special tokens in the text that are not meant for display:\n\n"
        "  <|startoftranscript|> <|id|> <|notimestamps|> <|3.20|>\n\n"
        "These are stripped using the regex pattern: <\\|[^|]*\\|>\n"
        "This removes any <|...|> token, leaving only the actual transcribed text."
    )

    pdf.subsection("D. Model Selection")
    pdf.body(
        "The system was tested with two Whisper model sizes:\n\n"
        "whisper-base (74M parameters): Fast but poor Indonesian accuracy. Many hallucinations "
        "and incorrect words.\n\n"
        "whisper-small (244M parameters): Much better Indonesian transcription. Currently the "
        "default. Good balance of speed and accuracy for on-device use.\n\n"
        "For production use, a fine-tuned Indonesian model (e.g., whisper-small-id trained on "
        "Indonesian speech data, converted to CoreML via whisperkittools) would significantly "
        "improve accuracy."
    )

    pdf.section("Source Files")
    pdf.file_ref("Transcriber.swift", "WhisperKit wrapper, model loading, token cleanup")
    pdf.file_ref("project.yml", "WhisperKit SPM dependency declaration")

    # ============================================================
    # CHAPTER 7: STAGE 5
    # ============================================================
    pdf.chapter_title("7", "Stage 5 - Speaker Attribution")

    pdf.section("Purpose")
    pdf.body(
        "Assign each transcribed word to the face that was most actively speaking at that moment, "
        "then merge consecutive same-speaker words into utterances. This is the final step that "
        "produces the speaker-attributed transcript."
    )

    pdf.section("How It Works")

    pdf.subsection("A. Word-to-Face Mapping")
    pdf.body(
        "For each transcribed word (with its start/end timestamps from WhisperKit):\n\n"
        "1. Compute the word's midpoint: mid = (word.start + word.end) / 2\n"
        "2. Look up the video timeline at that moment: timeline.dominantSpeaker(at: mid)\n"
        "3. dominantSpeaker finds the nearest video frame, filters for faces with activity above "
        "the threshold, and returns the face ID with the highest activity value (argmax)\n"
        "4. If no face is active above threshold, the word is attributed to 'unknown' (?)\n\n"
        "This approach works because WhisperKit provides word-level timestamps, and the video "
        "timeline records per-frame per-face activity values. By looking up the most-active face "
        "at each word's midpoint, we get a natural speaker assignment."
    )

    pdf.subsection("B. Utterance Merging")
    pdf.body(
        "After individual word attribution, consecutive words assigned to the same speaker are "
        "merged into utterances:\n\n"
        "  Word: 'Ini'    -> Speaker 1 (3.9s)\n"
        "  Word: 'adalah' -> Speaker 1 (4.1s)  -> merged\n"
        "  Word: 'contoh' -> Speaker 1 (4.3s)  -> merged\n"
        "  Word: 'Itu'    -> Speaker 2 (5.0s)  -> new utterance\n\n"
        "Result:\n"
        "  [Speaker 1] 'Ini adalah contoh' (3.9 - 4.5s)\n"
        "  [Speaker 2] 'Itu ...' (5.0s - ...)\n\n"
        "Each AttributedUtterance stores: speaker ID, merged text, start time, and end time."
    )

    pdf.subsection("C. Attribution Accuracy")
    pdf.body(
        "The accuracy of speaker attribution is bounded by:\n\n"
        "1. Video active-speaker detection quality: If the lip motion detector wrongly flags a "
        "face as active or misses the true speaker, the word will be misattributed.\n\n"
        "2. WhisperKit word timestamp accuracy: Whisper's word boundaries are approximate "
        "(typically within ~200ms). For fast speaker turns, this may misalign.\n\n"
        "3. Overlap sensitivity threshold: The same slider controls both overlap detection and "
        "attribution. A lower threshold means more faces qualify as 'active', making it harder "
        "to pick the dominant one.\n\n"
        "In practice, attribution works well for clear turn-taking conversations and degrades "
        "during fast back-and-forth or genuine overlapping speech."
    )

    pdf.section("Source Files")
    pdf.file_ref("Attribution.swift", "Word -> face mapping + utterance merging")
    pdf.file_ref("VideoAnalyzer.swift", "Timeline.dominantSpeaker(at:threshold:)")

    # ============================================================
    # CHAPTER 8: ANALYSIS LAB
    # ============================================================
    pdf.chapter_title("8", "Offline Analysis Lab (Analyze File Mode)")

    pdf.section("Purpose")
    pdf.body(
        "The analysis lab runs the full pipeline offline on a recorded video file, letting you "
        "evaluate each stage's output, tune parameters, and compare before/after spectral separation. "
        "This is essential for development and debugging since real-time evaluation of spectral "
        "quality is impractical."
    )

    pdf.section("Features")
    pdf.bullet("File import: Load any .mov, .mp4, or audio file via the system file picker")
    pdf.bullet("Video analysis: Runs face detection + lip activity on every video frame with progress %")
    pdf.bullet("Speaker cards: Face thumbnail, speaker ID, and estimated F0 per detected speaker")
    pdf.bullet("Overlap sensitivity slider: Re-derives the active/overlap timeline instantly (no re-decode)")
    pdf.bullet("'Mask whenever active' toggle: Forces harmonic masking even outside overlap regions")
    pdf.bullet("Close-pitch warning: Alerts when two speakers have F0 within 20 Hz (unseparable)")
    pdf.bullet("Before/after spectrograms: Original vs. separated, log-magnitude heatmap")
    pdf.bullet("A/B playback: Play original or separated audio (via temp .caf + AVAudioPlayer)")
    pdf.bullet("Transcription: WhisperKit transcribe button with model loading status")
    pdf.bullet("Speaker-attributed transcript: Colored 'Speaker N' chips per utterance line")

    pdf.section("Workflow")
    pdf.body(
        "1. Switch to 'Analyze File' tab (camera stops automatically)\n"
        "2. Click 'Load video...' and select a recording\n"
        "3. Wait for audio extraction and video analysis (progress bar shows %)\n"
        "4. Review speaker cards - check that faces are detected and F0 estimates look reasonable\n"
        "5. Adjust overlap sensitivity slider - watch the 'overlap Xs' readout change\n"
        "6. Select a target speaker to separate\n"
        "7. Compare original and separated spectrograms visually\n"
        "8. Use A/B playback to listen to the difference\n"
        "9. Click 'Transcribe' to run WhisperKit and see the speaker-attributed transcript"
    )

    pdf.section("Source Files")
    pdf.file_ref("AnalysisView.swift", "Full analysis UI + AnalysisViewModel orchestration")
    pdf.file_ref("VideoAnalyzer.swift", "Offline video -> Timeline (raw per-frame activity)")
    pdf.file_ref("ContentView.swift", "Live/Analyze mode switch, camera lifecycle")

    # ============================================================
    # CHAPTER 9: LIMITATIONS
    # ============================================================
    pdf.chapter_title("9", "Current Limitations & Known Issues")

    pdf.section("Spectral Separation Quality")
    pdf.bullet("Cannot separate speakers with similar F0 (e.g., two males at 130/135 Hz). "
               "Harmonic comb masking fundamentally requires distinct pitches.")
    pdf.bullet("Damages unvoiced consonants (s, sh, f, t, k) because they have no harmonic "
               "structure - the comb mask attenuates them as 'non-target'.")
    pdf.bullet("May introduce musical noise artifacts at mask boundaries.")
    pdf.bullet("Only works for voiced speech segments - whispered or breathy speech has no "
               "clear harmonics to target.")

    pdf.section("Single Microphone Limitation")
    pdf.bullet("With one microphone, audio energy cannot be attributed to a specific face. "
               "If two people both move their lips while audio is present, both read as active.")
    pdf.bullet("Cross-modal fusion reduces this (requires BOTH lip motion AND audio), but "
               "cannot fully resolve who produced which sound from a single channel.")

    pdf.section("Active Speaker Detection")
    pdf.bullet("Requires faces to be visible and roughly front-facing. Profile views or "
               "occluded faces may not be detected by Vision.")
    pdf.bullet("Rapid head movement can briefly confuse the differential motion measure, "
               "though the reference-landmark subtraction handles most cases.")
    pdf.bullet("The IoU face tracker is simple - it can lose identity if faces cross paths "
               "or temporarily leave the frame.")

    pdf.section("Transcription")
    pdf.bullet("Using stock openai_whisper-small, not fine-tuned for Indonesian. Accuracy "
               "is good but not production-grade for specialized vocabulary.")
    pdf.bullet("First transcription requires downloading the CoreML model (~500MB). Needs "
               "network connectivity.")
    pdf.bullet("Transcription + attribution currently only works in offline (Analyze File) "
               "mode. Live real-time transcription is not yet implemented.")

    pdf.section("Platform")
    pdf.bullet("macOS only (14.0+). Uses AVCaptureSession APIs not available on iOS in the "
               "same form.")
    pdf.bullet("Not sandboxed - suitable for development but needs entitlements for App Store.")
    pdf.bullet("No code signing (identity '-') - for local development only.")

    # ============================================================
    # CHAPTER 10: IMPROVEMENTS
    # ============================================================
    pdf.chapter_title("10", "Improvement Opportunities")

    pdf.section("High Impact")

    pdf.subsection("1. Neural Source Separation (Conv-TasNet / SepFormer)")
    pdf.body(
        "Replace harmonic comb masking with a learned neural separation model. Conv-TasNet or "
        "SepFormer can separate overlapping speakers regardless of pitch similarity, handling "
        "unvoiced consonants and same-gender speakers. The model would be converted to CoreML "
        "for on-device inference.\n\n"
        "Effort: High (model training/conversion, CoreML optimization)\n"
        "Impact: Dramatically better separation quality - the single biggest improvement possible."
    )

    pdf.subsection("2. Fine-Tuned Indonesian Whisper Model")
    pdf.body(
        "Fine-tune whisper-small (or whisper-medium) on Indonesian speech data, then convert to "
        "CoreML using the whisperkittools Python package. This would improve transcription accuracy "
        "significantly, especially for Indonesian-specific vocabulary, names, and colloquialisms.\n\n"
        "Effort: Medium (dataset collection + fine-tuning + CoreML conversion)\n"
        "Impact: Much better transcription accuracy for the target language."
    )

    pdf.subsection("3. Live Real-Time Transcription + Attribution")
    pdf.body(
        "Bring WhisperKit streaming transcription into the live mode. Buffer audio in sliding "
        "windows (e.g., 5-second chunks with 1-second overlap), transcribe incrementally, and "
        "attribute each word to the currently active face in real-time.\n\n"
        "Effort: Medium (buffering logic, incremental updates, UI streaming)\n"
        "Impact: Completes the live pipeline vision - real-time speaker-attributed captions."
    )

    pdf.section("Medium Impact")

    pdf.subsection("4. SpeakerKit Diarization (Off-Screen Speakers)")
    pdf.body(
        "Integrate Argmax's SpeakerKit (now in argmax-oss-swift v1.0.0) for audio-based speaker "
        "diarization. This would handle speakers who are off-camera or whose faces are not detected. "
        "The visual and audio identities could be fused for robust speaker tracking.\n\n"
        "Effort: Medium\n"
        "Impact: Handles off-screen speakers; more robust speaker identification."
    )

    pdf.subsection("5. Audio-Visual Lip Sync Correlation")
    pdf.body(
        "Compute per-face correlation between lip motion timing and audio energy/onset patterns. "
        "This would tell you which face is actually producing the heard audio, solving the "
        "ambiguity when multiple faces move their lips during the same audio.\n\n"
        "Effort: Medium (signal processing + correlation analysis)\n"
        "Impact: More accurate active-speaker detection in multi-speaker scenes."
    )

    pdf.subsection("6. Improved Face Tracking")
    pdf.body(
        "Replace IoU-based tracking with a more robust multi-object tracker (e.g., Deep SORT "
        "with face embeddings, or Apple's VNTrackObjectRequest). This would maintain identity "
        "through temporary occlusions, face crossings, and frame exits/re-entries.\n\n"
        "Effort: Medium\n"
        "Impact: More stable Speaker IDs across longer recordings."
    )

    pdf.section("Lower Effort / Nice to Have")

    pdf.subsection("7. Larger Whisper Models")
    pdf.body(
        "Switch from whisper-small to whisper-medium or whisper-large for better accuracy. "
        "Trade-off is inference speed and memory. Test on your hardware to find the sweet spot.\n\n"
        "Effort: Low (just change the model name)\n"
        "Impact: Better transcription, slower inference."
    )

    pdf.subsection("8. Confidence-Based Attribution")
    pdf.body(
        "Instead of hard argmax attribution (assign to the single most-active face), use a "
        "confidence score. When the top two faces have similar activity levels, mark the word "
        "as 'uncertain' rather than guessing. Show confidence in the UI.\n\n"
        "Effort: Low\n"
        "Impact: More honest/transparent attribution."
    )

    pdf.subsection("9. Export Functionality")
    pdf.body(
        "Add export options: SRT/VTT subtitle files, plain text transcript, CSV with timestamps "
        "and speakers, or separated audio WAV files. Useful for downstream processing.\n\n"
        "Effort: Low\n"
        "Impact: Practical utility for end users."
    )

    # ============================================================
    # CHAPTER 11: EVALUATION
    # ============================================================
    pdf.chapter_title("11", "Performance Evaluation & Comparison Ideas")

    pdf.section("What to Measure")
    pdf.body(
        "To evaluate and improve the system, you need ground truth annotations and quantitative "
        "metrics. Here are practical approaches for each stage:"
    )

    pdf.subsection("A. Active Speaker Detection Accuracy")
    pdf.body(
        "Ground truth: Manually annotate a test video with who is speaking at each moment "
        "(per-frame or per-100ms labels).\n\n"
        "Metrics:\n"
        "- Frame-level accuracy: % of frames where the active/inactive prediction matches ground truth\n"
        "- Precision: Of frames predicted 'active', how many are truly active?\n"
        "- Recall: Of truly active frames, how many are detected?\n"
        "- F1 score: Harmonic mean of precision and recall\n"
        "- Overlap detection rate: What % of true overlap segments are correctly detected?\n\n"
        "Comparison:\n"
        "- Compare LAR-only detection vs. differential motion detection\n"
        "- Compare visual-only overlap vs. cross-modal (visual + audio VAD) fusion\n"
        "- Sweep threshold values and plot precision-recall curves"
    )

    pdf.subsection("B. Spectral Separation Quality")
    pdf.body(
        "Ground truth: Record each speaker separately (isolated channels), then mix them. "
        "The individual recordings are the ground truth for separation.\n\n"
        "Metrics:\n"
        "- SDR (Signal-to-Distortion Ratio): Overall separation quality in dB\n"
        "- SIR (Signal-to-Interference Ratio): How well the other speaker is suppressed\n"
        "- SAR (Signal-to-Artifacts Ratio): How much artifact (musical noise) is introduced\n"
        "- PESQ/POLQA: Perceptual speech quality measures\n\n"
        "You can compute SDR/SIR/SAR using the Python library 'mir_eval' or 'museval':\n"
    )
    pdf.code_block(
        "# Python example with mir_eval\n"
        "import mir_eval\n"
        "sdr, sir, sar, _ = mir_eval.separation.bss_eval_sources(\n"
        "    reference_sources,  # [2, num_samples] ground truth\n"
        "    estimated_sources   # [2, num_samples] your separation output\n"
        ")"
    )
    pdf.body(
        "Comparison:\n"
        "- Harmonic comb masking (current) vs. no separation (baseline)\n"
        "- Harmonic comb masking vs. neural separation (Conv-TasNet, if implemented)\n"
        "- Different F0 estimation methods\n"
        "- Different mask floor values (0.05, 0.08, 0.15)\n"
        "- Different Gaussian sigma widths"
    )

    pdf.subsection("C. Transcription Accuracy")
    pdf.body(
        "Ground truth: Human transcription of the test audio.\n\n"
        "Metrics:\n"
        "- WER (Word Error Rate): (substitutions + insertions + deletions) / total reference words\n"
        "- CER (Character Error Rate): Same formula at character level (better for Indonesian)\n\n"
        "You can compute WER using the Python library 'jiwer':\n"
    )
    pdf.code_block(
        "# Python example with jiwer\n"
        "from jiwer import wer, cer\n"
        "reference = 'ini adalah contoh kalimat'\n"
        "hypothesis = 'ini dalah contoh kalimat'\n"
        "print(f'WER: {wer(reference, hypothesis):.2%}')\n"
        "print(f'CER: {cer(reference, hypothesis):.2%}')"
    )
    pdf.body(
        "Comparison:\n"
        "- whisper-base vs. whisper-small vs. whisper-medium (accuracy vs. speed trade-off)\n"
        "- Stock model vs. fine-tuned Indonesian model\n"
        "- Original audio vs. separated audio (does separation improve or hurt transcription?)\n"
        "- Clean speech vs. overlapping speech (where does the model struggle?)"
    )

    pdf.subsection("D. Speaker Attribution Accuracy")
    pdf.body(
        "Ground truth: Manually label which speaker said each word/utterance.\n\n"
        "Metrics:\n"
        "- DER (Diarization Error Rate): Standard metric for speaker diarization\n"
        "  DER = (missed speech + false alarm + speaker confusion) / total speech duration\n"
        "- Word-level speaker accuracy: % of words attributed to the correct speaker\n"
        "- Utterance-level speaker accuracy: % of utterances with correct speaker label\n\n"
        "Comparison:\n"
        "- Video-only attribution (current) vs. audio diarization (e.g., SpeakerKit)\n"
        "- Different overlap sensitivity thresholds\n"
        "- Different attribution strategies (argmax vs. weighted vs. time-window voting)"
    )

    pdf.subsection("E. End-to-End Benchmark")
    pdf.body(
        "The most meaningful evaluation is end-to-end: given a test video with multiple speakers, "
        "how well does the system produce a correct speaker-attributed transcript?\n\n"
        "Suggested test set:\n"
        "1. Two speakers with distinct pitches, clear turn-taking\n"
        "2. Two speakers with similar pitches, clear turn-taking\n"
        "3. Two speakers with some overlapping speech\n"
        "4. Three or more speakers\n"
        "5. Varying recording conditions (quiet room, noisy environment)\n\n"
        "For each clip, measure WER per speaker and overall DER."
    )

    pdf.section("Practical Comparison Table")
    pdf.body("Here is a template for comparing different configurations:")
    pdf.ln(2)
    w = [45, 25, 25, 25, 25, 25]
    pdf.table_header(["Configuration", "WER (%)", "DER (%)", "SDR (dB)", "Latency", "Notes"], w)
    pdf.table_row(["whisper-base, no sep.", "", "", "N/A", "", "Baseline"], w)
    pdf.table_row(["whisper-small, no sep.", "", "", "N/A", "", "Current"], w)
    pdf.table_row(["whisper-small + comb", "", "", "", "", "Current"], w)
    pdf.table_row(["whisper-small + neural", "", "", "", "", "Future"], w)
    pdf.table_row(["whisper-medium, no sep.", "", "", "N/A", "", "Larger model"], w)
    pdf.table_row(["fine-tuned ID, no sep.", "", "", "N/A", "", "Future"], w)
    pdf.body("\n(Fill in with your test results)")

    # ============================================================
    # CHAPTER 12: FILE REFERENCE
    # ============================================================
    pdf.chapter_title("12", "Source File Reference")

    pdf.section("Application Core")
    pdf.file_ref("LiveCaptionApp.swift", "@main entry point, WindowGroup (min 760x560)")
    pdf.file_ref("ContentView.swift", "Live/Analyze tab switch, CaptureManager lifecycle")
    pdf.file_ref("project.yml", "XcodeGen spec: targets, dependencies, build settings")

    pdf.section("Stage 1: Capture & Detection")
    pdf.file_ref("CaptureManager.swift", "AVCaptureSession (video+audio), delegates, cross-modal fusion")
    pdf.file_ref("FaceLandmarkProcessor.swift", "VNDetectFaceLandmarksRequest Rev3 wrapper")
    pdf.file_ref("CameraPreview.swift", "NSViewRepresentable, overlay rendering (CAShapeLayer)")
    pdf.file_ref("AudioMetrics.swift", "CMSampleBuffer -> mean-square (Float32/Int16, vDSP)")

    pdf.section("Stage 2: Active Speaker Detection")
    pdf.file_ref("LipGeometry.swift", "LAR = inner vertical / outer horizontal (scale-invariant)")
    pdf.file_ref("LipActivityDetector.swift", "IoU tracking, differential motion, hysteresis, hold time")
    pdf.file_ref("VoiceActivityDetector.swift", "Energy VAD, adaptive noise floor, hangover")

    pdf.section("Stage 3: Spectral Separation")
    pdf.file_ref("STFTProcessor.swift", "vDSP full-complex FFT, sqrt-Hann, overlap-add inverse")
    pdf.file_ref("PitchEstimator.swift", "Normalized autocorrelation, octave-bias, median F0")
    pdf.file_ref("SpectralGate.swift", "Gaussian harmonic comb mask, 3-way gating")
    pdf.file_ref("SpectrogramView.swift", "Log-magnitude heatmap (black-purple-orange-yellow)")
    pdf.file_ref("MediaLoader.swift", "AVAssetReader -> 16kHz mono Float32")
    pdf.file_ref("AudioPlayer.swift", "Temp .caf + AVAudioPlayer for playback")

    pdf.section("Stage 4: Transcription")
    pdf.file_ref("Transcriber.swift", "WhisperKit wrapper, DecodingOptions, token cleanup regex")

    pdf.section("Stage 5: Attribution")
    pdf.file_ref("Attribution.swift", "Word midpoint -> dominantSpeaker, utterance merging")

    pdf.section("Offline Analysis")
    pdf.file_ref("VideoAnalyzer.swift", "Batch video -> Timeline (raw per-frame activity, thumbnails)")
    pdf.file_ref("AnalysisView.swift", "Full analysis lab UI + AnalysisViewModel")

    # ---- OUTPUT ----
    out = "/Users/virafitriyani/Documents/AIML Institute/Challenge 1 - Audio/auto-captioning/LiveCaption_Documentation.pdf"
    pdf.output(out)
    print(f"PDF saved to: {out}")
    return out


if __name__ == "__main__":
    build()
