import Foundation

struct ChoreographyParser {
    func parse(text: String, title: String, sourceFilename: String) -> ChoreographyScript {
        let rawLines = text
            .components(separatedBy: .newlines)
            .map(normalizeDisplayText)
            .filter { !$0.isEmpty }

        let classType = detectClassType(in: rawLines, title: title)
        let plannedDuration = extractPlannedDuration(from: rawLines, classType: classType)
        let contentLines = trimOverview(from: rawLines, classType: classType)
        let filteredLines = contentLines.enumerated().compactMap { index, line -> String? in
            let next = contentLines.indices.contains(index + 1) ? contentLines[index + 1] : nil
            return isBoilerplate(line, nextLine: next) ? nil : line
        }
        let lines = joinListMarkers(in: filteredLines)

        var sections: [ChoreographySection] = []
        var sectionHeading = "CLASS NOTES"
        var sectionSong: String?
        var sectionEquipment: String?
        var sectionOption: String?
        var sectionDirection: String?
        var combinations: [ChoreographyCombination] = []
        var combinationTitle: String?
        var cues: [ChoreographyCue] = []

        func flushCombination() {
            guard combinationTitle != nil || !cues.isEmpty else { return }
            combinations.append(.init(title: combinationTitle, cues: cues))
            combinationTitle = nil
            cues = []
        }

        func flushSection() {
            flushCombination()
            guard !combinations.isEmpty else { return }
            sections.append(.init(
                heading: sectionHeading,
                combinations: combinations,
                song: sectionSong,
                equipment: sectionEquipment,
                option: sectionOption,
                direction: sectionDirection
            ))
            combinations = []
        }

        func beginSection(_ heading: String) {
            flushSection()
            sectionHeading = heading
            sectionSong = nil
            sectionEquipment = nil
            sectionOption = nil
            sectionDirection = nil
        }

        for line in lines {
            if isMajorHeading(line, classType: classType) {
                beginSection(line)
            } else if let value = metadataValue(in: line, prefix: "SONG") {
                sectionSong = value
            } else if let value = metadataValue(in: line, prefix: "EQUIPMENT") {
                sectionEquipment = value
            } else if isSimpleOptionLine(line) {
                sectionOption = line
            } else if let value = metadataValue(in: line, prefix: "DIRECTION") {
                sectionDirection = value
            } else if isCombinationHeading(line) {
                flushCombination()
                combinationTitle = line
            } else if shouldJoinContinuation(line, after: cues.last?.sourceText ?? cues.last?.text) {
                cues[cues.count - 1].text += " " + line
                if cues[cues.count - 1].sourceText != nil {
                    cues[cues.count - 1].sourceText! += " " + line
                }
            } else {
                cues.append(makeCue(from: line, sectionHeading: sectionHeading))
            }
        }
        flushSection()

        if sections.isEmpty {
            sections = [.init(
                heading: "CLASS NOTES",
                combinations: [.init(cues: lines.map { makeCue(from: $0, sectionHeading: "CLASS NOTES") })]
            )]
        }

        sections = RepeatLinker.linking(sections)

        return .init(
            title: title,
            sourceFilename: sourceFilename,
            sections: sections,
            originalText: text,
            classType: classType,
            plannedDurationMinutes: plannedDuration
        )
    }

