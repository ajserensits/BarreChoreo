import SwiftUI

@main
struct BarreWatchApp: App {
    @StateObject private var store = WatchScriptStore()

    var body: some Scene {
        WindowGroup {
            WatchLibraryView()
                .environmentObject(store)
        }
    }
}

