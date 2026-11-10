import Foundation

enum BarreClassType: String, Codable, CaseIterable, Hashable, Sendable {
    case classic
    case define
    case engage
    case align
    case reform
    case empower
    case unknown

    var displayName: String {
        switch self {
        case .classic: "Classic"
        case .define: "Define"
        case .engage: "Engage"
        case .align: "Align"
        case .reform: "Reform"
        case .empower: "Empower"
        case .unknown: "Class Plan"
        }
    }
}

enum ChoreographyCueKind: String, Codable, CaseIterable, Hashable, Sendable {
    case choreography
    case setup
    case equipment
    case song
    case option
    case transition
    case repeatInstruction
}

enum ChoreographyScriptKind: String, Codable, Hashable, Sendable {
    case importedPDF
    case teachingCopy
    case builtPlan
}

struct ChoreographyScript: Identifiable, Codable, Hashable, Sendable {
    static let currentParserVersion = 3

    var id: UUID
    var title: String
    var importedAt: Date
    var sourceFilename: String
    var sections: [ChoreographySection]
    var originalSections: [ChoreographySection]
    var originalText: String
    var sourceScriptID: UUID?
    var classType: BarreClassType
    var plannedDurationMinutes: Int?
    var isAvailableOnWatch: Bool
    var parserVersion: Int
    var kind: ChoreographyScriptKind

    init(
        id: UUID = UUID(),
        title: String,
        importedAt: Date = Date(),
        sourceFilename: String,
        sections: [ChoreographySection],
        originalSections: [ChoreographySection]? = nil,
        originalText: String,
        sourceScriptID: UUID? = nil,
        classType: BarreClassType = .unknown,
        plannedDurationMinutes: Int? = nil,
        isAvailableOnWatch: Bool = true,
        parserVersion: Int = ChoreographyScript.currentParserVersion,
        kind: ChoreographyScriptKind = .importedPDF
    ) {
        self.id = id
        self.title = title
        self.importedAt = importedAt
        self.sourceFilename = sourceFilename
        self.sections = sections
        self.originalSections = originalSections ?? sections
        self.originalText = originalText
        self.sourceScriptID = sourceScriptID
        self.classType = classType
        self.plannedDurationMinutes = plannedDurationMinutes
        self.isAvailableOnWatch = isAvailableOnWatch
        self.parserVersion = parserVersion
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, importedAt, sourceFilename, sections, originalSections, originalText, sourceScriptID
        case classType, plannedDurationMinutes, isAvailableOnWatch, parserVersion, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        sourceFilename = try container.decode(String.self, forKey: .sourceFilename)
        sections = try container.decode([ChoreographySection].self, forKey: .sections)
        originalSections = try container.decodeIfPresent([ChoreographySection].self, forKey: .originalSections) ?? sections
        originalText = try container.decodeIfPresent(String.self, forKey: .originalText) ?? ""
        sourceScriptID = try container.decodeIfPresent(UUID.self, forKey: .sourceScriptID)
        classType = try container.decodeIfPresent(BarreClassType.self, forKey: .classType) ?? .unknown
        plannedDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .plannedDurationMinutes)
        isAvailableOnWatch = try container.decodeIfPresent(Bool.self, forKey: .isAvailableOnWatch) ?? true
        parserVersion = try container.decodeIfPresent(Int.self, forKey: .parserVersion) ?? 1
        kind = try container.decodeIfPresent(ChoreographyScriptKind.self, forKey: .kind)
            ?? (sourceScriptID == nil ? .importedPDF : .teachingCopy)
    }
}

extension ChoreographyScript {
    var isTeachingCopy: Bool { sourceScriptID != nil }

    var isBuiltPlan: Bool { kind == .builtPlan }

    var planLabel: String {
        switch kind {
        case .importedPDF: "Original"
        case .teachingCopy: "Teaching Copy"
        case .builtPlan: "Built Plan"
        }
    }

    var hasCustomizations: Bool { sections != originalSections }

    func makeTeachingCopy(title: String? = nil) -> ChoreographyScript {
        let copyTitle = title ?? "\(self.title) – Teaching Copy"
        return ChoreographyScript(
            title: copyTitle,
            sourceFilename: sourceFilename,
            sections: sections,
            originalSections: originalSections,
            originalText: originalText,
            sourceScriptID: sourceScriptID ?? id,
            classType: classType,
            plannedDurationMinutes: plannedDurationMinutes,
            isAvailableOnWatch: true,
            parserVersion: parserVersion,
            kind: .teachingCopy
        )
    }

    mutating func restoreOriginalSections() {
        sections = originalSections
    }

    static func alphabeticallyByTitle(_ lhs: ChoreographyScript, _ rhs: ChoreographyScript) -> Bool {
        let comparison = lhs.title.localizedStandardCompare(rhs.title)
        if comparison == .orderedSame {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return comparison == .orderedAscending
    }
}

struct ChoreographySection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var heading: String
    var combinations: [ChoreographyCombination]
    var song: String?
    var equipment: String?
    var option: String?
    var direction: String?

