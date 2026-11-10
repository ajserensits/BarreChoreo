import AVFAudio
import Foundation
import Speech

@MainActor
final class AudioFollowCoordinator: NSObject {
    var onEvent: (([String: Any]) -> Void)?

    private let matcher = AudioFollowingMatcher()
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var script: ChoreographyScript?
    private var currentSectionIndex = 0
    private var currentCueIndex = 0
    private var elapsedSeconds: TimeInterval?
    private var autoAdvance = false
    private var skipAlertsEnabled = false
    private var history: [(text: String, confidence: Double, date: Date)] = []
    private var partialEvidence: AudioTranscriptEvidence?
    private var repeatedCandidate: AudioCueLocation?
    private var repeatedCandidateCount = 0
    private var skipCandidateSectionIndex: Int?
    private var skipCandidateCount = 0
    private var skipCandidateLastObservedAt: Date?
    private var lastSkipAlertedSectionIndex: Int?
    private var shouldBeListening = false
    private var hasInputTap = false

    func preparePermissions(completion: @escaping (String) -> Void) {
        Task {
            let speech = await requestSpeechPermission()
            let microphone = await requestMicrophonePermission()
            if speech && microphone {
                completion("Audio Follow is ready. Start it from the Watch during class.")
            } else {
                completion("Enable Microphone and Speech Recognition for Barre Scripts in iPhone Settings.")
            }
        }
    }

    func start(
        script: ChoreographyScript,
        sectionIndex: Int,
        cueIndex: Int,
        elapsedSeconds: TimeInterval?,
        autoAdvance: Bool,
        skipAlertsEnabled: Bool
    ) {
        self.script = script
        self.currentSectionIndex = sectionIndex
        self.currentCueIndex = cueIndex
        self.elapsedSeconds = elapsedSeconds
        self.autoAdvance = autoAdvance
        self.skipAlertsEnabled = skipAlertsEnabled
        resetSkipDetection(clearLastAlert: true)
        shouldBeListening = true

        Task {
            guard await requestSpeechPermission(), await requestMicrophonePermission() else {
                emitStatus("Permission needed on iPhone", state: "permissionRequired")
                return
            }
            do {
                try beginRecognition()
                emitStatus("Listening on iPhone", state: "listening")
            } catch {
                emitStatus("Could not start listening", state: "error")
            }
        }
    }

    func updatePosition(
        sectionIndex: Int,
        cueIndex: Int,
        elapsedSeconds: TimeInterval?,
        autoAdvance: Bool,
        skipAlertsEnabled: Bool
    ) {
        let sectionChanged = sectionIndex != currentSectionIndex
        currentSectionIndex = sectionIndex
        currentCueIndex = cueIndex
        self.elapsedSeconds = elapsedSeconds
        self.autoAdvance = autoAdvance
        self.skipAlertsEnabled = skipAlertsEnabled
        repeatedCandidate = nil
        repeatedCandidateCount = 0
        if sectionChanged || !skipAlertsEnabled {
            resetSkipDetection(clearLastAlert: sectionChanged)
        }
    }

    func locate(elapsedSeconds: TimeInterval?) {
        self.elapsedSeconds = elapsedSeconds
        guard let script else {
            emitStatus("Start Audio Follow first", state: "error")
            return
        }
        let result = matcher.match(
            evidence: currentEvidence(),
            script: script,
            currentSectionIndex: currentSectionIndex,
            currentCueIndex: currentCueIndex,
            elapsedSeconds: elapsedSeconds,
            scope: .locate
        )
        guard let result,
              result.confidence >= 0.34,
              result.confidence - result.runnerUpConfidence >= 0.025 else {
            emitStatus("Not enough speech to locate yet", state: "listening")
            return
        }
        emit(event: "locate", result: result)
    }

    func stop() {
        shouldBeListening = false
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTapIfNeeded()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        history.removeAll()
        partialEvidence = nil
        repeatedCandidate = nil
        repeatedCandidateCount = 0
        resetSkipDetection(clearLastAlert: true)
        emitStatus("Off", state: "off")
    }

