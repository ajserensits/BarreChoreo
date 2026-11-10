import Foundation
import WatchConnectivity

@MainActor
final class PhoneConnectivityManager: NSObject, WCSessionDelegate {
    private var pendingScripts: [ChoreographyScript] = []
    private let contextLimit = 60_000
    private let audioFollower = AudioFollowCoordinator()

    func activate() {
        guard WCSession.isSupported() else { return }
        audioFollower.onEvent = { [weak self] event in self?.sendAudioEvent(event) }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func prepareAudioPermissions(completion: @escaping (String) -> Void) {
        audioFollower.preparePermissions(completion: completion)
    }

    func sync(scripts: [ChoreographyScript]) {
        pendingScripts = scripts
        sendIfReady()
    }

    private func sendIfReady() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let watchScripts = pendingScripts.map { script in
            var copy = script
            copy.originalText = ""
            copy.originalSections = []
            return copy
        }
        guard let data = try? SharedCodec.encoder.encode(watchScripts) else { return }

        do {
            if data.count <= contextLimit {
                try session.updateApplicationContext(["scripts": data])
            }

            if session.isReachable {
                session.sendMessage(["scripts": data], replyHandler: nil) { error in
                    print("Immediate Watch sync failed: \(error.localizedDescription)")
                }
            }

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BarreWatchTransfers", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent("scripts-\(UUID().uuidString).json")
            try data.write(to: fileURL, options: .atomic)
            session.transferFile(fileURL, metadata: ["kind": "scripts"])
        } catch {
            print("Watch sync failed: \(error.localizedDescription)")
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.sendIfReady() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        if let error {
            print("Watch file transfer failed: \(error.localizedDescription)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handleAudioCommand(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.handleAudioCommand(userInfo) }
    }

    private func handleAudioCommand(_ message: [String: Any]) {
        guard let command = message["audioCommand"] as? String else { return }
        let sectionIndex = message["sectionIndex"] as? Int ?? 0
        let cueIndex = message["cueIndex"] as? Int ?? 0
        let rawElapsed = message["elapsedSeconds"] as? Double ?? -1
        let elapsed: TimeInterval? = rawElapsed >= 0 ? rawElapsed : nil
        let autoAdvance = message["autoAdvance"] as? Bool ?? false
        let skipAlertsEnabled = message["skipAlertsEnabled"] as? Bool ?? false

        switch command {
        case "start":
            guard let idString = message["scriptID"] as? String,
                  let id = UUID(uuidString: idString),
                  let script = pendingScripts.first(where: { $0.id == id }) else {
                sendAudioEvent(["audioEvent": "status", "audioState": "error", "message": "Class is not synced to iPhone"])
                return
            }
            audioFollower.start(
                script: script,
                sectionIndex: sectionIndex,
                cueIndex: cueIndex,
                elapsedSeconds: elapsed,
                autoAdvance: autoAdvance,
                skipAlertsEnabled: skipAlertsEnabled
            )
        case "position":
            audioFollower.updatePosition(
                sectionIndex: sectionIndex,
                cueIndex: cueIndex,
                elapsedSeconds: elapsed,
                autoAdvance: autoAdvance,
                skipAlertsEnabled: skipAlertsEnabled
            )
        case "locate":
            audioFollower.locate(elapsedSeconds: elapsed)
        case "stop":
            audioFollower.stop()
        default:
            break
        }
    }

    private func sendAudioEvent(_ event: [String: Any]) {
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(event, replyHandler: nil) { error in
                print("Audio Follow update failed: \(error.localizedDescription)")
            }
        } else if event["audioEvent"] as? String != "suggestion" {
            session.transferUserInfo(event)
        }
    }
}

