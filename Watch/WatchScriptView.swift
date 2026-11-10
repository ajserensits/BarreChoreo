import SwiftUI

private enum WatchReadingMode: String, CaseIterable {
    case focus
    case continuous

    var label: String {
        switch self {
        case .focus: "Focus"
        case .continuous: "Continuous"
        }
    }
}

struct WatchScriptView: View {
    let script: ChoreographyScript

    @EnvironmentObject private var watchStore: WatchScriptStore
    @State private var selectedSection = 0
    @State private var showingEndConfirmation = false
    @AppStorage private var savedSection: Int
    @AppStorage private var readingModeRaw: String
    @AppStorage private var hasStarted: Bool
    @AppStorage private var timerRunning: Bool
    @AppStorage private var timerStartedAt: Double
    @AppStorage private var accumulatedSeconds: Double
    @AppStorage("showNextCueHint") private var showNextCueHint = false
    @AppStorage("audioFollowEnabled") private var audioFollowEnabled = false
    @AppStorage("audioAutoAdvanceEnabled") private var audioAutoAdvanceEnabled = false
    @AppStorage("audioSkipAlertsEnabled") private var audioSkipAlertsEnabled = false

    init(script: ChoreographyScript) {
        self.script = script
        let suffix = script.id.uuidString
        _savedSection = AppStorage(wrappedValue: 0, "section-\(suffix)")
        _readingModeRaw = AppStorage(wrappedValue: WatchReadingMode.focus.rawValue, "readingMode-\(suffix)")
        _hasStarted = AppStorage(wrappedValue: false, "classStarted-\(suffix)")
        _timerRunning = AppStorage(wrappedValue: false, "timerRunning-\(suffix)")
        _timerStartedAt = AppStorage(wrappedValue: 0, "timerStartedAt-\(suffix)")
        _accumulatedSeconds = AppStorage(wrappedValue: 0, "timerAccumulated-\(suffix)")
    }

    private var readingMode: WatchReadingMode {
        WatchReadingMode(rawValue: readingModeRaw) ?? .focus
    }

