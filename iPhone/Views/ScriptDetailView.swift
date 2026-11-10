import SwiftUI

struct ScriptDetailView: View {
    @EnvironmentObject private var store: ScriptStore
    let script: ChoreographyScript
    @State private var editingDraft: ChoreographyScript?
    @State private var showingStudyMode = false

    private var currentScript: ChoreographyScript {
        store.scripts.first(where: { $0.id == script.id }) ?? script
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Plan", value: currentScript.planLabel)
                LabeledContent("Class type", value: currentScript.classType.displayName)
                if let minutes = currentScript.plannedDurationMinutes {
                    LabeledContent("Planned time", value: "\(minutes) minutes")
                }
                LabeledContent("Source", value: currentScript.sourceFilename)
                LabeledContent("Imported", value: currentScript.importedAt.formatted(date: .abbreviated, time: .shortened))
                if currentScript.isTeachingCopy {
                    LabeledContent("Status", value: currentScript.hasCustomizations ? "Customized" : "Matches Original")
                }
            }

            Section {
                Button {
                    showingStudyMode = true
                } label: {
                    Label("Study with Flash Cards", systemImage: "rectangle.on.rectangle.angled")
                }
                .disabled(currentScript.sections.allSatisfy { $0.combinations.isEmpty })
            } footer: {
                Text("Choose sections, reveal each combination's choreography, and mark what you know. Studying never changes the saved plan.")
            }

            if !currentScript.isTeachingCopy && !currentScript.isBuiltPlan {
                Section {
                    Button {
                        editingDraft = currentScript.makeTeachingCopy()
                    } label: {
                        Label("Create Teaching Copy", systemImage: "doc.on.doc")
                    }
                } footer: {
                    Text("The imported original stays locked. Edit a teaching copy to exclude, reorder, or add choreography.")
                }
            }

            Section("Apple Watch") {
                Toggle("Available offline on Watch", isOn: Binding(
                    get: { currentScript.isAvailableOnWatch },
                    set: { store.setWatchAvailability(for: currentScript.id, isAvailable: $0) }
                ))
            }

