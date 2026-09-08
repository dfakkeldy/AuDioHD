// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

nonisolated enum ContextualCandidateSlot: String, Codable, Equatable, Sendable {
    case a, b, c, d, needsReview
}

nonisolated enum ContextualFamilyState: String, Codable, Equatable, Sendable {
    case disabled, shadow, graduated
}

nonisolated enum DeterministicRuleStrength: String, Codable, Equatable, Sendable {
    case definitive, advisory, abstained
}

nonisolated struct ContextualPronunciationCandidate: Codable, Equatable, Sendable {
    let slot: ContextualCandidateSlot
    let candidateID: String
    let ipa: String
    let senseLabel: String
    let lexicalRole: String
}

nonisolated struct ContextualPronunciationOccurrence: Codable, Equatable, Sendable {
    let occurrenceID: String
    let blockID: String
    let wordStart: Int
    let wordEnd: Int
    let targetWord: String
    var precedingSentence: String?
    let targetSentence: String
    var followingSentence: String?
    let familyID: String
    let candidates: [ContextualPronunciationCandidate]
    let deterministicCandidateID: String?
    let deterministicRuleID: String?
    let deterministicStrength: DeterministicRuleStrength
    /// Index in the display sentence, not in the block or pronunciation markup.
    /// Optional for decoding older discovery fixtures.
    var targetSentenceWordIndex: Int? = nil
}

nonisolated struct ContextualPronunciationKey: Hashable, Sendable {
    let blockID: String
    let wordStart: Int
    let wordEnd: Int
}

