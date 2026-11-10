import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: ScriptStore
    @State private var showingImporter = false
    @State private var showingPlanBuilder = false
    @State private var showingHighlightedPDFImporter = false
    @State private var showingHighlightedPDFBuilder = false
    @State private var highlightedPDFURLs: [URL] = []

    var body: some View {
        NavigationStack {
            Group {
                if store.scripts.isEmpty {
                    ContentUnavailableView(
                        "No Class Scripts",
                        systemImage: "doc.text",
                        description: Text("Import a text-based choreography PDF from Files to begin.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(store.scripts) { script in
                                NavigationLink(value: script) {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(script.title).font(.headline)
                                            Text("\(script.classType.displayName) • \(script.sections.count) sections • \(script.planLabel)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if script.isAvailableOnWatch {
                                            Image(systemName: "applewatch")
                                                .foregroundStyle(.pink)
                                                .accessibilityLabel("Available on Apple Watch")
                                        }
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        store.setWatchAvailability(
                                            for: script.id,
                                            isAvailable: !script.isAvailableOnWatch
                                        )
                                    } label: {
                                        Label(
                                            script.isAvailableOnWatch ? "Remove from Watch" : "Add to Watch",
                                            systemImage: script.isAvailableOnWatch ? "applewatch.slash" : "applewatch"
                                        )
                                    }
                                    .tint(.pink)
                                }
                            }
                            .onDelete(perform: store.delete)
                        } footer: {
                            Text(store.watchSyncSummary)
                        }
                    }
                }
            }
            .navigationTitle("Class Scripts")
            .navigationDestination(for: ChoreographyScript.self) { script in
                ScriptDetailView(script: script)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { store.syncNow() } label: {
                            Label("Sync Watch", systemImage: "applewatch.radiowaves.left.and.right")
                        }
                        .disabled(store.watchScripts.isEmpty)

                        Button { store.prepareAudioFollow() } label: {
                            Label("Set Up Audio Follow", systemImage: "mic.badge.plus")
                        }
                    } label: {
                        Label("Watch & Audio", systemImage: "applewatch.radiowaves.left.and.right")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingImporter = true } label: {
                            Label("Import PDF", systemImage: "square.and.arrow.down")
                        }
                        Button { showingPlanBuilder = true } label: {
                            Label("Build Class Plan", systemImage: "rectangle.stack.badge.plus")
                        }
                        .disabled(store.scripts.isEmpty)
                        Button { showingHighlightedPDFImporter = true } label: {
                            Label("Build Highlighted PDF", systemImage: "highlighter")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .overlay { if store.isImporting { ProgressView("Reading PDF…") } }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): Task { await store.prepareImport(from: url) }
                case .failure(let error): store.importError = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $showingHighlightedPDFImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    highlightedPDFURLs = urls
                    showingHighlightedPDFBuilder = true
                case .failure(let error):
                    store.importError = error.localizedDescription
                }
            }
            .sheet(isPresented: Binding(
                get: { store.pendingImport != nil },
                set: { if !$0 { store.cancelPendingImport() } }
            )) {
                if let script = store.pendingImport {
                    ImportPreviewView(
                        script: script,
                        onSave: store.savePendingImport,
                        onCancel: store.cancelPendingImport
                    )
                }
            }
            .sheet(isPresented: $showingPlanBuilder) {
                ClassPlanBuilderView(scripts: store.scripts) { title, selections, availableOnWatch in
                    store.saveBuiltClassPlan(
                        title: title,
                        selections: selections,
                        availableOnWatch: availableOnWatch
                    )
                }
            }
            .sheet(isPresented: $showingHighlightedPDFBuilder, onDismiss: {
                highlightedPDFURLs = []
            }) {
                HighlightedPDFBuilderView(urls: highlightedPDFURLs)
            }
            .alert("Import Problem", isPresented: Binding(
                get: { store.importError != nil },
                set: { if !$0 { store.importError = nil } }
            )) { Button("OK") { store.importError = nil } } message: {
                Text(store.importError ?? "Unknown error")
            }
            .alert("Audio Follow", isPresented: Binding(
                get: { store.audioSetupMessage != nil },
                set: { if !$0 { store.audioSetupMessage = nil } }
            )) { Button("OK") { store.audioSetupMessage = nil } } message: {
                Text(store.audioSetupMessage ?? "")
            }
        }
    }
}