    private func normalizeDisplayText(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "ﬁ", with: "fi")
            .replacingOccurrences(of: "ﬂ", with: "fl")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{2060}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canonicalHeading(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "*:-–— ")).uppercased()
    }

    private func detectClassType(in lines: [String], title: String) -> BarreClassType {
        let sample = ([title] + lines.prefix(20)).joined(separator: " ").uppercased()
        if sample.contains("BARRE DEFINE") || sample.contains("DEFINE CHOREO") { return .define }
        if sample.contains("BARRE ENGAGE") { return .engage }
        if sample.contains("BARRE ALIGN") { return .align }
        if sample.contains("BARRE REFORM") { return .reform }
        if sample.contains("BARRE EMPOWER") { return .empower }
        if sample.contains("BARRE CLASSIC CLASS PLAN") { return .classic }
        return .unknown
    }

    private func extractPlannedDuration(from lines: [String], classType: BarreClassType) -> Int? {
        let sample = lines.prefix(80).joined(separator: " ").uppercased()
        if let match = firstMatch(in: sample, pattern: #"\b(\d{2})\s*MIN\b"#),
           let minutes = Int(match[1]) {
            return minutes
        }
        if classType == .reform,
           let match = firstMatch(in: sample, pattern: #"TOTAL\s+TIME\s+(\d+)\s*[-–]\s*(\d+)"#),
           let upper = Int(match[2]) {
            return upper
        }
        return nil
    }

    private func firstMatch(in text: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func trimOverview(from lines: [String], classType: BarreClassType) -> [String] {
        guard classType != .unknown else { return lines }
        let mainStart = lines.firstIndex { line in
            let canonical = canonicalHeading(line)
            let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let isUppercase = !letters.contains(where: { CharacterSet.lowercaseLetters.contains($0) })
            return isUppercase && (canonical == "WARM UP"
                || canonical == "WARMUP"
                || canonical.range(of: #"^BLOCK\s+1\s*\|"#, options: .regularExpression) != nil)
        }
        let roomStarts = lines.indices.filter { index in
            let canonical = canonicalHeading(lines[index])
            let letters = lines[index].unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let isUppercase = !letters.contains(where: { CharacterSet.lowercaseLetters.contains($0) })
            let isRoomSetup = isUppercase && (canonical == "ROOM SET UP" || canonical == "ROOM SETUP")
            return isRoomSetup && (mainStart == nil || index < mainStart!)
        }
        let start = roomStarts.last ?? mainStart
        guard let start else { return lines }
        return Array(lines[start...])
    }

    private func isMajorHeading(_ line: String, classType: BarreClassType) -> Bool {
        let canonical = canonicalHeading(line)
        if canonical.range(of: #"^BLOCK\s+\d+\s*\|"#, options: .regularExpression) != nil { return true }
        if canonical == "ROOM SET UP" || canonical == "ROOM SETUP" || canonical == "COOL DOWN 2" { return true }

        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.contains(where: { CharacterSet.lowercaseLetters.contains($0) }) else { return false }

        if classType == .define || classType == .engage {
            return false
        }

        let exact: Set<String> = [
            "WARM UP", "WARMUP", "WARMUP FLOOR WORK", "WARMUP WEIGHT WORK", "WARM UP WEIGHT WORK",
            "FLOORWORK", "FLOOR WORK AT BARRE",
            "WEIGHT WORK", "ARMS", "ARMS & LEGS", "ARM STRETCH", "ARMS & LEGS STRETCH",
            "CLASSIC THIGH INSERT", "CORE", "CORE COMBO", "CORE FOCUS", "ABS",
            "ABS 1–3", "ABS 1-3",
            "BACK EXTENSION", "BACK EXTENSION SERIES", "BACK DANCING", "BRIDGING",
            "STRETCH", "STRETCH AT BARRE", "PIGEON STRETCH", "KNEELING STRETCH SERIES",
            "SEATED / ON BACK STRETCH SERIES", "ON BACK COOL DOWN", "FINAL STRETCH",
            "COOL DOWN", "COOL-DOWN", "FLAT ON BACK STRETCH", "STANDING SEAT STRETCH", "SEAT"
        ]
        if exact.contains(canonical) { return true }

        let prefixes = [
            "THIGH #", "THIGH STRETCH", "THIGHS", "SEAT SIDE #", "FLOOR CORE WORK",
            "ABS FOCUS", "BALANCING STRENGTH & STRETCH SERIES", "BARRE STRENGTH & STRETCH SERIES",
            "CARDIO CENTRIC #", "STRENGTH CIRCUIT #", "STRENGTH SERIES #",
            "COBRA–BACK EXTENSION–CAT/COW", "COBRA-BACK EXTENSION-CAT/COW"
        ]
        if prefixes.contains(where: canonical.hasPrefix) { return true }

        if classType == .unknown {
            return canonical.hasPrefix("WARM UP ")
                || canonical.hasPrefix("WARM-UP ")
                || canonical.hasPrefix("WEIGHT WORK ")
                || canonical.hasPrefix("SEAT")
                || canonical.range(of: #"^ABS\s+\d+$"#, options: .regularExpression) != nil
        }
        return false
    }

    private func isBoilerplate(_ line: String, nextLine: String?) -> Bool {
        let canonical = canonicalHeading(line)
        if canonical == "CLASSIC CHOREOGRAPHY COMBINATIONS" || canonical == "CHOREOGRAPHY WRITE-UP" {
            return true
        }
        if canonical.contains("BARRE"), canonical.contains("CLASS PLAN") { return true }
        if canonical.hasPrefix("DEFINE CHOREO | CLASS PLAN") { return true }
        if canonical.range(of: #"^Q\d\s+\d{4}$"#, options: .regularExpression) != nil { return true }
        if canonical == "SONG SECTION OPTION DIRECTION"
            || canonical == "SONG SECTION OPTION EQUIPMENT TIME"
            || canonical == "SONG BLOCK SECTION TIME" { return true }
        if canonical.range(of: #"^Q\d \d{4} TO POST \d{1,2}\.\d{1,2}\.\d{2}$"#, options: .regularExpression) != nil {
            return true
        }
        if canonical.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil {
            guard let nextLine else { return true }
            let nextCanonical = canonicalHeading(nextLine)
            return nextCanonical.contains("BARRE") || nextCanonical.contains("CHOREOGRAPHY")
        }
        return false
    }

    private func joinListMarkers(in lines: [String]) -> [String] {
        var result: [String] = []
        var marker: String?

        for line in lines {
            if isStandaloneListMarker(line) {
                marker = line
            } else if let pendingMarker = marker {
                result.append("\(pendingMarker) \(line)")
                marker = nil
            } else {
                result.append(line)
            }
        }
        if let marker { result.append(marker) }
        return result
    }

    private func isStandaloneListMarker(_ line: String) -> Bool {
        ["•", "●", "○", "◦", "▪", "▫", "‣", "⁃", "o", "*", "+", "-"].contains(line)
    }

    private func splitListItem(_ line: String) -> (marker: String, text: String)? {
        let patterns = [
            #"^(\d{1,3}[.)])\s*(.+)$"#,
            #"^(\(\d{1,3}\))\s*(.+)$"#,
            #"^([•●○◦▪▫‣⁃])\s*(.+)$"#,
            #"^([*+\-–—])\s+(.+)$"#,
            #"^(o)\s+(.+)$"#
        ]
        for pattern in patterns {
            if let match = firstMatch(in: line, pattern: pattern), match.count == 3 {
                return (match[1], match[2])
            }
        }
        return nil
    }

    private func metadataValue(in line: String, prefix: String) -> String? {
        let canonical = canonicalHeading(line)
        let pattern = "^\(prefix)S?\\s*:?\\s*(#?.+)$"
        guard canonical.range(of: pattern, options: .regularExpression) != nil else { return nil }
        guard let colon = line.firstIndex(of: ":") else {
            let pieces = line.split(separator: " ", maxSplits: 1).map(String.init)
            return pieces.count == 2 ? pieces[1] : line
        }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    private func isSimpleOptionLine(_ line: String) -> Bool {
        canonicalHeading(line).range(of: #"^OPTION\s+[A-Z0-9]+$"#, options: .regularExpression) != nil
    }

    private func isCombinationHeading(_ line: String) -> Bool {
        let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 3, line.count <= 100 else { return false }
        let hasLowercase = letters.contains { CharacterSet.lowercaseLetters.contains($0) }
        let looksLikeCount = line.range(of: #"\b\d+\b"#, options: .regularExpression) != nil
        let canonical = canonicalHeading(line)
        let excludedPrefixes = [
            "OR", "USES ", "USE SONG", "CLICK TO SONG", "MUSIC ", "LIGHTS ", "DIM LIGHTS",
            "TURN ", "AFTER ", "REPEAT ", "REMOVE ", "SET ", "COME TO ", "FLOW ",
            "CENTER OF ", "AT BARRE", "NO WEIGHTS", "STAY ", "COMPLETE ", "ROOM SET"
        ]
        return !hasLowercase
            && !looksLikeCount
            && !excludedPrefixes.contains(where: canonical.hasPrefix)
    }

    private func makeCue(from line: String, sectionHeading: String) -> ChoreographyCue {
        let listItem = splitListItem(line)
        let cueText = listItem?.text ?? line
        let parts = cueText.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let kind = cueKind(for: cueText, sectionHeading: sectionHeading)
        if parts.count == 2 {
            let short = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let detail = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if !short.isEmpty, !detail.isEmpty {
                return .init(text: detail, shortText: short, sourceText: line, kind: kind, listMarker: listItem?.marker)
            }
        }
        return .init(text: cueText, sourceText: line, kind: kind, listMarker: listItem?.marker)
    }

    private func cueKind(for line: String, sectionHeading: String) -> ChoreographyCueKind {
        let canonical = canonicalHeading(line)
        let section = canonicalHeading(sectionHeading)
        if section == "ROOM SET UP" || section == "ROOM SETUP" { return .setup }
        if canonical.contains("REPEAT") || canonical.hasPrefix("COMPLETE ") { return .repeatInstruction }
        if canonical.hasPrefix("AFTER ") || canonical.hasPrefix("FLOW ") || canonical.hasPrefix("COME TO ")
            || canonical.hasPrefix("SET WEIGHTS ASIDE") || canonical.hasPrefix("STAY AT ") { return .transition }
        if canonical.hasPrefix("SONG") || canonical.hasPrefix("USE SONG") || canonical.hasPrefix("CLICK TO SONG")
            || canonical.contains("MUSIC ") || canonical.contains("LIGHTS") { return .song }
        if canonical.hasPrefix("EQUIPMENT") || canonical.hasPrefix("USES ")
            || canonical.hasPrefix("REMOVE ") || canonical == "NO WEIGHTS" { return .equipment }
        if canonical.hasPrefix("OPTION ") { return .option }
        return .choreography
    }

    private func shouldJoinContinuation(_ line: String, after previous: String?) -> Bool {
        guard let previous, !previous.isEmpty, let first = line.unicodeScalars.first else { return false }
        if splitListItem(line) != nil { return false }
        if CharacterSet.lowercaseLetters.contains(first)
            || CharacterSet.decimalDigits.contains(first)
            || CharacterSet(charactersIn: "–—-,;/)").contains(first) {
            return true
        }
        return previous.hasSuffix(",")
            || previous.hasSuffix(";")
            || previous.hasSuffix("/")
            || previous.hasSuffix("“W”")
            || previous.hasSuffix("“O”")
    }
}
