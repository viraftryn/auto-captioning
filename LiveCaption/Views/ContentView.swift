import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case live = "Live"
    case analyze = "Analyze File"
    var id: String { rawValue }
}

struct ContentView: View {
    @State private var mode: AppMode = .live
    @StateObject private var capture = CaptureManager()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(AppMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(8)

            Divider()

            switch mode {
            case .live: LiveCaptureView(capture: capture)
            case .analyze: AnalysisView()
            }
        }
        .onChange(of: mode) { _, newMode in
            // The camera starts only when the user presses Start (it's off at launch).
            // Just release it when leaving Live for the file analyzer.
            if newMode == .analyze { capture.stop() }
        }
    }
}

#Preview {
    ContentView()
}
