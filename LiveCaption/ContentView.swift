import SwiftUI

struct ContentView: View {
    @StateObject private var capture = CaptureManager()

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CameraPreview(session: capture.session,
                              observations: capture.faceObservations)
                    .frame(minWidth: 640, minHeight: 360)

                infoOverlay.padding(12)
            }
            controlBar
        }
        .onAppear { capture.start() }
        .onDisappear { capture.stop() }
    }

    // MARK: Subviews

    private var infoOverlay: some View {
        HStack(spacing: 10) {
            Label("\(capture.faceCount)", systemImage: "face.smiling")
            Label("\(Int(capture.fps)) fps", systemImage: "speedometer")
        }
        .font(.system(.callout, design: .rounded).weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }

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
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            Text(title).font(.callout)
        }
    }

    private var audioMeter: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(meterColor)
                        .frame(width: max(2, geo.size.width * CGFloat(capture.audioLevel)))
                }
            }
            .frame(width: 90, height: 8)
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

#Preview {
    ContentView()
}