    init(
        id: UUID = UUID(),
        heading: String,
        combinations: [ChoreographyCombination],
        song: String? = nil,
        equipment: String? = nil,
        option: String? = nil,
        direction: String? = nil
    ) {
        self.id = id
        self.heading = heading
        self.combinations = combinations
        self.song = song
        self.equipment = equipment
        self.option = option
        self.direction = direction
    }

    private enum CodingKeys: String, CodingKey {
        case id, heading, combinations, song, equipment, option, direction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        heading = try container.decode(String.self, forKey: .heading)
        combinations = try container.decode([ChoreographyCombination].self, forKey: .combinations)
        song = try container.decodeIfPresent(String.self, forKey: .song)
        equipment = try container.decodeIfPresent(String.self, forKey: .equipment)
        option = try container.decodeIfPresent(String.self, forKey: .option)
        direction = try container.decodeIfPresent(String.self, forKey: .direction)
    }
}

extension ChoreographySection {
    /// Returns a structurally independent copy suitable for use in a newly built plan.
    /// New identifiers prevent collisions when the same source section is used more than once,
    /// while repeat links that point inside the section continue to work.
    func independentCopy() -> ChoreographySection {
        let cueIDMap = Dictionary(uniqueKeysWithValues: combinations.flatMap { combination in
            combination.cues.map { ($0.id, UUID()) }
        })

        let copiedCombinations = combinations.map { combination in
            ChoreographyCombination(
                id: UUID(),
                title: combination.title,
                cues: combination.cues.map { cue in
                    ChoreographyCue(
                        id: cueIDMap[cue.id] ?? UUID(),
                        text: cue.text,
                        shortText: cue.shortText,
                        sourceText: cue.sourceText,
                        kind: cue.kind,
                        listMarker: cue.listMarker,
                        repeatTargetCueID: cue.repeatTargetCueID.flatMap { cueIDMap[$0] }
                    )
                }
            )
        }

        return ChoreographySection(
            id: UUID(),
            heading: heading,
            combinations: copiedCombinations,
            song: song,
            equipment: equipment,
            option: option,
            direction: direction
        )
    }
}

struct ChoreographyCombination: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String?
    var cues: [ChoreographyCue]

    init(id: UUID = UUID(), title: String? = nil, cues: [ChoreographyCue]) {
        self.id = id
        self.title = title
        self.cues = cues
    }
}

struct ChoreographyCue: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var shortText: String?
    var sourceText: String?
    var kind: ChoreographyCueKind
    var listMarker: String?
    var repeatTargetCueID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        shortText: String? = nil,
        sourceText: String? = nil,
        kind: ChoreographyCueKind = .choreography,
        listMarker: String? = nil,
        repeatTargetCueID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.shortText = shortText
        self.sourceText = sourceText
        self.kind = kind
        self.listMarker = listMarker
        self.repeatTargetCueID = repeatTargetCueID
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, shortText, sourceText, kind, listMarker, repeatTargetCueID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        shortText = try container.decodeIfPresent(String.self, forKey: .shortText)
        sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText)
        kind = try container.decodeIfPresent(ChoreographyCueKind.self, forKey: .kind) ?? .choreography
        listMarker = try container.decodeIfPresent(String.self, forKey: .listMarker)
        repeatTargetCueID = try container.decodeIfPresent(UUID.self, forKey: .repeatTargetCueID)
    }
}

enum RepeatLinker {
    static func linking(_ sections: [ChoreographySection], overwriteExisting: Bool = false) -> [ChoreographySection] {
        var linked = sections

        for sectionIndex in linked.indices {
            let combinations = linked[sectionIndex].combinations
            let validCueIDs = Set(combinations.flatMap { $0.cues.map(\.id) })
            let starts: [UUID?] = combinations.map { combination in
                combination.cues.first(where: { cue in
                    cue.kind == .choreography || cue.kind == .setup || cue.kind == .transition
                })?.id
            }

            for combinationIndex in combinations.indices {
                let currentStart = starts[combinationIndex]
                let previousStart = starts[..<combinationIndex].reversed().compactMap { $0 }.first
                let nextStart = starts.dropFirst(combinationIndex + 1).compactMap { $0 }.first
                let inferredTarget = currentStart ?? nextStart ?? previousStart

                for cueIndex in linked[sectionIndex].combinations[combinationIndex].cues.indices {
                    let cue = linked[sectionIndex].combinations[combinationIndex].cues[cueIndex]
                    let existingTargetIsValid = cue.repeatTargetCueID.map(validCueIDs.contains) ?? false
                    guard cue.kind == .repeatInstruction,
                          overwriteExisting || !existingTargetIsValid else { continue }
                    linked[sectionIndex].combinations[combinationIndex].cues[cueIndex].repeatTargetCueID = inferredTarget
                }
            }
        }

        return linked
    }
}

enum SharedCodec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