    var body: some View {
        Group {
            if hasStarted { classContent } else { startView }
        }
        .navigationTitle(script.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasStarted {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchClassNavigatorView(
                            script: script,
                            selectedSection: $selectedSection,
                            showNextCueHint: $showNextCueHint,
                            audioFollowEnabled: Binding(
                                get: { audioFollowEnabled },
                                set: { setAudioFollow($0) }
                            ),
                            audioAutoAdvanceEnabled: Binding(
                                get: { audioAutoAdvanceEnabled },
                                set: { setAutoAdvance($0) }
                            ),
                            audioSkipAlertsEnabled: Binding(
                                get: { audioSkipAlertsEnabled },
                                set: { setSkipAlerts($0) }
                            ),
                            audioMessage: watchStore.audioMessage,
                            audioConfidence: watchStore.audioConfidence,
                            readingMode: readingMode,
                            timerRunning: timerRunning,
                            switchMode: switchMode,
                            toggleTimer: toggleTimer,
                            locateMe: locateMe,
                            requestEndClass: { showingEndConfirmation = true }
                        )
                    } label: {
                        Image(systemName: "list.bullet.circle")
                    }
                }
            }
        }
        .confirmationDialog("End this class?", isPresented: $showingEndConfirmation) {
            Button("End Class", role: .destructive, action: endClass)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The timer and choreography position will reset.")
        }
        .alert(item: $watchStore.audioSuggestion) { suggestion in
            Alert(
                title: Text("Likely Location"),
                message: Text(locateMessage(suggestion)),
                primaryButton: .default(Text("Jump Here")) {
                    watchStore.acceptLocateSuggestion()
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: $watchStore.skippedSectionAlert) { alert in
            Alert(
                title: Text("Possible Skipped Section"),
                message: Text("Audio sounds like \(alert.detectedSectionHeading). Did you skip \(alert.skippedSectionHeading)?"),
                primaryButton: .default(Text("Review Section")) {
                    watchStore.reviewSkippedSection()
                },
                secondaryButton: .cancel(Text("Dismiss")) {
                    watchStore.dismissSkippedSectionAlert()
                }
            )
        }
        .onAppear {
            selectedSection = min(savedSection, max(0, script.sections.count - 1))
        }
        .onChange(of: selectedSection) { _, newValue in
            savedSection = newValue
            reportAudioPosition(sectionIndex: newValue, cueIndex: savedCueIndex(for: newValue))
        }
        .onChange(of: watchStore.audioTarget) { _, target in
            guard let target else { return }
            applyAudioTarget(target)
        }
    }

    private var startView: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "figure.barre")
                    .font(.title2)
                    .foregroundStyle(.tint)

                Text(script.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(startSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Reading Mode", selection: $readingModeRaw) {
                    ForEach(WatchReadingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.navigationLink)

                NavigationLink {
                    WatchQuickReferenceView(script: script)
                } label: {
                    HStack(alignment: .center, spacing: 7) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 18)
                        Text("Quick Reference")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                Button("Start Class", action: startClass)
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var startSummary: String {
        var values = [script.classType.displayName, "\(script.sections.count) sections"]
        if let minutes = script.plannedDurationMinutes {
            values.append("\(minutes) min")
        }
        return values.joined(separator: " • ")
    }

    private var classContent: some View {
        TabView(selection: $selectedSection) {
            ForEach(Array(script.sections.enumerated()), id: \.element.id) { index, section in
                Group {
                    switch readingMode {
                    case .focus:
                        WatchFocusSectionView(
                            scriptID: script.id,
                            sectionIndex: index,
                            section: section,
                            timerRunning: timerRunning,
                            timerStartedAt: timerStartedAt,
                            accumulatedSeconds: accumulatedSeconds,
                            showNextCueHint: showNextCueHint,
                            audioReportingEnabled: audioFollowEnabled
                        )
                    case .continuous:
                        WatchContinuousSectionView(
                            scriptID: script.id,
                            sectionIndex: index,
                            section: section,
                            timerRunning: timerRunning,
                            timerStartedAt: timerStartedAt,
                            accumulatedSeconds: accumulatedSeconds,
                            audioReportingEnabled: audioFollowEnabled
                        )
                    }
                }
                .tag(index)
            }
        }
        #if os(watchOS)
        .tabViewStyle(.verticalPage)
        #else
        .tabViewStyle(.page)
        #endif
    }

    private func startClass() {
        for section in script.sections {
            let suffix = "\(script.id.uuidString)-\(section.id.uuidString)"
            UserDefaults.standard.removeObject(forKey: "cue-\(suffix)")
            UserDefaults.standard.removeObject(forKey: "focusCue-\(suffix)")
        }
        selectedSection = 0
        savedSection = 0
        accumulatedSeconds = 0
        timerStartedAt = Date().timeIntervalSince1970
        timerRunning = true
        hasStarted = true
        if audioFollowEnabled {
            watchStore.startAudioFollow(
                scriptID: script.id,
                sectionIndex: 0,
                cueIndex: 0,
                elapsedSeconds: 0,
                autoAdvance: audioAutoAdvanceEnabled,
                skipAlertsEnabled: audioSkipAlertsEnabled
            )
        }
    }

    private func toggleTimer() {
        if timerRunning {
            accumulatedSeconds += max(0, Date().timeIntervalSince1970 - timerStartedAt)
            timerRunning = false
        } else {
            timerStartedAt = Date().timeIntervalSince1970
            timerRunning = true
        }
    }

    private func endClass() {
        if audioFollowEnabled { watchStore.stopAudioFollow(scriptID: script.id) }
        hasStarted = false
        timerRunning = false
        timerStartedAt = 0
        accumulatedSeconds = 0
        selectedSection = 0
        savedSection = 0
    }

    private func switchMode(to newMode: WatchReadingMode) {
        guard newMode != readingMode,
              script.sections.indices.contains(selectedSection) else { return }

        let section = script.sections[selectedSection]
        let suffix = "\(script.id.uuidString)-\(section.id.uuidString)"
        let cueIDs = section.combinations.flatMap { $0.cues.map(\.id) }

        if newMode == .focus,
           let savedID = UUID(uuidString: UserDefaults.standard.string(forKey: "cue-\(suffix)") ?? ""),
           let index = cueIDs.firstIndex(of: savedID) {
            UserDefaults.standard.set(index, forKey: "focusCue-\(suffix)")
        } else if newMode == .continuous {
            let index = UserDefaults.standard.integer(forKey: "focusCue-\(suffix)")
            if cueIDs.indices.contains(index) {
                UserDefaults.standard.set(cueIDs[index].uuidString, forKey: "cue-\(suffix)")
            }
        }

        readingModeRaw = newMode.rawValue
    }

    private func setAudioFollow(_ enabled: Bool) {
        audioFollowEnabled = enabled
        if enabled {
            watchStore.startAudioFollow(
                scriptID: script.id,
                sectionIndex: selectedSection,
                cueIndex: savedCueIndex(for: selectedSection),
                elapsedSeconds: elapsedClassSeconds,
                autoAdvance: audioAutoAdvanceEnabled,
                skipAlertsEnabled: audioSkipAlertsEnabled
            )
        } else {
            audioAutoAdvanceEnabled = false
            watchStore.stopAudioFollow(scriptID: script.id)
        }
    }

    private func setAutoAdvance(_ enabled: Bool) {
        audioAutoAdvanceEnabled = enabled
        reportAudioPosition(sectionIndex: selectedSection, cueIndex: savedCueIndex(for: selectedSection))
    }

    private func setSkipAlerts(_ enabled: Bool) {
        audioSkipAlertsEnabled = enabled
        if !enabled { watchStore.dismissSkippedSectionAlert() }
        reportAudioPosition(sectionIndex: selectedSection, cueIndex: savedCueIndex(for: selectedSection))
    }

    private func locateMe() {
        watchStore.locateMe(scriptID: script.id, elapsedSeconds: timerRunning || accumulatedSeconds > 0 ? elapsedClassSeconds : nil)
    }

    private var elapsedClassSeconds: TimeInterval {
        accumulatedSeconds + (timerRunning ? max(0, Date().timeIntervalSince1970 - timerStartedAt) : 0)
    }

    private func savedCueIndex(for sectionIndex: Int) -> Int {
        guard script.sections.indices.contains(sectionIndex) else { return 0 }
        let section = script.sections[sectionIndex]
        return UserDefaults.standard.integer(forKey: "focusCue-\(script.id.uuidString)-\(section.id.uuidString)")
    }

    private func reportAudioPosition(sectionIndex: Int, cueIndex: Int) {
        guard audioFollowEnabled, hasStarted else { return }
        watchStore.updateAudioPosition(
            scriptID: script.id,
            sectionIndex: sectionIndex,
            cueIndex: cueIndex,
            elapsedSeconds: timerRunning || accumulatedSeconds > 0 ? elapsedClassSeconds : nil,
            autoAdvance: audioAutoAdvanceEnabled,
            skipAlertsEnabled: audioSkipAlertsEnabled
        )
    }

    private func applyAudioTarget(_ target: WatchAudioTarget) {
        guard script.sections.indices.contains(target.sectionIndex) else { return }
        let section = script.sections[target.sectionIndex]
        let cueIDs = section.combinations.flatMap { $0.cues.map(\.id) }
        let cueIndex = min(max(0, target.cueIndex), max(0, cueIDs.count - 1))
        let suffix = "\(script.id.uuidString)-\(section.id.uuidString)"
        UserDefaults.standard.set(cueIndex, forKey: "focusCue-\(suffix)")
        if cueIDs.indices.contains(cueIndex) {
            UserDefaults.standard.set(cueIDs[cueIndex].uuidString, forKey: "cue-\(suffix)")
        }
        selectedSection = target.sectionIndex
        reportAudioPosition(sectionIndex: target.sectionIndex, cueIndex: cueIndex)
    }

    private func locateMessage(_ suggestion: WatchAudioSuggestion) -> String {
        let percent = Int((suggestion.confidence * 100).rounded())
        let combination = suggestion.combinationTitle.flatMap { $0.isEmpty ? nil : $0 }
        return [
            suggestion.sectionHeading,
            combination,
            "Cue \(suggestion.cueIndex + 1) • \(percent)%",
            suggestion.cueText
        ].compactMap { $0 }.joined(separator: "\n")
    }
}

private struct WatchClassNavigatorView: View {
    let script: ChoreographyScript
    @Binding var selectedSection: Int
    @Binding var showNextCueHint: Bool
    @Binding var audioFollowEnabled: Bool
    @Binding var audioAutoAdvanceEnabled: Bool
    @Binding var audioSkipAlertsEnabled: Bool
    let audioMessage: String
    let audioConfidence: Double?
    let readingMode: WatchReadingMode
    let timerRunning: Bool
    let switchMode: (WatchReadingMode) -> Void
    let toggleTimer: () -> Void
    let locateMe: () -> Void
    let requestEndClass: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Jump to Section") {
                ForEach(Array(script.sections.enumerated()), id: \.element.id) { index, section in
                    Button {
                        selectedSection = index
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.heading)
                                    .font(.body.weight(.semibold))
                                Text(sectionSummary(section))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if selectedSection == index {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section("Reading Mode") {
                Button {
                    switchMode(.focus)
                } label: {
                    Label("Focus", systemImage: readingMode == .focus ? "checkmark" : "textformat")
                }

                Button {
                    switchMode(.continuous)
                } label: {
                    Label("Continuous", systemImage: readingMode == .continuous ? "checkmark" : "scroll")
                }
            }

            Section("Display") {
                Toggle("Show Next Cue", isOn: $showNextCueHint)
            }

            Section("Audio Follow") {
                Toggle("Listen on iPhone", isOn: $audioFollowEnabled)
                Toggle("Auto Advance", isOn: $audioAutoAdvanceEnabled)
                    .disabled(!audioFollowEnabled)
                Toggle("Skipped Section Alerts", isOn: $audioSkipAlertsEnabled)
                    .disabled(!audioFollowEnabled)
                Button(action: locateMe) {
                    Label("Locate Me", systemImage: "location.magnifyingglass")
                }
                .disabled(!audioFollowEnabled)

                HStack {
                    Text(audioMessage)
                    Spacer()
                    if let audioConfidence {
                        Text("\(Int((audioConfidence * 100).rounded()))%")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Section("Class") {
                Button(action: toggleTimer) {
                    Label(timerRunning ? "Pause Timer" : "Resume Timer", systemImage: timerRunning ? "pause" : "play")
                }

                Button(role: .destructive) {
                    requestEndClass()
                    dismiss()
                } label: {
                    Label("End Class", systemImage: "stop.fill")
                }
            }
        }
        .navigationTitle("Sections")
    }
}

private struct WatchQuickReferenceView: View {
    let script: ChoreographyScript
    @AppStorage("showNextCueHint") private var showNextCueHint = false

    var body: some View {
        List {
            ForEach(Array(script.sections.enumerated()), id: \.element.id) { index, section in
                NavigationLink {
                    WatchFocusSectionView(
                        scriptID: script.id,
                        sectionIndex: index,
                        section: section,
                        timerRunning: false,
                        timerStartedAt: 0,
                        accumulatedSeconds: 0,
                        showNextCueHint: showNextCueHint,
                        audioReportingEnabled: false,
                        allowsCueScrolling: true
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.heading)
                            .font(.body.weight(.semibold))
                        Text(sectionSummary(section))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Quick Reference")
    }
}

private func sectionSummary(_ section: ChoreographySection) -> String {
    let cueCount = section.combinations.reduce(0) { $0 + $1.cues.count }
    let cueLabel = cueCount == 1 ? "cue" : "cues"
    if let song = section.song, !song.isEmpty {
        return "\(cueCount) \(cueLabel) • \(song)"
    }
    return "\(cueCount) \(cueLabel)"
}

private struct ClassTimerLabel: View {
    let timerRunning: Bool
    let timerStartedAt: Double
    let accumulatedSeconds: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formattedElapsed(at: context.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(timerRunning ? .primary : .secondary)
                .accessibilityLabel("Class time \(formattedElapsed(at: context.date))")
        }
    }

    private func formattedElapsed(at date: Date) -> String {
        let liveSeconds = timerRunning ? max(0, date.timeIntervalSince1970 - timerStartedAt) : 0
        let total = max(0, Int(accumulatedSeconds + liveSeconds))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct WatchFocusSectionView: View {
    let scriptID: UUID
    let sectionIndex: Int
    let section: ChoreographySection
    let timerRunning: Bool
    let timerStartedAt: Double
    let accumulatedSeconds: Double
    let showNextCueHint: Bool
    let audioReportingEnabled: Bool
    let allowsCueScrolling: Bool

    @EnvironmentObject private var watchStore: WatchScriptStore
    @AppStorage("audioAutoAdvanceEnabled") private var audioAutoAdvanceEnabled = false
    @AppStorage("audioSkipAlertsEnabled") private var audioSkipAlertsEnabled = false
    @FocusState private var crownNavigationFocused: Bool
    @State private var crownPosition: Double = 0
    @State private var repeatReturnCueIndex: Int?
    @AppStorage private var savedCueIndex: Int

    private var cues: [(cue: ChoreographyCue, combinationTitle: String?)] {
        section.combinations.flatMap { combination in
            combination.cues.map { ($0, combination.title) }
        }
    }

    init(
        scriptID: UUID,
        sectionIndex: Int,
        section: ChoreographySection,
        timerRunning: Bool,
        timerStartedAt: Double,
        accumulatedSeconds: Double,
        showNextCueHint: Bool,
        audioReportingEnabled: Bool,
        allowsCueScrolling: Bool = false
    ) {
        self.scriptID = scriptID
        self.sectionIndex = sectionIndex
        self.section = section
        self.timerRunning = timerRunning
        self.timerStartedAt = timerStartedAt
        self.accumulatedSeconds = accumulatedSeconds
        self.showNextCueHint = showNextCueHint
        self.audioReportingEnabled = audioReportingEnabled
        self.allowsCueScrolling = allowsCueScrolling
        _savedCueIndex = AppStorage(wrappedValue: 0, "focusCue-\(scriptID.uuidString)-\(section.id.uuidString)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(section.heading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                Spacer(minLength: 2)
                AudioListeningIndicator()
                ClassTimerLabel(
                    timerRunning: timerRunning,
                    timerStartedAt: timerStartedAt,
                    accumulatedSeconds: accumulatedSeconds
                )
            }

            if cues.isEmpty {
                ContentUnavailableView("No Cues", systemImage: "text.badge.xmark")
            } else {
                let safeIndex = min(max(0, savedCueIndex), cues.count - 1)
                WatchFocusContextLine(
                    section: section,
                    combinationTitle: cues[safeIndex].combinationTitle
                )

                if allowsCueScrolling {
                    ScrollView(.vertical) {
                        cueRow(cues[safeIndex].cue, at: safeIndex, scrollable: true)
                    }
                    .id(cues[safeIndex].cue.id)
                    .scrollIndicators(.visible)
                    .focusable(false)
                } else {
                    cueRow(cues[safeIndex].cue, at: safeIndex, scrollable: false)
                }

                if showNextCueHint, cues.indices.contains(safeIndex + 1) {
                    HStack(alignment: .top, spacing: 5) {
                        Text("NEXT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tint)
                        Text(cuePreviewText(cues[safeIndex + 1].cue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Up next, \(cuePreviewText(cues[safeIndex + 1].cue))")
                }

                HStack {
                    Text("Cue \(safeIndex + 1) of \(cues.count)")
                    Spacer()
                    if let returnIndex = repeatReturnCueIndex {
                        Button {
                            move(to: returnIndex)
                            repeatReturnCueIndex = nil
                        } label: {
                            Image(systemName: "arrow.uturn.forward.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Return to repeat instruction")
                    }
                    Image(systemName: "digitalcrown.horizontal.arrow.clockwise")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .focusable()
        .focused($crownNavigationFocused)
        .digitalCrownRotation(
            $crownPosition,
            from: 0,
            through: Double(max(0, cues.count - 1)),
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            savedCueIndex = min(max(0, savedCueIndex), max(0, cues.count - 1))
            crownPosition = Double(savedCueIndex)
            claimCrownNavigationFocus()
        }
        .onChange(of: crownPosition) { _, newValue in
            savedCueIndex = min(max(0, Int(newValue.rounded())), max(0, cues.count - 1))
            reportPosition()
        }
        .onChange(of: watchStore.audioTarget) { _, target in
            guard audioReportingEnabled,
                  let target,
                  target.sectionIndex == sectionIndex else { return }
            let cueIndex = min(max(0, target.cueIndex), max(0, cues.count - 1))
            savedCueIndex = cueIndex
            crownPosition = Double(cueIndex)
            claimCrownNavigationFocus()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                claimCrownNavigationFocus()
            }
        )
    }

    private func reportPosition() {
        guard audioReportingEnabled else { return }
        let elapsed = accumulatedSeconds
            + (timerRunning ? max(0, Date().timeIntervalSince1970 - timerStartedAt) : 0)
        watchStore.updateAudioPosition(
            scriptID: scriptID,
            sectionIndex: sectionIndex,
            cueIndex: savedCueIndex,
            elapsedSeconds: elapsed,
            autoAdvance: audioAutoAdvanceEnabled,
            skipAlertsEnabled: audioSkipAlertsEnabled
        )
    }

    @ViewBuilder
    private func cueRow(_ cue: ChoreographyCue, at cueIndex: Int, scrollable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 5) {
                if let marker = cue.listMarker {
                    Text(marker)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                }
                if cue.kind != .choreography {
                    Image(systemName: cue.kind.systemImage)
                        .foregroundStyle(cue.kind.tint)
                }
                Text(cue.shortText ?? cue.text)
                    .font(.body.weight(.medium))
                    .minimumScaleFactor(scrollable ? 1 : 0.72)
                    .lineLimit(scrollable ? nil : (showNextCueHint ? 5 : 8))
                    .fixedSize(horizontal: false, vertical: scrollable)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: scrollable ? nil : .infinity,
                        alignment: .leading
                    )
            }

            if let targetIndex = repeatTargetIndex(for: cue), targetIndex != cueIndex {
                Button {
                    repeatReturnCueIndex = cueIndex
                    move(to: targetIndex)
                } label: {
                    Label("Repeat from top", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .accessibilityHint("Jumps to the beginning of the repeated combination")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func repeatTargetIndex(for cue: ChoreographyCue) -> Int? {
        guard cue.kind == .repeatInstruction, let targetID = cue.repeatTargetCueID else { return nil }
        return cues.firstIndex { $0.cue.id == targetID }
    }

    private func move(to cueIndex: Int) {
        let safeIndex = min(max(0, cueIndex), max(0, cues.count - 1))
        savedCueIndex = safeIndex
        crownPosition = Double(safeIndex)
        reportPosition()
        claimCrownNavigationFocus()
    }

    private func claimCrownNavigationFocus() {
        DispatchQueue.main.async {
            crownNavigationFocused = true
        }
    }
}

private struct AudioListeningIndicator: View {
    @EnvironmentObject private var store: WatchScriptStore
    @AppStorage("audioFollowEnabled") private var enabled = false

    var body: some View {
        if enabled {
            Image(systemName: store.audioState == "listening" ? "mic.fill" : "mic")
                .font(.caption2)
                .foregroundStyle(store.audioState == "listening" ? .green : .orange)
                .accessibilityLabel(store.audioMessage)
        }
    }
}

private struct WatchFocusContextLine: View {
    let section: ChoreographySection
    let combinationTitle: String?

    var body: some View {
        HStack(spacing: 5) {
            if let song = section.song, !song.isEmpty {
                Label(song, systemImage: "music.note")
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let combinationTitle, !combinationTitle.isEmpty {
                Text(combinationTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let equipment = section.equipment, !equipment.isEmpty {
                Label(equipment, systemImage: "dumbbell")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let option = section.option, !option.isEmpty {
                Label(option, systemImage: "arrow.triangle.branch")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct WatchContinuousSectionView: View {
    let scriptID: UUID
    let sectionIndex: Int
    let section: ChoreographySection
    let timerRunning: Bool
    let timerStartedAt: Double
    let accumulatedSeconds: Double
    let audioReportingEnabled: Bool

    @EnvironmentObject private var watchStore: WatchScriptStore
    @AppStorage("audioAutoAdvanceEnabled") private var audioAutoAdvanceEnabled = false
    @AppStorage("audioSkipAlertsEnabled") private var audioSkipAlertsEnabled = false
    @State private var scrollPosition: UUID?
    @State private var repeatReturnCueID: UUID?
    @AppStorage private var savedCueID: String

    init(
        scriptID: UUID,
        sectionIndex: Int,
        section: ChoreographySection,
        timerRunning: Bool,
        timerStartedAt: Double,
        accumulatedSeconds: Double,
        audioReportingEnabled: Bool
    ) {
        self.scriptID = scriptID
        self.sectionIndex = sectionIndex
        self.section = section
        self.timerRunning = timerRunning
        self.timerStartedAt = timerStartedAt
        self.accumulatedSeconds = accumulatedSeconds
        self.audioReportingEnabled = audioReportingEnabled
        _savedCueID = AppStorage(wrappedValue: "", "cue-\(scriptID.uuidString)-\(section.id.uuidString)")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(section.heading)
                        .font(.headline)
                        .foregroundStyle(.tint)
                    Spacer(minLength: 2)
                    ClassTimerLabel(
                        timerRunning: timerRunning,
                        timerStartedAt: timerStartedAt,
                        accumulatedSeconds: accumulatedSeconds
                    )
                }

                WatchSectionMetadata(section: section)

                ForEach(section.combinations) { combination in
                    if let title = combination.title {
                        Text(title).font(.headline).padding(.top, 4)
                    }
                    ForEach(combination.cues) { cue in
                        WatchCueRow(cue: cue) {
                            guard let targetID = cue.repeatTargetCueID,
                                  sectionContainsCue(targetID) else { return }
                            repeatReturnCueID = cue.id
                            scrollPosition = targetID
                        }
                            .id(cue.id)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrollPosition, anchor: .top)
        .focusable()
        .overlay(alignment: .bottomTrailing) {
            if let returnID = repeatReturnCueID {
                Button {
                    scrollPosition = returnID
                    repeatReturnCueID = nil
                } label: {
                    Image(systemName: "arrow.uturn.forward.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .accessibilityLabel("Return to repeat instruction")
            }
        }
        .onAppear {
            if let id = UUID(uuidString: savedCueID) { scrollPosition = id }
        }
        .onChange(of: scrollPosition) { _, newValue in
            savedCueID = newValue?.uuidString ?? ""
            reportPosition(for: newValue)
        }
        .onChange(of: watchStore.audioTarget) { _, target in
            guard audioReportingEnabled,
                  let target,
                  target.sectionIndex == sectionIndex else { return }
            let cueIDs = section.combinations.flatMap { $0.cues.map(\.id) }
            guard cueIDs.indices.contains(target.cueIndex) else { return }
            scrollPosition = cueIDs[target.cueIndex]
        }
    }

    private func reportPosition(for cueID: UUID?) {
        guard audioReportingEnabled, let cueID else { return }
        let cueIDs = section.combinations.flatMap { $0.cues.map(\.id) }
        guard let cueIndex = cueIDs.firstIndex(of: cueID) else { return }
        let elapsed = accumulatedSeconds
            + (timerRunning ? max(0, Date().timeIntervalSince1970 - timerStartedAt) : 0)
        watchStore.updateAudioPosition(
            scriptID: scriptID,
            sectionIndex: sectionIndex,
            cueIndex: cueIndex,
            elapsedSeconds: elapsed,
            autoAdvance: audioAutoAdvanceEnabled,
            skipAlertsEnabled: audioSkipAlertsEnabled
        )
    }

    private func sectionContainsCue(_ cueID: UUID) -> Bool {
        section.combinations.contains { combination in
            combination.cues.contains { $0.id == cueID }
        }
    }
}

private struct WatchSectionMetadata: View {
    let section: ChoreographySection

    var body: some View {
        if section.song != nil || section.equipment != nil || section.option != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let song = section.song {
                    Label(song, systemImage: "music.note")
                }
                if let equipment = section.equipment {
                    Label(equipment, systemImage: "dumbbell")
                }
                if let option = section.option {
                    Label(option, systemImage: "arrow.triangle.branch")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

private struct WatchCueRow: View {
    let cue: ChoreographyCue
    let repeatAction: (() -> Void)?

    init(cue: ChoreographyCue, repeatAction: (() -> Void)? = nil) {
        self.cue = cue
        self.repeatAction = cue.kind == .repeatInstruction && cue.repeatTargetCueID != nil ? repeatAction : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 5) {
                if let marker = cue.listMarker {
                    Text(marker)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                }
                if cue.kind != .choreography {
                    Image(systemName: cue.kind.systemImage)
                        .foregroundStyle(cue.kind.tint)
                }
                Text(cue.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let repeatAction {
                Button(action: repeatAction) {
                    Label("Repeat from top", systemImage: "arrow.uturn.backward.circle.fill")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
            }
        }
        .padding(cue.kind == .choreography ? 0 : 6)
        .background(cue.kind.tint.opacity(cue.kind == .choreography ? 0 : 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private func cuePreviewText(_ cue: ChoreographyCue) -> String {
    let text = cue.shortText ?? cue.text
    guard let marker = cue.listMarker else { return text }
    return "\(marker) \(text)"
}

private extension ChoreographyCueKind {
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

    var tint: Color {
        switch self {
        case .choreography: .primary
        case .setup: .blue
        case .equipment: .purple
        case .song: .orange
        case .option: .cyan
        case .transition: .mint
        case .repeatInstruction: .pink
        }
    }
}
