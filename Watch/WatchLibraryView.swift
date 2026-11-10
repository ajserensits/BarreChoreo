import SwiftUI

struct WatchLibraryView: View {
    @EnvironmentObject private var store: WatchScriptStore
    @AppStorage("lastScriptID") private var lastScriptID = ""

    var body: some View {
        NavigationStack {
            Group {
                if store.scripts.isEmpty {
                    ContentUnavailableView("No Scripts", systemImage: "iphone.and.arrow.forward", description: Text("Import on iPhone, then sync."))
                } else {
                    List(store.scripts) { script in
                        NavigationLink(value: script) {
                            VStack(alignment: .leading) {
                                Text(script.title).font(.headline)
                                Text(summary(for: script)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Choreography")
            .navigationDestination(for: ChoreographyScript.self) { script in
                WatchScriptView(script: script)
                    .onAppear { lastScriptID = script.id.uuidString }
            }
        }
    }

    private func summary(for script: ChoreographyScript) -> String {
        var values = [script.classType.displayName, "\(script.sections.count) sections"]
        if let minutes = script.plannedDurationMinutes {
            values.append("\(minutes) min")
        }
        return values.joined(separator: " • ")
    }
}

