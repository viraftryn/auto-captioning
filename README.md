# LiveCaption

Live, speaker-attributed captioning on macOS from a single camera + microphone.
Built with SwiftUI, AVFoundation, Apple Vision, and (later) WhisperKit.

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

> The `.xcodeproj` is generated and git-ignored — run `xcodegen generate`
> after pulling or after adding/removing source files.
