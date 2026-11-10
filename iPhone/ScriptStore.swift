import Foundation
import PDFKit

@MainActor
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [ChoreographyScript] = []
    @Published private(set) var pendingImport: ChoreographyScript?
    @Published var importError: String?
    @Published var isImporting = false
    @Published var audioSetupMessage: String?

    private let fileURL: URL
    private let connectivity = PhoneConnectivityManager()

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = applicationSupport.appendingPathComponent("BarreChoreography", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("scripts.json")
        load()
        connectivity.activate()
        connectivity.sync(scripts: watchScripts)
    }

    var watchScripts: [ChoreographyScript] {
        scripts.filter(\.isAvailableOnWatch)
    }

    var watchSyncSummary: String {
        guard !watchScripts.isEmpty else { return "No classes selected for Apple Watch." }
        return "\(watchScripts.count) selected for Apple Watch"
    }

    func prepareImport(from url: URL) async {
        isImporting = true
        defer { isImporting = false }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url) else {
            importError = "That file could not be opened as a PDF."
            return
        }

        let pageText = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let text = pageText.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            importError = "This PDF does not contain selectable text. Scanned-image OCR is not included in the MVP."
            return
        }

        let filename = url.lastPathComponent
        let suggestedTitle = url.deletingPathExtension().lastPathComponent
        pendingImport = ChoreographyParser().parse(text: text, title: suggestedTitle, sourceFilename: filename)
    }

    func savePendingImport(title: String, availableOnWatch: Bool) {
        guard var script = pendingImport else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        script.title = trimmedTitle.isEmpty
            ? URL(fileURLWithPath: script.sourceFilename).deletingPathExtension().lastPathComponent
            : trimmedTitle
        script.isAvailableOnWatch = availableOnWatch
        scripts.insert(script, at: 0)
        scripts.sort(by: ChoreographyScript.alphabeticallyByTitle)
        pendingImport = nil
        persistAndSync()
    }

    func cancelPendingImport() {
        pendingImport = nil
    }

    func delete(at offsets: IndexSet) {
        scripts.remove(atOffsets: offsets)
        persistAndSync()
    }

    func update(_ script: ChoreographyScript) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index] = script
        persistAndSync()
    }

    func saveTeachingCopy(_ script: ChoreographyScript) {
        var script = script
        script.sections = RepeatLinker.linking(script.sections)
        script.originalSections = RepeatLinker.linking(script.originalSections)
        script.parserVersion = ChoreographyScript.currentParserVersion
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = script
        } else {
            scripts.append(script)
        }
        persistAndSync()
    }

    func saveBuiltClassPlan(
        title: String,
        selections: [(script: ChoreographyScript, section: ChoreographySection)],
        availableOnWatch: Bool
    ) {
        guard !selections.isEmpty else { return }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let copiedSections = RepeatLinker.linking(selections.map { $0.section.independentCopy() })
        let sourceScripts = selections.reduce(into: [ChoreographyScript]()) { result, selection in
            guard !result.contains(where: { $0.id == selection.script.id }) else { return }
            result.append(selection.script)
        }
        let classTypes = Set(sourceScripts.map(\.classType))
        let classType = classTypes.count == 1 ? (classTypes.first ?? .unknown) : .unknown
        let sourceDescription = sourceScripts.map(\.title).joined(separator: ", ")

        let script = ChoreographyScript(
            title: trimmedTitle.isEmpty ? "New Class Plan" : trimmedTitle,
            sourceFilename: sourceDescription,
            sections: copiedSections,
            originalText: builtPlanText(from: selections),
            classType: classType,
            isAvailableOnWatch: availableOnWatch,
            kind: .builtPlan
        )

        scripts.append(script)
        persistAndSync()
    }

    func setWatchAvailability(for id: UUID, isAvailable: Bool) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].isAvailableOnWatch = isAvailable
        persistAndSync()
    }

    func syncNow() {
        connectivity.sync(scripts: watchScripts)
    }

    func prepareAudioFollow() {
        connectivity.prepareAudioPermissions { [weak self] message in
            self?.audioSetupMessage = message
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? SharedCodec.decoder.decode([ChoreographyScript].self, from: data) else { return }
        var didMigrate = false
        scripts = saved.map { savedScript in
            guard savedScript.parserVersion < ChoreographyScript.currentParserVersion else { return savedScript }

            if savedScript.isTeachingCopy {
                var migrated = savedScript
                migrated.sections = RepeatLinker.linking(migrated.sections)
                migrated.originalSections = RepeatLinker.linking(migrated.originalSections)
                migrated.parserVersion = ChoreographyScript.currentParserVersion
                didMigrate = true
                return migrated
            }

            guard !savedScript.originalText.isEmpty else { return savedScript }

            var reparsed = ChoreographyParser().parse(
                text: savedScript.originalText,
                title: savedScript.title,
                sourceFilename: savedScript.sourceFilename
            )
            reparsed.id = savedScript.id
            reparsed.importedAt = savedScript.importedAt
            reparsed.isAvailableOnWatch = savedScript.isAvailableOnWatch
            didMigrate = true
            return reparsed
        }
        scripts.sort(by: ChoreographyScript.alphabeticallyByTitle)

        if didMigrate,
           let migratedData = try? SharedCodec.encoder.encode(scripts) {
            try? migratedData.write(to: fileURL, options: .atomic)
        }
    }

    private func persistAndSync() {
        do {
            scripts.sort(by: ChoreographyScript.alphabeticallyByTitle)
            let data = try SharedCodec.encoder.encode(scripts)
            try data.write(to: fileURL, options: .atomic)
            connectivity.sync(scripts: watchScripts)
        } catch {
            importError = "The class library could not be saved: \(error.localizedDescription)"
        }
    }

    private func builtPlanText(
        from selections: [(script: ChoreographyScript, section: ChoreographySection)]
    ) -> String {
        selections.map { selection in
            let section = selection.section
            let metadata = [section.song, section.option, section.equipment, section.direction]
                .compactMap { $0 }
                .joined(separator: "\n")
            let combinations = section.combinations.map { combination in
                let heading = combination.title.map { "\n\($0)" } ?? ""
                let cues = combination.cues.map { cue in
                    [cue.listMarker, cue.text].compactMap { $0 }.joined(separator: " ")
                }.joined(separator: "\n")
                return "\(heading)\n\(cues)"
            }.joined(separator: "\n")

            return "SOURCE: \(selection.script.title)\n\(section.heading)\n\(metadata)\n\(combinations)"
        }.joined(separator: "\n\n")
    }
}

