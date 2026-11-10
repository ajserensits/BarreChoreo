import SwiftUI

struct TeachingCopyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ChoreographyScript
    let onSave: (ChoreographyScript) -> Void

    init(script: ChoreographyScript, onSave: @escaping (ChoreographyScript) -> Void) {
        _draft = State(initialValue: script)
        self.onSave = onSave
    }

    private var removedOriginalSections: [ChoreographySection] {
        let includedIDs = Set(draft.sections.map(\.id))
        return draft.originalSections.filter { !includedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Teaching Copy") {
                    TextField("Class Name", text: $draft.title)
                        .textInputAutocapitalization(.words)
                    LabeledContent("Source", value: draft.sourceFilename)
                }

                Section {
                    ForEach($draft.sections) { $section in
                        NavigationLink {
                            TeachingSectionEditorView(
                                section: $section,
                                originalSection: originalSection(withID: section.id)
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(section.heading)
                                    .font(.body.weight(.semibold))
                                Text(sectionEditorSummary(section))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { draft.sections.remove(atOffsets: $0) }
                    .onMove { draft.sections.move(fromOffsets: $0, toOffset: $1) }

                    Button(action: addSection) {
                        Label("Add Section", systemImage: "plus")
                    }
                } header: {
                    Text("Included Sections")
                } footer: {
                    Text("Swipe to exclude a section. Use Edit to reorder sections.")
                }

                if !removedOriginalSections.isEmpty {
                    Section {
                        ForEach(removedOriginalSections) { section in
                            Button {
                                restore(section)
                            } label: {
                                Label(section.heading, systemImage: "arrow.uturn.backward.circle")
                            }
                        }
                    } header: {
                        Text("Excluded from Original")
                    } footer: {
                        Text("Excluded sections remain available here and are not sent to Apple Watch.")
                    }
                }

                Section("Apple Watch") {
                    Toggle("Available offline on Watch", isOn: $draft.isAvailableOnWatch)
                }

                if draft.hasCustomizations {
                    Section {
                        Button("Restore Entire Original", role: .destructive) {
                            draft.restoreOriginalSections()
                        }
                    } footer: {
                        Text("This replaces all section edits in this teaching copy. The imported original is never changed.")
                    }
                }
            }
            .navigationTitle(draft.isBuiltPlan ? "Edit Class Plan" : "Edit Teaching Copy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Save") {
                        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    EditButton()
                }
            }
        }
    }

    private func addSection() {
        draft.sections.append(.init(
            heading: "CUSTOM SECTION",
            combinations: [.init(title: "CUSTOM", cues: [.init(text: "New cue")])]
        ))
    }

    private func originalSection(withID id: UUID) -> ChoreographySection? {
        draft.originalSections.first { $0.id == id }
    }

    private func restore(_ section: ChoreographySection) {
        guard let originalIndex = draft.originalSections.firstIndex(where: { $0.id == section.id }) else {
            draft.sections.append(section)
            return
        }
        let laterOriginalIDs = Set(draft.originalSections.dropFirst(originalIndex + 1).map(\.id))
        if let insertionIndex = draft.sections.firstIndex(where: { laterOriginalIDs.contains($0.id) }) {
            draft.sections.insert(section, at: insertionIndex)
        } else {
            draft.sections.append(section)
        }
    }
}

struct TeachingSectionEditorView: View {
    @Binding var section: ChoreographySection
    let originalSection: ChoreographySection?

