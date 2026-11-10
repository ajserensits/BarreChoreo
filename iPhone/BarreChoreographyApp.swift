import SwiftUI

@main
struct BarreChoreographyApp: App {
    @StateObject private var store = ScriptStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
        }
    }
}

