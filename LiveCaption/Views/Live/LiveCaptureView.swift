import SwiftUI

struct LiveCaptureView: View {
    @ObservedObject var capture: CaptureManager

    @State private var talkThreshold: Double = 0.008
    @State private var holdTime: Double = 0.35
    @State private var speechMargin: Double = 6

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    CameraPreview(session: capture.session, faces: capture.trackedFaces)
                        .frame(minWidth: 560, minHeight: 300)
                    topOverlay.padding(12)
                }
                Divider()
                LiveTranscriptView(engine: capture.live)
                    .frame(height: 200)
                controlBar
            }
            Divider()
            speakerSidebar.frame(width: 250)
        }
        .onAppear {
            pushConfig()
            capture.setSpeechMargin(Float(speechMargin))
        }
    }

    private func pushConfig() {
        var config = LipActivityConfig()
        config.activityOn = talkThreshold
        config.activityOff = talkThreshold * 0.6
        config.holdTime = holdTime
        capture.setConfig(config)
    }

    // MARK: - Preview overlay (badge + overlap banner)

    private var topOverlay: some View {
        VStack(spacing: 8) {
            HStack { infoBadge; Spacer() }
            if capture.overlapDetected {
                Label("OVERLAP · \(capture.activeSpeakerCount) speakers talking",
                      systemImage: "exclamationmark.2")
                    .font(.system(.callout, design: .rounded).weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: capture.overlapDetected)
    }

    private var infoBadge: some View {
        HStack(spacing: 10) {
            Label("\(capture.faceCount)", systemImage: "face.smiling")
            Label("\(capture.activeSpeakerCount) active", systemImage: "waveform.badge.mic")
            Label("\(Int(capture.fps)) fps", systemImage: "speedometer")
        }
        .font(.system(.callout, design: .rounded).weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }

    // MARK: - Speakers sidebar

    private var speakerSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Speakers").font(.headline)
                .padding(.horizontal).padding(.top)
            fusionStatus
                .padding(.horizontal).padding(.top, 8)
            audioDiagnostics
                .padding(.horizontal).padding(.top, 4).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if capture.trackedFaces.isEmpty {
                        Text("No faces detected")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(capture.trackedFaces) { speakerRow($0) }
                }
                .padding()
            }
            Divider()
            tuningPanel.padding()
        }
        .background(.background)
    }

    private func speakerRow(_ face: TrackedFace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speaker \(face.id)").font(.subheadline.weight(.semibold))
                Spacer()
                if face.isActive {
                    Text("ACTIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            meterRow("LAR", value: face.smoothedLAR, max: 0.6, tint: .blue)
            meterRow("Move", value: face.activity, max: 0.03, tint: face.isActive ? .green : .gray)
        }
        .padding(10)
        .background(face.isActive ? Color.green.opacity(0.12) : Color.gray.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func meterRow(_ label: String, value: Double, max: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * Swift.min(1, CGFloat(value / max)))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.3f", value))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var tuningPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tuning").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Talk threshold: \(String(format: "%.3f", talkThreshold))").font(.caption)
                Slider(value: $talkThreshold, in: 0.002...0.030)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Hold time: \(String(format: "%.2f", holdTime)) s").font(.caption)
                Slider(value: $holdTime, in: 0.1...1.0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Speech margin: \(String(format: "%.0f", speechMargin)) dB").font(.caption)
                Slider(value: $speechMargin, in: 2...15)
            }
        }
        .onChange(of: talkThreshold) { pushConfig() }
        .onChange(of: holdTime) { pushConfig() }
        .onChange(of: speechMargin) { capture.setSpeechMargin(Float(speechMargin)) }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button(action: capture.toggle) {
                Label(capture.isRunning ? "Stop" : "Start",
                      systemImage: capture.isRunning ? "stop.fill" : "play.fill")
                    .frame(width: 64)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])

            permissionDot("Camera", granted: capture.cameraAuthorized)
            permissionDot("Mic", granted: capture.microphoneAuthorized)

            audioMeter
            speechIndicator

            Spacer()

            Text(capture.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func permissionDot(_ title: String, granted: Bool) -> some View {
        HStack(spacing: 5) {
            Circle().fill(granted ? Color.green : Color.red).frame(width: 9, height: 9)
            Text(title).font(.callout)
        }
    }

    private var audioMeter: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(meterColor)
                        .frame(width: max(2, geo.size.width * CGFloat(capture.audioLevel)))
                }
            }
            .frame(width: 90, height: 8)
        }
    }

    private var speechIndicator: some View {
        HStack(spacing: 5) {
            Circle().fill(capture.audioSpeechActive ? Color.green : Color.secondary)
                .frame(width: 9, height: 9)
            Text("Speech").font(.callout)
                .foregroundStyle(capture.audioSpeechActive ? .primary : .secondary)
        }
    }

    private var fusionStatus: some View {
        HStack(spacing: 8) {
            miniBadge("2+ lips", on: capture.activeSpeakerCount >= 2, system: "mouth")
            miniBadge("speech", on: capture.audioSpeechActive, system: "waveform")
            Spacer()
        }
    }

    private func miniBadge(_ text: String, on: Bool, system: String) -> some View {
        Label(text, systemImage: system)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(on ? Color.orange.opacity(0.25) : Color.gray.opacity(0.15), in: Capsule())
            .foregroundStyle(on ? Color.primary : Color.secondary)
    }

    private var audioDiagnostics: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "audio %.0f dB · floor %.0f dB",
                        capture.audioEnergyDB, capture.noiseFloorDB))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if !capture.audioDeviceName.isEmpty {
                Text("mic: \(capture.audioDeviceName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var meterColor: Color {
        switch capture.audioLevel {
        case ..<0.5: return .green
        case ..<0.8: return .yellow
        default: return .red
        }
    }
}
