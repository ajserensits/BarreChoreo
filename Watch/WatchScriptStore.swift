import Foundation
import WatchConnectivity

@MainActor
final class WatchScriptStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var scripts: [ChoreographyScript] = []
    @Published private(set) var audioState = "off"
    @Published private(set) var audioMessage = "Off"
    @Published private(set) var audioConfidence: Double?
    @Published var audioSuggestion: WatchAudioSuggestion?
    @Published var audioTarget: WatchAudioTarget?
    @Published var skippedSectionAlert: WatchSkippedSectionAlert?

    private lazy var storageURL: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("BarreChoreography", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("scripts.json")
    }()

    override init() {
        super.init()
        load()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? SharedCodec.decoder.decode([ChoreographyScript].self, from: data) else { return }
        scripts = decoded.sorted(by: ChoreographyScript.alphabeticallyByTitle)
    }

    private func receive(data: Data) {
        guard let decoded = try? SharedCodec.decoder.decode([ChoreographyScript].self, from: data) else { return }
        Task { @MainActor in
            let sorted = decoded.sorted(by: ChoreographyScript.alphabeticallyByTitle)
            scripts = sorted
            if let sortedData = try? SharedCodec.encoder.encode(sorted) {
                try? sortedData.write(to: storageURL, options: .atomic)
            }
        }
    }

    func startAudioFollow(
        scriptID: UUID,
        sectionIndex: Int,
        cueIndex: Int,
        elapsedSeconds: TimeInterval?,
        autoAdvance: Bool,
        skipAlertsEnabled: Bool
    ) {
        audioState = "connecting"
        audioMessage = "Connecting to iPhone…"
        sendAudioCommand(
            "start",
            scriptID: scriptID,
            sectionIndex: sectionIndex,
            cueIndex: cueIndex,
            elapsedSeconds: elapsedSeconds,
            autoAdvance: autoAdvance,
            skipAlertsEnabled: skipAlertsEnabled
        )
    }

    func stopAudioFollow(scriptID: UUID) {
        sendAudioCommand("stop", scriptID: scriptID)
        audioState = "off"
        audioMessage = "Off"
        audioConfidence = nil
        audioSuggestion = nil
        skippedSectionAlert = nil
    }

    func updateAudioPosition(
        scriptID: UUID,
        sectionIndex: Int,
        cueIndex: Int,
        elapsedSeconds: TimeInterval?,
        autoAdvance: Bool,
        skipAlertsEnabled: Bool
    ) {
        sendAudioCommand(
            "position",
            scriptID: scriptID,
            sectionIndex: sectionIndex,
            cueIndex: cueIndex,
            elapsedSeconds: elapsedSeconds,
            autoAdvance: autoAdvance,
            skipAlertsEnabled: skipAlertsEnabled
        )
    }

    func locateMe(scriptID: UUID, elapsedSeconds: TimeInterval?) {
        audioMessage = "Locating…"
        sendAudioCommand("locate", scriptID: scriptID, elapsedSeconds: elapsedSeconds)
    }

    func acceptLocateSuggestion() {
        guard let suggestion = audioSuggestion else { return }
        audioTarget = .init(
            id: UUID(),
            sectionIndex: suggestion.sectionIndex,
            cueIndex: suggestion.cueIndex
        )
        audioSuggestion = nil
    }

    func reviewSkippedSection() {
        guard let alert = skippedSectionAlert else { return }
        audioTarget = .init(id: UUID(), sectionIndex: alert.skippedSectionIndex, cueIndex: 0)
        skippedSectionAlert = nil
    }

    func dismissSkippedSectionAlert() {
        skippedSectionAlert = nil
    }

    private func sendAudioCommand(
        _ command: String,
        scriptID: UUID,
        sectionIndex: Int = 0,
        cueIndex: Int = 0,
        elapsedSeconds: TimeInterval? = nil,
        autoAdvance: Bool = false,
        skipAlertsEnabled: Bool = false
    ) {
        let message: [String: Any] = [
            "audioCommand": command,
            "scriptID": scriptID.uuidString,
            "sectionIndex": sectionIndex,
            "cueIndex": cueIndex,
            "elapsedSeconds": elapsedSeconds ?? -1,
            "autoAdvance": autoAdvance,
            "skipAlertsEnabled": skipAlertsEnabled
        ]
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { [weak self] error in
                Task { @MainActor in
                    self?.audioState = "error"
                    self?.audioMessage = error.localizedDescription
                }
            }
        } else {
            session.transferUserInfo(message)
            audioState = "waiting"
            audioMessage = "Waiting for iPhone"
        }
    }

    private func receiveAudioEvent(_ event: [String: Any]) {
        guard let kind = event["audioEvent"] as? String else { return }
        let confidence = event["confidence"] as? Double
        audioConfidence = confidence

        switch kind {
        case "status":
            audioState = event["audioState"] as? String ?? "off"
            audioMessage = event["message"] as? String ?? ""
        case "suggestion":
            audioState = "listening"
            audioMessage = "Listening"
        case "advance":
            if let sectionIndex = event["sectionIndex"] as? Int,
               let cueIndex = event["cueIndex"] as? Int {
                audioTarget = .init(id: UUID(), sectionIndex: sectionIndex, cueIndex: cueIndex)
            }
        case "locate":
            if let sectionIndex = event["sectionIndex"] as? Int,
               let cueIndex = event["cueIndex"] as? Int {
                audioSuggestion = .init(
                    id: UUID(),
                    sectionIndex: sectionIndex,
                    cueIndex: cueIndex,
                    sectionHeading: event["sectionHeading"] as? String ?? "Section",
                    combinationTitle: event["combinationTitle"] as? String,
                    cueText: event["cueText"] as? String ?? "Cue \(cueIndex + 1)",
                    confidence: confidence ?? 0
                )
                audioMessage = "Location found"
            }
        case "skippedSection":
            if let skippedSectionIndex = event["skippedSectionIndex"] as? Int,
               let detectedSectionIndex = event["detectedSectionIndex"] as? Int {
                skippedSectionAlert = .init(
                    id: UUID(),
                    skippedSectionIndex: skippedSectionIndex,
                    skippedSectionHeading: event["skippedSectionHeading"] as? String ?? "Section",
                    detectedSectionIndex: detectedSectionIndex,
                    detectedSectionHeading: event["detectedSectionHeading"] as? String ?? "a later section",
                    confidence: confidence ?? 0
                )
                audioMessage = "Possible skipped section"
            }
        default:
            break
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard error == nil, activationState == .activated,
              let data = session.receivedApplicationContext["scripts"] as? Data else { return }
        Task { @MainActor in self.receive(data: data) }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["scripts"] as? Data else { return }
        Task { @MainActor in self.receive(data: data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo["scripts"] as? Data {
            Task { @MainActor in self.receive(data: data) }
        } else if userInfo["audioEvent"] != nil {
            Task { @MainActor in self.receiveAudioEvent(userInfo) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let data = message["scripts"] as? Data {
            Task { @MainActor in self.receive(data: data) }
        } else if message["audioEvent"] != nil {
            Task { @MainActor in self.receiveAudioEvent(message) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["kind"] as? String == "scripts",
              let data = try? Data(contentsOf: file.fileURL) else { return }
        Task { @MainActor in self.receive(data: data) }
    }
}

struct WatchAudioSuggestion: Identifiable, Equatable {
    let id: UUID
    let sectionIndex: Int
    let cueIndex: Int
    let sectionHeading: String
    let combinationTitle: String?
    let cueText: String
    let confidence: Double
}

struct WatchAudioTarget: Identifiable, Equatable {
    let id: UUID
    let sectionIndex: Int
    let cueIndex: Int
}

struct WatchSkippedSectionAlert: Identifiable, Equatable {
    let id: UUID
    let skippedSectionIndex: Int
    let skippedSectionHeading: String
    let detectedSectionIndex: Int
    let detectedSectionHeading: String
    let confidence: Double
}