    var body: some View {
        Form {
            Section("Section") {
                TextField("Heading", text: $section.heading)
                    .textInputAutocapitalization(.characters)
                TextField("Song", text: optionalBinding(\.song))
                TextField("Option", text: optionalBinding(\.option))
                TextField("Equipment", text: optionalBinding(\.equipment))
                TextField("Direction", text: optionalBinding(\.direction))
            }

            Section("Combinations") {
                ForEach($section.combinations) { $combination in
                    NavigationLink {
                        TeachingCombinationEditorView(
                            combination: $combination,
                            repeatDestinations: repeatDestinations(in: section)
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(combination.title?.nilIfBlank ?? "Untitled Combination")
                            Text("\(combination.cues.count) cues")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { section.combinations.remove(atOffsets: $0) }
                .onMove { section.combinations.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    section.combinations.append(.init(title: "CUSTOM", cues: [.init(text: "New cue")]))
                } label: {
                    Label("Add Combination", systemImage: "plus")
                }
            }

            if let originalSection, section != originalSection {
                Section {
                    Button("Restore This Section", role: .destructive) {
                        section = originalSection
                    }
                }
            }
        }
        .navigationTitle(section.heading)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<ChoreographySection, String?>) -> Binding<String> {
        Binding(
            get: { section[keyPath: keyPath] ?? "" },
            set: { section[keyPath: keyPath] = $0.nilIfBlank }
        )
    }
}

private struct TeachingCombinationEditorView: View {
    @Binding var combination: ChoreographyCombination
    let repeatDestinations: [RepeatDestination]

    var body: some View {
        List {
            Section("Combination") {
                TextField("Title", text: Binding(
                    get: { combination.title ?? "" },
                    set: { combination.title = $0.nilIfBlank }
                ))
                .textInputAutocapitalization(.characters)
            }

            Section("Cues") {
                ForEach($combination.cues) { $cue in
                    NavigationLink {
                        TeachingCueEditorView(cue: $cue, repeatDestinations: repeatDestinations)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cue.shortText?.nilIfBlank ?? cue.text)
                                .lineLimit(2)
                            Text(cueKindName(cue.kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { combination.cues.remove(atOffsets: $0) }
                .onMove { combination.cues.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    combination.cues.append(.init(text: "New cue"))
                } label: {
                    Label("Add Cue", systemImage: "plus")
                }
            }
        }
        .navigationTitle(combination.title?.nilIfBlank ?? "Combination")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}

private struct TeachingCueEditorView: View {
    @Binding var cue: ChoreographyCue
    let repeatDestinations: [RepeatDestination]

    var body: some View {
        Form {
            Section("Cue Text") {
                TextEditor(text: $cue.text)
                    .frame(minHeight: 120)
                TextField("Short text (optional)", text: Binding(
                    get: { cue.shortText ?? "" },
                    set: { cue.shortText = $0.nilIfBlank }
                ))
                TextField("List marker (optional)", text: Binding(
                    get: { cue.listMarker ?? "" },
                    set: { cue.listMarker = $0.nilIfBlank }
                ))
            }

            Section("Type") {
                Picker("Cue Type", selection: $cue.kind) {
                    ForEach(ChoreographyCueKind.allCases, id: \.self) { kind in
                        Text(cueKindName(kind)).tag(kind)
                    }
                }
            }

            if cue.kind == .repeatInstruction {
                Section {
                    Picker("Repeat From", selection: repeatTargetBinding) {
                        Text("Not linked").tag(nil as UUID?)
                        ForEach(repeatDestinations) { destination in
                            Text(destination.label).tag(destination.id as UUID?)
                        }
                    }
                } header: {
                    Text("Repeat Link")
                } footer: {
                    Text("This controls where Repeat from Top jumps on Apple Watch.")
                }
            }
        }
        .navigationTitle("Edit Cue")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: cue.kind) { _, newKind in
            if newKind == .repeatInstruction, cue.repeatTargetCueID == nil {
                cue.repeatTargetCueID = repeatDestinations.first?.id
            } else if newKind != .repeatInstruction {
                cue.repeatTargetCueID = nil
            }
        }
    }

    private var repeatTargetBinding: Binding<UUID?> {
        Binding(
            get: {
                guard repeatDestinations.contains(where: { $0.id == cue.repeatTargetCueID }) else { return nil }
                return cue.repeatTargetCueID
            },
            set: { cue.repeatTargetCueID = $0 }
        )
    }
}

private struct RepeatDestination: Identifiable {
    let id: UUID
    let label: String
}

private func repeatDestinations(in section: ChoreographySection) -> [RepeatDestination] {
    section.combinations.enumerated().compactMap { combinationIndex, combination in
        guard let cue = combination.cues.first(where: {
            $0.kind == .choreography || $0.kind == .setup || $0.kind == .transition
        }) else { return nil }

        let heading = combination.title?.nilIfBlank ?? (combinationIndex == 0 ? "Top of section" : "Combination \(combinationIndex + 1)")
        let cueText = cue.shortText?.nilIfBlank ?? cue.text
        return RepeatDestination(id: cue.id, label: "\(heading): \(cueText)")
    }
}

private func sectionEditorSummary(_ section: ChoreographySection) -> String {
    let cueCount = section.combinations.reduce(0) { $0 + $1.cues.count }
    let metadata = [section.song, section.option].compactMap { $0?.nilIfBlank }
    return (["\(cueCount) cues"] + metadata).joined(separator: " • ")
}

private func cueKindName(_ kind: ChoreographyCueKind) -> String {
    switch kind {
    case .choreography: "Choreography"
    case .setup: "Setup"
    case .equipment: "Equipment"
    case .song: "Music and lights"
    case .option: "Option"
    case .transition: "Transition"
    case .repeatInstruction: "Repeat"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
