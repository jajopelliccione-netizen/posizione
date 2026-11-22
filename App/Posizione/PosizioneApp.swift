import SwiftUI

@main
struct PosizioneApp: App {
    init() { Notifier.setup() }

    var body: some Scene {
        WindowGroup { ContentView().tint(Theme.accent) }
    }
}