private struct ClassPlanBuilderView: View {
    private enum Step: Int {
        case sources
        case sections
        case review
    }

    private struct ChoiceID: Hashable {
        let scriptID: UUID
        let sectionID: UUID
    }

    private struct Choice: Identifiable {
        var id: ChoiceID { ChoiceID(scriptID: script.id, sectionID: section.id) }
        let script: ChoreographyScript
        let section: ChoreographySection
    }

    @Environment(\.dismiss) private var dismiss
    let scripts: [ChoreographyScript]
    let onSave: (String, [(script: ChoreographyScript, section: ChoreographySection)], Bool) -> Void

    @State private var step: Step = .sources
    @State private var selectedSourceIDs: Set<UUID> = []
    @State private var selectedChoiceIDs: Set<ChoiceID> = []
    @State private var orderedChoiceIDs: [ChoiceID] = []
    @State private var editedSections: [ChoiceID: ChoreographySection] = [:]
    @State private var previewChoice: Choice?
    @State private var planName = "New Class Plan"
    @State private var availableOnWatch = false
    private let choices: [Choice]

    init(
        scripts: [ChoreographyScript],
        onSave: @escaping (String, [(script: ChoreographyScript, section: ChoreographySection)], Bool) -> Void
    ) {
        self.scripts = scripts
        self.onSave = onSave
        choices = scripts.flatMap { script in
            script.sections.map { Choice(script: script, section: $0) }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .sources: sourcePicker
                case .sections: sectionPicker
                case .review: review
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .sources ? "Cancel" : "Back") {
                        if step == .sources {
                            dismiss()
                        } else {
                            step = Step(rawValue: step.rawValue - 1) ?? .sources
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .review {
                        Button("Save", action: save)
                            .disabled(planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("Next", action: advance)
                            .disabled(!canAdvance)
                    }
                }
            }
        }
        .interactiveDismissDisabled(step != .sources)
        .sheet(item: $previewChoice) { choice in
            ClassPlanSectionPreviewView(
                scriptTitle: choice.script.title,
                section: effectiveSection(for: choice),
                originalSection: choice.section,
                isSelected: selectedChoiceIDs.contains(choice.id),
                onSave: { updatedSection in
                    if updatedSection == choice.section {
                        editedSections.removeValue(forKey: choice.id)
                    } else {
                        editedSections[choice.id] = updatedSection
                    }
                },
                onRemove: {
                    selectedChoiceIDs.remove(choice.id)
                    orderedChoiceIDs.removeAll { $0 == choice.id }
                }
            )
        }
    }

    private var sourcePicker: some View {
        List {
            Section {
                ForEach(scripts) { script in
                    selectionRow(
                        title: script.title,
                        subtitle: "\(script.sections.count) sections • \(script.classType.displayName) • \(script.planLabel)",
                        isSelected: selectedSourceIDs.contains(script.id)
                    ) {
                        toggle(script.id, in: &selectedSourceIDs)
                        if !selectedSourceIDs.contains(script.id) {
                            let removedIDs = Set(choices.filter { $0.script.id == script.id }.map(\.id))
                            selectedChoiceIDs.subtract(removedIDs)
                            orderedChoiceIDs.removeAll { removedIDs.contains($0) }
                            for id in removedIDs {
                                editedSections.removeValue(forKey: id)
                            }
                        }
                    }
                }
            } header: {
                Text("Choose Source Imports")
            } footer: {
                Text("Choose one or more imported plans. Nothing from them will be changed.")
            }
        }
    }

