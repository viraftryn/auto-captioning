import SwiftUI
import AppKit

/// The clean caption view, shown in its own pop-up window: full camera feed with
/// NO face landmarks, live captions overlaid at the bottom. It shares the running
/// `CaptureManager` (same session + engine) with the main window, so the detail
/// view stays fully usable at the same time.
struct CaptionWindowView: View {
    @ObservedObject var capture: CaptureManager

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: capture.session, faces: [])
            CaptionOverlay(engine: capture.live)
        }
        .frame(minWidth: 480, minHeight: 300)
        .background(.black)
    }
}

/// Opens (and reuses) a single auxiliary `NSWindow` hosting `CaptionWindowView`.
/// Done in AppKit so the window opens on demand and never appears at launch — a
/// SwiftUI `Window` scene would be created up-front on macOS 14.
final class CaptionWindowPresenter {
    private var window: NSWindow?

    func show(capture: CaptureManager) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: CaptionWindowView(capture: capture))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Live Captions"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 720, height: 460))
        w.isReleasedWhenClosed = false   // keep it around so the button can reopen it
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
