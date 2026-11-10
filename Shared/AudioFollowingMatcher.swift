import Foundation

struct AudioTranscriptEvidence: Hashable, Sendable {
    var text: String
    var confidence: Double
    var ageSeconds: TimeInterval
}

struct AudioCueLocation: Codable, Hashable, Sendable {
    var sectionIndex: Int
    var cueIndex: Int
    var sectionHeading: String
    var combinationTitle: String?
    var cueText: String
}

struct AudioMatchResult: Hashable, Sendable {
    var location: AudioCueLocation
    var confidence: Double
    var runnerUpConfidence: Double
}

enum AudioMatchScope: Sendable {
    case follow
    case locate
    case skipDetection
}

struct AudioFollowingMatcher {
    func match(
        evidence: [AudioTranscriptEvidence],
        script: ChoreographyScript,
        currentSectionIndex: Int,
        currentCueIndex: Int,
        elapsedSeconds: TimeInterval?,
        scope: AudioMatchScope
    ) -> AudioMatchResult? {
        let candidates = flatten(script)
        guard !candidates.isEmpty, evidence.contains(where: { !tokens(in: $0.text).isEmpty }) else { return nil }

        let currentGlobalIndex = candidates.firstIndex {
            $0.location.sectionIndex == currentSectionIndex && $0.location.cueIndex == currentCueIndex
        } ?? 0

        let eligible: [(globalIndex: Int, location: AudioCueLocation)]
        switch scope {
        case .follow:
            let lower = max(0, currentGlobalIndex - 1)
            let upper = min(candidates.count - 1, currentGlobalIndex + 6)
            eligible = Array(candidates[lower...upper])
        case .locate:
            eligible = candidates
        case .skipDetection:
            eligible = candidates.filter { $0.location.sectionIndex >= currentSectionIndex + 2 }
        }

        guard !eligible.isEmpty else { return nil }

        let elapsedProgress: Double? = {
            guard let elapsedSeconds,
                  let minutes = script.plannedDurationMinutes,
                  minutes > 0 else { return nil }
            return min(1, max(0, elapsedSeconds / Double(minutes * 60)))
        }()

        let scored = eligible.map { candidate -> (AudioCueLocation, Double) in
            let candidateText = [
                candidate.location.sectionHeading,
                candidate.location.combinationTitle,
                candidate.location.cueText
            ].compactMap { $0 }.joined(separator: " ")

            let audioScore = evidence.reduce(0.0) { best, item in
                let similarity = tokenSimilarity(spoken: item.text, candidate: candidateText)
                let recognition = 0.65 + (0.35 * min(1, max(0, item.confidence)))
                let recency = exp(-max(0, item.ageSeconds) / 45)
                return max(best, similarity * recognition * recency)
            }

            let distance = abs(candidate.globalIndex - currentGlobalIndex)
            let continuityDivisor: Double = scope == .follow ? 6 : 18
            let continuity = max(0, 1 - (Double(distance) / continuityDivisor))

            let timing: Double
            if let elapsedProgress, candidates.count > 1 {
                let candidateProgress = Double(candidate.globalIndex) / Double(candidates.count - 1)
                timing = max(0, 1 - abs(candidateProgress - elapsedProgress) / 0.28)
            } else {
                timing = 0.5
            }

            let score: Double
            switch scope {
            case .follow:
                score = (audioScore * 0.88) + (continuity * 0.12)
            case .locate:
                score = (audioScore * 0.72) + (timing * 0.20) + (continuity * 0.08)
            case .skipDetection:
                score = (audioScore * 0.82) + (timing * 0.12) + (continuity * 0.06)
            }
            return (candidate.location, min(1, max(0, score)))
        }.sorted { $0.1 > $1.1 }

        guard let best = scored.first else { return nil }
        return AudioMatchResult(
            location: best.0,
            confidence: best.1,
            runnerUpConfidence: scored.dropFirst().first?.1 ?? 0
        )
    }

    private func flatten(_ script: ChoreographyScript) -> [(globalIndex: Int, location: AudioCueLocation)] {
        var result: [(Int, AudioCueLocation)] = []
        for (sectionIndex, section) in script.sections.enumerated() {
            var cueIndex = 0
            for combination in section.combinations {
                for cue in combination.cues {
                    let marker = cue.listMarker.map { "\($0) " } ?? ""
                    result.append((result.count, .init(
                        sectionIndex: sectionIndex,
                        cueIndex: cueIndex,
                        sectionHeading: section.heading,
                        combinationTitle: combination.title,
                        cueText: marker + (cue.shortText ?? cue.text)
                    )))
                    cueIndex += 1
                }
            }
        }
        return result
    }

    private func tokenSimilarity(spoken: String, candidate: String) -> Double {
        let spokenTokens = tokens(in: spoken)
        let candidateTokens = tokens(in: candidate)
        guard !spokenTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        let spokenSet = Set(spokenTokens)
        let candidateSet = Set(candidateTokens)
        let overlap = Double(spokenSet.intersection(candidateSet).count)
        let spokenCoverage = overlap / Double(spokenSet.count)
        let candidateCoverage = overlap / Double(candidateSet.count)

        let spokenBigrams = Set(zip(spokenTokens, spokenTokens.dropFirst()).map { "\($0.0) \($0.1)" })
        let candidateBigrams = Set(zip(candidateTokens, candidateTokens.dropFirst()).map { "\($0.0) \($0.1)" })
        let bigramScore: Double
        if spokenBigrams.isEmpty || candidateBigrams.isEmpty {
            bigramScore = 0
        } else {
            bigramScore = Double(spokenBigrams.intersection(candidateBigrams).count) / Double(spokenBigrams.count)
        }

        return min(1, (spokenCoverage * 0.50) + (candidateCoverage * 0.30) + (bigramScore * 0.20))
    }

    private func tokens(in text: String) -> [String] {
        let stopWords: Set<String> = ["a", "an", "and", "the", "of", "to", "your", "you"]
        return text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }
}