            ForEach(currentScript.sections) { section in
                Section(section.heading) {
                    if section.song != nil || section.equipment != nil || section.option != nil || section.direction != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            if let song = section.song { Label(song, systemImage: "music.note") }
                            if let equipment = section.equipment { Label(equipment, systemImage: "dumbbell") }
                            if let option = section.option { Label(option, systemImage: "arrow.triangle.branch") }
                            if let direction = section.direction { Label(direction, systemImage: "location") }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(section.combinations) { combination in
                        VStack(alignment: .leading, spacing: 8) {
                            if let title = combination.title {
                                Text(title).font(.headline)
                            }
                            ForEach(combination.cues) { cue in
                                HStack(alignment: .top, spacing: 8) {
                                    if let marker = cue.listMarker {
                                        Text(marker)
                                            .font(.body.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        if let shortText = cue.shortText {
                                            Text(shortText).font(.subheadline.weight(.semibold))
                                        }
                                        Text(cue.text)
                                        if cue.kind != .choreography {
                                            Label(cue.kind.displayName, systemImage: cue.kind.systemImage)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Original Extracted Text") {
                Text(currentScript.originalText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(currentScript.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if currentScript.isTeachingCopy || currentScript.isBuiltPlan {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            editingDraft = currentScript
                        } label: {
                            Label(currentScript.isBuiltPlan ? "Edit Class Plan" : "Edit Teaching Copy", systemImage: "pencil")
                        }
                        Button {
                            editingDraft = currentScript.makeTeachingCopy(title: "\(currentScript.title) – Copy")
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                    } label: {
                        Label("Edit", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $editingDraft) { draft in
            TeachingCopyEditorView(script: draft) { saved in
                store.saveTeachingCopy(saved)
            }
        }
        .fullScreenCover(isPresented: $showingStudyMode) {
            StudyModeView(script: currentScript)
        }
    }
}

private struct StudyCard: Identifiable, Hashable {
    let id: UUID
    let sectionHeading: String
    let combinationTitle: String
    let metadata: [String]
    let cues: [ChoreographyCue]
}

private struct StudyModeView: View {
    @Environment(\.dismiss) private var dismiss
    let script: ChoreographyScript

    @State private var selectedSectionIDs: Set<UUID>
    @State private var shuffleCards = false
    @State private var sessionStarted = false
    @State private var queue: [StudyCard] = []
    @State private var masteredCardIDs: Set<UUID> = []
    @State private var revealed = false
    @State private var revealedCueCount = 0
    @State private var reviewAgainCount = 0
    @State private var sessionCardCount = 0

    init(script: ChoreographyScript) {
        self.script = script
        _selectedSectionIDs = State(initialValue: Set(script.sections.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !sessionStarted {
                    setupView
                } else if let card = queue.first {
                    cardView(card)
                } else {
                    summaryView
                }
            }
            .navigationTitle(sessionStarted ? "Study" : "Study \(script.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Study Mode")
                }
            }
        }
    }

    private var setupView: some View {
        List {
            Section {
                LabeledContent("Plan", value: script.title)
                LabeledContent("Cards", value: "\(selectedCards.count)")
                Toggle("Shuffle Cards", isOn: $shuffleCards)
            } header: {
                Text("Session")
            } footer: {
                Text("Cards are shown in class order unless Shuffle Cards is enabled.")
            }

            Section {
                ForEach(script.sections) { section in
                    Button {
                        toggleSection(section.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedSectionIDs.contains(section.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedSectionIDs.contains(section.id) ? Color.pink : Color.secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(section.heading)
                                    .foregroundStyle(.primary)
                                Text("\(section.combinations.count) combinations")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Sections")
                    Spacer()
                    Button(selectedSectionIDs.count == script.sections.count ? "Clear" : "Select All") {
                        if selectedSectionIDs.count == script.sections.count {
                            selectedSectionIDs.removeAll()
                        } else {
                            selectedSectionIDs = Set(script.sections.map(\.id))
                        }
                    }
                    .textCase(nil)
                }
            } footer: {
                Text("All sections are selected initially. Choose only the areas you want to study this session.")
            }

            Section {
                Button(action: startSession) {
                    Label("Start Studying", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(selectedCards.isEmpty)
            }
            .listRowBackground(Color.clear)
        }
    }

    private func cardView(_ card: StudyCard) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(masteredCardIDs.count) mastered")
                Spacer()
                Text("\(queue.count) remaining")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ProgressView(value: Double(masteredCardIDs.count), total: Double(max(sessionCardCount, 1)))
                .tint(.pink)

            Group {
                if revealed {
                    revealedCard(card)
                } else {
                    promptCard(card)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 12, y: 5)

            if revealed && revealedCueCount >= card.cues.count {
                HStack(spacing: 12) {
                    Button(action: studyAgain) {
                        Label("Study Again", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: gotIt) {
                        Label("Got It", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                }
            } else if revealed {
                Button(action: revealNextCue) {
                    Label(
                        revealedCueCount == 0 ? "Reveal First Cue" : "Reveal Next Cue",
                        systemImage: "eye.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .accessibilityHint("Reveals cue \(revealedCueCount + 1) of \(card.cues.count)")
            } else {
                Text("Tap the card to reveal the choreography")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func promptCard(_ card: StudyCard) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                revealed = true
                revealedCueCount = 0
            }
        } label: {
            VStack(spacing: 18) {
                Text(card.sectionHeading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 34))
                    .foregroundStyle(.pink)

                Text(card.combinationTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                if !card.metadata.isEmpty {
                    Text(card.metadata.joined(separator: " • "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(card.sectionHeading), \(card.combinationTitle). Tap to reveal choreography.")
    }

    private func revealedCard(_ card: StudyCard) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(card.sectionHeading)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(card.combinationTitle)
                            .font(.title3.bold())
                        if !card.metadata.isEmpty {
                            Text(card.metadata.joined(separator: " • "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    if revealedCueCount == 0 {
                        VStack(spacing: 10) {
                            Image(systemName: "eye.slash")
                                .font(.title2)
                                .foregroundStyle(.pink)
                            Text("Picture the first cue, then reveal it when you're ready.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(card.cues.prefix(revealedCueCount)) { cue in
                            HStack(alignment: .top, spacing: 8) {
                                if let marker = cue.listMarker {
                                    Text(marker)
                                        .font(.body.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.pink)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    if let shortText = cue.shortText,
                                       shortText.localizedCaseInsensitiveCompare(cue.text) != .orderedSame {
                                        Text(shortText)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text(cue.text)
                                        .font(.body)
                                    if cue.kind != .choreography {
                                        Text(cue.kind.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(cue.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
                .padding(22)
            }
            .scrollIndicators(.visible)
            .onChange(of: revealedCueCount) { _, newCount in
                guard newCount > 0, newCount <= card.cues.count else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(card.cues[newCount - 1].id, anchor: .bottom)
                }
            }
        }
    }

    private var summaryView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.pink)
            Text("Study Session Complete")
                .font(.title2.bold())
            Text("You mastered \(sessionCardCount) cards\(reviewAgainCount == 0 ? "." : " and repeated \(reviewAgainCount) for extra practice.")")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(action: startSession) {
                Label("Study Same Sections Again", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)

            Button("Change Sections") {
                sessionStarted = false
                resetSessionProgress()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(28)
    }

    private var selectedCards: [StudyCard] {
        script.sections
            .filter { selectedSectionIDs.contains($0.id) }
            .flatMap { section in
                section.combinations.enumerated().compactMap { index, combination in
                    guard !combination.cues.isEmpty else { return nil }
                    return StudyCard(
                        id: combination.id,
                        sectionHeading: section.heading,
                        combinationTitle: combination.title?.studyNonblank
                            ?? combination.cues.first?.shortText?.studyNonblank
                            ?? "Combination \(index + 1)",
                        metadata: [section.song, section.option, section.equipment, section.direction]
                            .compactMap { $0?.studyNonblank },
                        cues: combination.cues
                    )
                }
            }
    }

    private func toggleSection(_ id: UUID) {
        if selectedSectionIDs.contains(id) {
            selectedSectionIDs.remove(id)
        } else {
            selectedSectionIDs.insert(id)
        }
    }

    private func startSession() {
        resetSessionProgress()
        let cards = selectedCards
        sessionCardCount = cards.count
        queue = shuffleCards ? cards.shuffled() : cards
        sessionStarted = true
    }

    private func studyAgain() {
        guard let current = queue.first else { return }
        var updated = Array(queue.dropFirst())
        updated.append(current)
        queue = updated
        reviewAgainCount += 1
        revealed = false
        revealedCueCount = 0
    }

    private func gotIt() {
        guard let current = queue.first else { return }
        masteredCardIDs.insert(current.id)
        queue.removeFirst()
        revealed = false
        revealedCueCount = 0
    }

    private func revealNextCue() {
        guard let current = queue.first, revealedCueCount < current.cues.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            revealedCueCount += 1
        }
    }

    private func resetSessionProgress() {
        queue = []
        masteredCardIDs = []
        revealed = false
        revealedCueCount = 0
        reviewAgainCount = 0
        sessionCardCount = 0
    }
}

private extension String {
    var studyNonblank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension ChoreographyCueKind {
    var displayName: String {
        switch self {
        case .choreography: "Choreography"
        case .setup: "Setup"
        case .equipment: "Equipment"
        case .song: "Music and lights"
        case .option: "Option"
        case .transition: "Transition"
        case .repeatInstruction: "Repeat"
        }
    }

    var systemImage: String {
        switch self {
        case .choreography: "figure.barre"
        case .setup: "list.bullet.clipboard"
        case .equipment: "dumbbell"
        case .song: "music.note"
        case .option: "arrow.triangle.branch"
        case .transition: "arrow.forward"
        case .repeatInstruction: "repeat"
        }
    }
}