    private func beginRecognition() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning { audioEngine.stop() }
        removeInputTapIfNeeded()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw AudioFollowError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
        request.contextualStrings = contextualPhrases()
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        hasInputTap = true
        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.consume(result)
                }
                if (result?.isFinal == true || error != nil), self.shouldBeListening {
                    try? self.beginRecognition()
                }
            }
        }
    }

    private func removeInputTapIfNeeded() {
        guard hasInputTap else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        hasInputTap = false
    }

    private func consume(_ result: SFSpeechRecognitionResult) {
        let transcription = result.bestTranscription
        let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let recentSegments = transcription.segments.suffix(8)
        let confidence = recentSegments.isEmpty
            ? 0.5
            : recentSegments.reduce(0.0) { $0 + Double($1.confidence) } / Double(recentSegments.count)
        partialEvidence = .init(text: text, confidence: confidence, ageSeconds: 0)

        if result.isFinal {
            history.append((text, confidence, Date()))
            partialEvidence = nil
            trimHistory()
        }
        evaluateFollow()
    }

    private func evaluateFollow() {
        guard let script else { return }
        let evidence = currentEvidence()
        if skipAlertsEnabled {
            evaluateSkippedSection(in: script, evidence: evidence)
        }

        guard let result = matcher.match(
                evidence: evidence,
                script: script,
                currentSectionIndex: currentSectionIndex,
                currentCueIndex: currentCueIndex,
                elapsedSeconds: elapsedSeconds,
                scope: .follow
              ) else { return }

        if result.confidence >= 0.42 {
            emit(event: "suggestion", result: result)
        }

        let isForward = result.location.sectionIndex > currentSectionIndex
            || (result.location.sectionIndex == currentSectionIndex && result.location.cueIndex > currentCueIndex)
        guard autoAdvance,
              isForward,
              result.confidence >= 0.78,
              result.confidence - result.runnerUpConfidence >= 0.10 else {
            repeatedCandidate = nil
            repeatedCandidateCount = 0
            return
        }

        if repeatedCandidate == result.location {
            repeatedCandidateCount += 1
        } else {
            repeatedCandidate = result.location
            repeatedCandidateCount = 1
        }
        if repeatedCandidateCount >= 2 {
            emit(event: "advance", result: result)
            currentSectionIndex = result.location.sectionIndex
            currentCueIndex = result.location.cueIndex
            repeatedCandidate = nil
            repeatedCandidateCount = 0
        }
    }

    private func evaluateSkippedSection(in script: ChoreographyScript, evidence: [AudioTranscriptEvidence]) {
        guard currentSectionIndex + 2 < script.sections.count,
              let result = matcher.match(
                evidence: evidence,
                script: script,
                currentSectionIndex: currentSectionIndex,
                currentCueIndex: currentCueIndex,
                elapsedSeconds: elapsedSeconds,
                scope: .skipDetection
              ),
              result.confidence >= 0.72,
              result.confidence - result.runnerUpConfidence >= 0.08 else {
            resetSkipDetection(clearLastAlert: false)
            return
        }

        let skippedSectionIndex = currentSectionIndex + 1
        guard skippedSectionIndex != lastSkipAlertedSectionIndex else { return }

        let now = Date()
        if skipCandidateSectionIndex == result.location.sectionIndex {
            if let lastObservation = skipCandidateLastObservedAt,
               now.timeIntervalSince(lastObservation) >= 1.25 {
                skipCandidateCount += 1
                skipCandidateLastObservedAt = now
            }
        } else {
            skipCandidateSectionIndex = result.location.sectionIndex
            skipCandidateCount = 1
            skipCandidateLastObservedAt = now
        }

        guard skipCandidateCount >= 2 else { return }
        let skippedSection = script.sections[skippedSectionIndex]
        onEvent?([
            "audioEvent": "skippedSection",
            "skippedSectionIndex": skippedSectionIndex,
            "skippedSectionHeading": skippedSection.heading,
            "detectedSectionIndex": result.location.sectionIndex,
            "detectedSectionHeading": result.location.sectionHeading,
            "confidence": result.confidence
        ])
        lastSkipAlertedSectionIndex = skippedSectionIndex
        resetSkipDetection(clearLastAlert: false)
    }

    private func resetSkipDetection(clearLastAlert: Bool) {
        skipCandidateSectionIndex = nil
        skipCandidateCount = 0
        skipCandidateLastObservedAt = nil
        if clearLastAlert { lastSkipAlertedSectionIndex = nil }
    }

    private func currentEvidence() -> [AudioTranscriptEvidence] {
        trimHistory()
        let now = Date()
        var evidence = history.map {
            AudioTranscriptEvidence(text: $0.text, confidence: $0.confidence, ageSeconds: now.timeIntervalSince($0.date))
        }
        if let partialEvidence { evidence.append(partialEvidence) }
        return evidence
    }

    private func trimHistory() {
        let cutoff = Date().addingTimeInterval(-90)
        history.removeAll { $0.date < cutoff }
    }

    private func contextualPhrases() -> [String] {
        guard let script else { return [] }
        var phrases: [String] = []
        for section in script.sections {
            phrases.append(section.heading)
            for combination in section.combinations {
                if let title = combination.title { phrases.append(title) }
                phrases.append(contentsOf: combination.cues.map { String(($0.shortText ?? $0.text).prefix(80)) })
            }
        }
        return Array(phrases.prefix(100))
    }

    private func emit(event: String, result: AudioMatchResult) {
        onEvent?([
            "audioEvent": event,
            "sectionIndex": result.location.sectionIndex,
            "cueIndex": result.location.cueIndex,
            "sectionHeading": result.location.sectionHeading,
            "combinationTitle": result.location.combinationTitle ?? "",
            "cueText": result.location.cueText,
            "confidence": result.confidence
        ])
    }

    private func emitStatus(_ message: String, state: String) {
        onEvent?(["audioEvent": "status", "audioState": state, "message": message])
    }

    private func requestSpeechPermission() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

private enum AudioFollowError: Error {
    case recognizerUnavailable
}
