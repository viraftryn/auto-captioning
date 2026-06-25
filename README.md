# LiveCaption

Live, speaker-attributed captioning on macOS from a single camera + microphone.
Built with SwiftUI, AVFoundation, Apple Vision, and (later) WhisperKit.

The app is being built **one pipeline stage at a time**:

| Stage | What it does | Status |
|------:|--------------|--------|
| **1** | Camera + audio capture, Vision face-landmark overlay | ✅ in progress |
| 2 | Lip Aperture Ratio (LAR) → active-speaker / overlap detection | ⬜ |
| 3 | Video-guided spectral gating (STFT → mask → ISTFT, vDSP) | ⬜ |
| 4 | WhisperKit (CoreML) transcription, fine-tuned Indonesian model | ⬜ |
| 5 | Word → face attribution + sidebar transcript UI | ⬜ |

## Stage 1 — what you should see

Camera preview with **green landmark contours** (face, eyes, brows, nose, lips)
and a **yellow face box**, a live **FPS / face-count** badge, **camera + mic**
permission indicators, and a **microphone level meter**. Press **Space** (or the
button) to start/stop.

## Requirements

- macOS 14+ and a recent full Xcode (not just Command Line Tools)
- [XcodeGen](https://github.com/yonsei/XcodeGen): `brew install xcodegen`

## Build & run

```bash
# 1. Generate the Xcode project from project.yml
xcodegen generate

# 2a. Open in Xcode and press Run
open LiveCaption.xcodeproj

# 2b. …or build from the command line
#     (this machine's `xcode-select` points at CLT, so point at full Xcode)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project LiveCaption.xcodeproj -scheme LiveCaption -configuration Debug build
```

On first launch macOS will prompt for **Camera** and **Microphone** access.
If you deny by accident, re-enable under
**System Settings ▸ Privacy & Security ▸ Camera / Microphone**.

## Project layout

```
project.yml                     XcodeGen spec (source of truth for the .xcodeproj)
LiveCaption/
  LiveCaptionApp.swift          @main App entry point
  ContentView.swift             SwiftUI UI: preview, controls, meters
  CameraPreview.swift           AVCaptureVideoPreviewLayer + landmark overlay
  CaptureManager.swift          AVCaptureSession + AudioEngine orchestration
  AudioEngine.swift             Mic capture → 16 kHz mono (Whisper-ready)
  FaceLandmarkProcessor.swift   Vision VNDetectFaceLandmarksRequest wrapper
```

> The `.xcodeproj` is generated and git-ignored — run `xcodegen generate`
> after pulling or after adding/removing source files.
