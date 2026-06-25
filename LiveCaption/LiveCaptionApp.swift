import SwiftUI

@main
struct LiveCaptionApp: App {
    var body: some Scene {
        WindowGroup("LiveCaption") {
            ContentView()
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