nonisolated enum ContextualPronunciationOccurrenceID {
    static func make(
        blockID: String,
        wordStart: Int,
        wordEnd: Int,
        normalizedWord: String
    ) -> String {
        let payload = [
            ContextualPronunciationFamilies.promptSchemaVersion,
            blockID,
            String(wordStart),
            String(wordEnd),
            normalizedWord,
        ].joined(separator: "\0")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

nonisolated enum ContextualModelAvailability: String, Codable, Equatable, Sendable {
    case available
    case notRequested
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unknown
}

nonisolated enum ContextualModelFailure: String, Codable, Equatable, Sendable {
    /// The prompt genuinely exceeded the model's context window.
    case contextTooLarge
    /// The runtime reported no usable context window, so the prompt could not
    /// be size-checked at all. Distinct from `contextTooLarge`: nothing was
    /// oversized, the window size was simply unknown.
    case contextWindowUnavailable
    case guardrail
    case refusal
    case unsupportedLanguageOrLocale
    case timeout
    case rateLimited
    case assetsUnavailable
    case concurrentRequest
    case parsing
    case invalidBatch
    case cancelled
    case unknown
}

nonisolated struct ContextualPronunciationFamily: Codable, Equatable, Sendable {
    let familyID: String
    let normalizedSpelling: String
    let candidates: [ContextualPronunciationCandidate]
    let state: ContextualFamilyState
}

nonisolated struct ContextualDeterministicAnalysis: Equatable, Sendable {
    let candidateID: String?
    let ruleID: String?
    let strength: DeterministicRuleStrength

    static let abstained = Self(
        candidateID: nil,
        ruleID: nil,
        strength: .abstained)
}

nonisolated struct ContextualPronunciationBatchRequest: Equatable, Sendable {
    let occurrences: [ContextualPronunciationOccurrence]
}

nonisolated struct ContextualModelSelection: Equatable, Sendable {
    let occurrenceID: String
    let slot: ContextualCandidateSlot
}

nonisolated struct ContextualModelRuntime: Codable, Equatable, Sendable {
    let platform: String
    let osBuild: String
    let qualifiedRuntimeFamilyID: String
}

nonisolated struct ContextualPronunciationBatchResult: Equatable, Sendable {
    let availability: ContextualModelAvailability
    let selections: [ContextualModelSelection]
    let failure: ContextualModelFailure?
    let runtime: ContextualModelRuntime
}

typealias ContextualPronunciationBatchEvaluator =
    @Sendable (ContextualPronunciationBatchRequest) async throws
    -> ContextualPronunciationBatchResult

nonisolated struct ContextualPronunciationEvidence: Codable, Equatable, Sendable {
    let occurrenceID: String
    let familyID: String
    let candidatePackVersion: String
    let submittedCandidateIDs: [String]
    let deterministicCandidateID: String?
    let deterministicRuleID: String?
    let deterministicStrength: DeterministicRuleStrength
    let modelCandidateID: String?
    let modelAbstained: Bool
    let modelAvailability: ContextualModelAvailability
    let modelFailure: ContextualModelFailure?
    let familyState: ContextualFamilyState
    let acceptanceReason: ContextualAcceptanceReason
    let promptSchemaVersion: String
    let platform: String
    let osBuild: String
    let qualifiedRuntimeFamilyID: String
    let humanCandidateID: String?
    let humanCorrectionScope: String?
    let isLimited: Bool
}

nonisolated enum ContextualPronunciationEvidenceValidator {
    static func isValidPhaseTwo(
        _ evidence: ContextualPronunciationEvidence,
        blockID: String,
        wordStart: Int,
        wordEnd: Int,
        normalizedWord: String,
        source: PronunciationAuditDecision.Source
    ) -> Bool {
        guard isEligiblePhaseTwoSource(source) else {
            return false
        }
        return isValidPhaseTwoEnvelope(
            evidence,
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordEnd,
            normalizedWord: normalizedWord)
    }

    private static func isValidPhaseTwoEnvelope(
        _ evidence: ContextualPronunciationEvidence,
        blockID: String,
        wordStart: Int,
        wordEnd: Int,
        normalizedWord: String
    ) -> Bool {
        guard
            let family = ContextualPronunciationFamilies.family(
                for: normalizedWord),
            evidence.occurrenceID
                == ContextualPronunciationOccurrenceID.make(
                    blockID: blockID,
                    wordStart: wordStart,
                    wordEnd: wordEnd,
                    normalizedWord: normalizedWord),
            evidence.familyID == family.familyID,
            evidence.candidatePackVersion
                == ContextualPronunciationFamilies.candidatePackVersion,
            evidence.submittedCandidateIDs == family.candidates.map(\.candidateID),
            family.state == .shadow,
            evidence.familyState == .shadow,
            evidence.promptSchemaVersion
                == ContextualPronunciationFamilies.promptSchemaVersion,
            evidence.humanCandidateID == nil,
            evidence.humanCorrectionScope == nil,
            !evidence.isLimited,
            isPresent(evidence.platform),
            isPresent(evidence.osBuild),
            isPresent(evidence.qualifiedRuntimeFamilyID)
        else {
            return false
        }

        let candidateIDs = Set(evidence.submittedCandidateIDs)
        guard
            [
                evidence.deterministicCandidateID,
                evidence.modelCandidateID,
            ].compactMap({ $0 }).allSatisfy(candidateIDs.contains)
        else {
            return false
        }

        switch evidence.acceptanceReason {
        case .shadowNotRequested:
            return evidence.modelAvailability == .notRequested
                && evidence.modelFailure == nil && evidence.modelCandidateID == nil
                && !evidence.modelAbstained
        case .shadowObserved:
            return evidence.modelAvailability == .available
                && evidence.modelFailure == nil
                && evidence.modelCandidateID != nil
                && !evidence.modelAbstained
        case .shadowNeedsReview:
            return evidence.modelAvailability == .available
                && evidence.modelFailure == nil
                && evidence.modelCandidateID == nil
                && evidence.modelAbstained
        case .shadowModelUnavailable:
            return evidence.modelAvailability != .available
                && evidence.modelFailure == nil
                && evidence.modelCandidateID == nil
                && !evidence.modelAbstained
        case .shadowModelFailure:
            return evidence.modelAvailability == .available
                && evidence.modelFailure != nil
                && evidence.modelFailure != .cancelled
                && evidence.modelCandidateID == nil
                && !evidence.modelAbstained
        }
    }

    static func isValidPhaseTwo(
        _ evidence: ContextualPronunciationEvidence,
        for occurrence: ContextualPronunciationOccurrence
    ) -> Bool {
        isValidPhaseTwoEnvelope(
            evidence,
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd,
            normalizedWord: PronunciationAuditContext.normalizedWord(
                occurrence.targetWord))
            && evidence.deterministicCandidateID
                == occurrence.deterministicCandidateID
            && evidence.deterministicRuleID == occurrence.deterministicRuleID
            && evidence.deterministicStrength
                == occurrence.deterministicStrength
    }

    private static func isPresent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isEligiblePhaseTwoSource(
        _ source: PronunciationAuditDecision.Source
    ) -> Bool {
        switch source {
        case .occurrenceOverride, .bookOverride, .globalOverride, .epubInline, .epubLexicon,
            .builtInOverride:
            return false
        case .contextualHomograph, .supplementalLexicon, .derivedMorphology,
            .monitoredLexicon, .fallback:
            return true
        }
    }
}

nonisolated enum ContextualAcceptanceReason: String, Codable, Equatable, Sendable {
    case shadowNotRequested
    case shadowObserved
    case shadowNeedsReview
    case shadowModelUnavailable
    case shadowModelFailure
}

nonisolated struct ContextualPronunciationPreflightConfiguration: Equatable, Sendable {
    let maximumBatchCount: Int
    let maximumPromptCharacters: Int

    static let phaseTwo = Self(
        maximumBatchCount: 8,
        maximumPromptCharacters: 8_000)
}