    private var sectionPicker: some View {
        List {
            ForEach(selectedScripts) { script in
                Section(script.title) {
                    ForEach(choices.filter { $0.script.id == script.id }) { choice in
                        sectionSelectionRow(choice)
                    }
                }
            }
        }
    }

    private var review: some View {
        List {
            Section("Class Plan") {
                TextField("Class Plan Name", text: $planName)
                    .textInputAutocapitalization(.words)
                Toggle("Available on Apple Watch", isOn: $availableOnWatch)
            }

            Section {
                ForEach(orderedChoices) { choice in
                    let section = effectiveSection(for: choice)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.heading)
                            .font(.body.weight(.semibold))
                        Text(choice.script.title + (editedSections[choice.id] == nil ? "" : " • Edited"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onMove { orderedChoiceIDs.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Section Order")
            } footer: {
                Text("Drag the handles to arrange the class from beginning to end.")
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    private func selectionRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.pink : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sectionSelectionRow(_ choice: Choice) -> some View {
        let section = effectiveSection(for: choice)
        return HStack(spacing: 10) {
            Button {
                toggle(choice.id, in: &selectedChoiceIDs)
            } label: {
                HStack(spacing: 12) {
                    let isSelected = selectedChoiceIDs.contains(choice.id)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.pink : Color.secondary)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.heading)
                            .foregroundStyle(.primary)
                        Text(sectionSummary(section))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if editedSections[choice.id] != nil {
                        Image(systemName: "pencil.circle.fill")
                            .foregroundStyle(.pink)
                            .accessibilityLabel("Edited for this class plan")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                previewChoice = choice
            } label: {
                Image(systemName: "eye")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview \(choice.section.heading)")
            .accessibilityHint("Shows the combinations and cues without selecting the section")
        }
    }

    private var selectedScripts: [ChoreographyScript] {
        scripts.filter { selectedSourceIDs.contains($0.id) }
    }

    private var orderedChoices: [Choice] {
        orderedChoiceIDs.compactMap { id in choices.first { $0.id == id } }
    }

    private func effectiveSection(for choice: Choice) -> ChoreographySection {
        editedSections[choice.id] ?? choice.section
    }

    private var navigationTitle: String {
        switch step {
        case .sources: "Choose Imports"
        case .sections: "Choose Sections"
        case .review: "Review Class Plan"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .sources: !selectedSourceIDs.isEmpty
        case .sections: !selectedChoiceIDs.isEmpty
        case .review: false
        }
    }

    private func advance() {
        if step == .sections {
            let stillSelected = orderedChoiceIDs.filter(selectedChoiceIDs.contains)
            let alreadyOrdered = Set(stillSelected)
            let newlySelected = choices
                .filter { selectedSourceIDs.contains($0.script.id) }
                .filter { selectedChoiceIDs.contains($0.id) && !alreadyOrdered.contains($0.id) }
                .map(\.id)
            orderedChoiceIDs = stillSelected + newlySelected
        }
        step = Step(rawValue: step.rawValue + 1) ?? .review
    }

    private func save() {
        onSave(
            planName,
            orderedChoices.map { choice in
                (script: choice.script, section: effectiveSection(for: choice))
            },
            availableOnWatch
        )
        dismiss()
    }

    private func toggle<ID: Hashable>(_ id: ID, in selection: inout Set<ID>) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func sectionSummary(_ section: ChoreographySection) -> String {
        let cueCount = section.combinations.reduce(0) { $0 + $1.cues.count }
        return ["\(cueCount) cues", section.song, section.option]
            .compactMap { $0 }
            .joined(separator: " • ")
    }
}

private struct ClassPlanSectionPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let scriptTitle: String
    let originalSection: ChoreographySection
    let isSelected: Bool
    let onSave: (ChoreographySection) -> Void
    let onRemove: () -> Void
    @State private var section: ChoreographySection

    init(
        scriptTitle: String,
        section: ChoreographySection,
        originalSection: ChoreographySection,
        isSelected: Bool,
        onSave: @escaping (ChoreographySection) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.scriptTitle = scriptTitle
        self.originalSection = originalSection
        self.isSelected = isSelected
        self.onSave = onSave
        self.onRemove = onRemove
        _section = State(initialValue: section)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Source", value: scriptTitle)
                    if section != originalSection {
                        Label("Edited for this class plan", systemImage: "pencil.circle.fill")
                            .foregroundStyle(.pink)
                    }
                    if let song = section.song {
                        Label(song, systemImage: "music.note")
                    }
                    if let equipment = section.equipment {
                        Label(equipment, systemImage: "dumbbell")
                    }
                    if let option = section.option {
                        Label(option, systemImage: "arrow.triangle.branch")
                    }
                    if let direction = section.direction {
                        Label(direction, systemImage: "location")
                    }

                    NavigationLink {
                        TeachingSectionEditorView(
                            section: $section,
                            originalSection: originalSection
                        )
                    } label: {
                        Label("Edit for This Plan", systemImage: "pencil")
                    }
                } header: {
                    Text("Section Details")
                } footer: {
                    Text("Edits apply only to this new class plan. The imported source is never changed.")
                }

                if section.combinations.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Cues in This Section",
                            systemImage: "text.page.slash",
                            description: Text("This section can still be included in the class plan.")
                        )
                    }
                } else {
                    ForEach(Array(section.combinations.enumerated()), id: \.element.id) { index, combination in
                        Section(combination.title?.planBuilderNonblank ?? "Combination \(index + 1)") {
                            if combination.cues.isEmpty {
                                Text("No cues")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(combination.cues) { cue in
                                    HStack(alignment: .top, spacing: 8) {
                                        if let marker = cue.listMarker {
                                            Text(marker)
                                                .font(.body.monospacedDigit().weight(.semibold))
                                                .foregroundStyle(.pink)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            if let shortText = cue.shortText?.planBuilderNonblank,
                                               shortText.localizedCaseInsensitiveCompare(cue.text) != .orderedSame {
                                                Text(shortText)
                                                    .font(.subheadline.weight(.semibold))
                                            }
                                            Text(cue.text)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }

                if section != originalSection || isSelected {
                    Section {
                    if section != originalSection {
                        Button {
                            section = originalSection
                        } label: {
                            Label("Restore from Source", systemImage: "arrow.uturn.backward.circle")
                        }
                    }

                    if isSelected {
                        Button(role: .destructive) {
                            onRemove()
                            dismiss()
                        } label: {
                            Label("Remove from Class Plan", systemImage: "trash")
                        }
                    }
                    }
                }
            }
            .navigationTitle(section.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(section == originalSection ? "Done" : "Save") {
                        onSave(section)
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(section != originalSection)
    }
}

private extension String {
    var planBuilderNonblank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ImportPreviewView: View {
    let script: ChoreographyScript
    let onSave: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var className: String
    @State private var availableOnWatch: Bool

    init(
        script: ChoreographyScript,
        onSave: @escaping (String, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.script = script
        self.onSave = onSave
        self.onCancel = onCancel
        _className = State(initialValue: script.title)
        _availableOnWatch = State(initialValue: script.isAvailableOnWatch)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Import Summary") {
                    TextField("Class Name", text: $className)
                        .textInputAutocapitalization(.words)
                    LabeledContent("Class type", value: script.classType.displayName)
                    LabeledContent("Sections", value: "\(script.sections.count)")
                    if let minutes = script.plannedDurationMinutes {
                        LabeledContent("Planned time", value: "\(minutes) minutes")
                    }
                    LabeledContent("Source", value: script.sourceFilename)
                }

                Section("Detected Sections") {
                    ForEach(script.sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.heading)
                            let details = [section.song, section.equipment, section.option]
                                .compactMap { $0 }
                                .joined(separator: " • ")
                            if !details.isEmpty {
                                Text(details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Available on Apple Watch", isOn: $availableOnWatch)
                } footer: {
                    Text("You can change this later. Select the plans you want available on your Apple Watch.")
                }
            }
            .navigationTitle("Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(className, availableOnWatch) }
                }
            }
        }
    }
}

