// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Compares advisory-only pronunciation candidates without participating in
/// pronunciation selection. The selected seed remains the sole synthesis input.
nonisolated struct PronunciationCandidateAnalyzer: Sendable {
    let productionPack: EnglishPronunciationPack
    let auditPack: EnglishPronunciationAuditPack

    func evidence(
        for decision: PronunciationDecisionSeed,
        fallbackHits: [PronunciationFallbackHit],
        isWatchWord: Bool
    ) -> PronunciationAdvisoryEvidence? {
        let alternatives = advisoryAlternatives(
            for: decision.normalizedWord,
            excluding: decision.selectedIPA)
        guard
            isComparisonScoped(
                decision: decision,
                fallbackHits: fallbackHits,
                alternatives: alternatives,
                isWatchWord: isWatchWord)
        else {
            return nil
        }

        return PronunciationAdvisoryEvidence(
            category: decision.contextualEvidence != nil
                || ContextualPronunciationFamilies.family(for: decision.normalizedWord) != nil
                ? .contextual : .lexical,
            selectedAuthority: selectedAuthority(for: decision),
            selectedCandidateID: decision.candidateID,
            alternatives: alternatives,
            selectionReason: selectionReason(
                for: decision,
                hasAlternatives: !alternatives.isEmpty),
            overrideSuppressedAutomation: isOverride(decision.source)
                && !alternatives.isEmpty,
            policyVersion: auditPack.auditPackVersion)
    }

    /// Stage-three neural comparison is deliberately narrower than the general
    /// audit comparison scope: only a genuine deterministic fallback may invoke
    /// the model. Known-word disagreements remain deterministic and model-free.
    static func isNeuralOOVComparisonCandidate(
        _ decision: PronunciationAuditDecision
    ) -> Bool {
        decision.source == .fallback
            && !decision.normalizedWord.isEmpty
            && decision.advisoryEvidence != nil
    }

    static func attachingNeuralShadowResult(
        _ result: NeuralG2PShadowResult,
        to decision: PronunciationAuditDecision
    ) -> PronunciationAuditDecision {
        guard isNeuralOOVComparisonCandidate(decision), let evidence = decision.advisoryEvidence
        else { return decision }
        let normalizedWord = PronunciationAuditContext.normalizedWord(decision.normalizedWord)
        guard normalizedWord == decision.normalizedWord else { return decision }
        if evidence.neuralShadowObservation == .unstableEvaluation { return decision }

        let existingNeuralAlternatives = evidence.alternatives.filter(claimsNeuralNamespace)
        if evidence.neuralShadowObservation != nil {
            guard evidence.neuralShadowNormalizedWord == normalizedWord,
                evidence.isValid(for: decision)
            else {
                return decision
            }
        } else if !existingNeuralAlternatives.isEmpty {
            // Schema-5 candidates are readable evidence, not a current receipt
            // that repeated evaluation may silently bind or promote.
            return decision
        }

        let preservesInvalidOutputReceipt = decision.isEvidenceOnlyInvalidOutputAdvisory
        let nonNeuralAlternatives = evidence.alternatives.filter {
            !claimsNeuralNamespace($0)
        }
        let baseline = PronunciationAdvisoryEvidence(
            category: evidence.category,
            selectedAuthority: evidence.selectedAuthority,
            selectedCandidateID: evidence.selectedCandidateID,
            alternatives: nonNeuralAlternatives,
            selectionReason: evidence.neuralShadowObservation == nil
                ? evidence.selectionReason : .deterministicFallback,
            overrideSuppressedAutomation: evidence.overrideSuppressedAutomation,
            policyVersion: evidence.policyVersion)

        let freshEvidence: PronunciationAdvisoryEvidence
        switch result {
        case .candidate(let candidate):
            guard
                let alternative = neuralAlternative(for: candidate, normalizedWord: normalizedWord)
            else {
                freshEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt ? baseline.selectionReason : .invalidCandidate,
                    neuralShadowObservation: .invalidCandidate,
                    normalizedWord: normalizedWord,
                    alternatives: nonNeuralAlternatives,
                    in: baseline)
                break
            }
            let candidateIPA = normalizedIPA(alternative.ipa)
            let selectedIPA = normalizedIPA(decision.selectedIPA)
            if baseline.selectedCandidateID == alternative.candidateID {
                let agreesWithSelected = candidateIPA == selectedIPA
                freshEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt
                        ? baseline.selectionReason
                        : agreesWithSelected
                            ? .shadowAgreementSelected : .invalidCandidate,
                    neuralShadowObservation: agreesWithSelected
                        ? .agreementSelected : .selectedCandidateIDConflict,
                    normalizedWord: normalizedWord,
                    alternatives: nonNeuralAlternatives,
                    in: baseline)
                break
            }
            if let existing = baseline.alternatives.first(where: {
                $0.candidateID == alternative.candidateID
            }) {
                let agreesWithExistingAlternative = normalizedIPA(existing.ipa) == candidateIPA
                freshEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt
                        ? baseline.selectionReason
                        : agreesWithExistingAlternative
                            ? .shadowAgreementExistingAlternative
                            : .invalidCandidate,
                    neuralShadowObservation: agreesWithExistingAlternative
                        ? .agreementExistingAlternative
                        : .existingAlternativeCandidateIDConflict,
                    normalizedWord: normalizedWord,
                    alternatives: nonNeuralAlternatives,
                    in: baseline)
                break
            }
            if candidateIPA == selectedIPA {
                freshEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt
                        ? baseline.selectionReason : .shadowAgreementSelected,
                    neuralShadowObservation: .agreementSelected,
                    normalizedWord: normalizedWord,
                    alternatives: nonNeuralAlternatives,
                    in: baseline)
                break
            }
            if nonNeuralAlternatives.contains(where: {
                normalizedIPA($0.ipa) == candidateIPA
            }) {
                freshEvidence = replacingSelectionReason(
                    preservesInvalidOutputReceipt
                        ? baseline.selectionReason : .shadowAgreementExistingAlternative,
                    neuralShadowObservation: .agreementExistingAlternative,
                    normalizedWord: normalizedWord,
                    alternatives: nonNeuralAlternatives,
                    in: baseline)
                break
            }
            freshEvidence = PronunciationAdvisoryEvidence(
                category: baseline.category,
                selectedAuthority: baseline.selectedAuthority,
                selectedCandidateID: baseline.selectedCandidateID,
                alternatives: nonNeuralAlternatives + [alternative],
                selectionReason: preservesInvalidOutputReceipt
                    ? baseline.selectionReason : .shadowCandidate,
                overrideSuppressedAutomation: baseline.overrideSuppressedAutomation,
                policyVersion: baseline.policyVersion,
                neuralShadowNormalizedWord: normalizedWord,
                neuralShadowObservation: .candidate)
        case .rejected(let failure):
            freshEvidence = replacingSelectionReason(
                preservesInvalidOutputReceipt
                    ? baseline.selectionReason : selectionReason(for: failure),
                neuralShadowObservation: neuralShadowObservation(for: failure),
                normalizedWord: normalizedWord,
                alternatives: nonNeuralAlternatives,
                in: baseline)
        }

        guard evidence.neuralShadowObservation != nil else {
            return replacingAdvisoryEvidence(freshEvidence, in: decision)
        }
        if hasSameStableOutcome(evidence, freshEvidence) { return decision }

        var candidateIDs: Set<String> = []
        let retainedCandidates =
            (existingNeuralAlternatives
            + freshEvidence.alternatives.filter(claimsNeuralNamespace))
            .filter { candidateIDs.insert($0.candidateID).inserted }
            .prefix(2)
        let unstableEvidence = PronunciationAdvisoryEvidence(
            category: evidence.category,
            selectedAuthority: evidence.selectedAuthority,
            selectedCandidateID: evidence.selectedCandidateID,
            alternatives: nonNeuralAlternatives + Array(retainedCandidates),
            selectionReason: evidence.selectionReason,
            overrideSuppressedAutomation: evidence.overrideSuppressedAutomation,
            policyVersion: evidence.policyVersion,
            neuralShadowNormalizedWord: normalizedWord,
            neuralShadowObservation: .unstableEvaluation)
        return replacingAdvisoryEvidence(unstableEvidence, in: decision)
    }

    private static func neuralAlternative(
        for candidate: NeuralG2PCandidate,
        normalizedWord: String
    ) -> PronunciationAdvisoryEvidence.Alternative? {
        guard
            let ipa = NeuralG2PGovernedIdentity.validatedIPA(
                for: candidate,
                normalizedWord: normalizedWord)
        else {
            return nil
        }

        return PronunciationAdvisoryEvidence.Alternative(
            candidateID: candidate.candidateID,
            ipa: ipa,
            source: NeuralG2PGovernedIdentity.alternativeSource,
            authority: .uncertain,
            validation: .shadow,
            policyVersion: NeuralG2PGovernedIdentity.selectionPolicyVersion)
    }

    private static func claimsNeuralNamespace(
        _ alternative: PronunciationAdvisoryEvidence.Alternative
    ) -> Bool {
        NeuralG2PGovernedIdentity.claimsNamespace(
            source: alternative.source,
            selectionPolicyVersion: alternative.policyVersion)
    }

    private static func hasSameStableOutcome(
        _ lhs: PronunciationAdvisoryEvidence,
        _ rhs: PronunciationAdvisoryEvidence
    ) -> Bool {
        lhs.neuralShadowObservation == rhs.neuralShadowObservation
            && lhs.selectionReason == rhs.selectionReason
            && lhs.alternatives.filter(claimsNeuralNamespace)
                == rhs.alternatives.filter(claimsNeuralNamespace)
    }

    private static func selectionReason(
        for failure: NeuralG2PFailure
    ) -> PronunciationAdvisoryEvidence.SelectionReason {
        switch failure {
        case .unavailable:
            return .modelUnavailable
        case .integrity:
            return .modelIntegrityFailure
        case .inference, .cancelled:
            return .modelInferenceFailure
        case .tokenization, .decoding, .emptyOutput, .unsupportedOutput:
            return .invalidCandidate
        }
    }

    private static func neuralShadowObservation(
        for failure: NeuralG2PFailure
    ) -> PronunciationAdvisoryEvidence.NeuralShadowObservation {
        switch failure {
        case .unavailable:
            return .modelUnavailable
        case .integrity:
            return .modelIntegrityFailure
        case .inference, .cancelled:
            return .modelInferenceFailure
        case .tokenization, .decoding, .emptyOutput, .unsupportedOutput:
            return .invalidCandidate
        }
    }

    private static func replacingSelectionReason(
        _ selectionReason: PronunciationAdvisoryEvidence.SelectionReason,
        neuralShadowObservation: PronunciationAdvisoryEvidence.NeuralShadowObservation,
        normalizedWord: String,
        alternatives: [PronunciationAdvisoryEvidence.Alternative]? = nil,
        in evidence: PronunciationAdvisoryEvidence
    ) -> PronunciationAdvisoryEvidence {
        PronunciationAdvisoryEvidence(
            category: evidence.category,
            selectedAuthority: evidence.selectedAuthority,
            selectedCandidateID: evidence.selectedCandidateID,
            alternatives: alternatives ?? evidence.alternatives,
            selectionReason: selectionReason,
            overrideSuppressedAutomation: evidence.overrideSuppressedAutomation,
            policyVersion: evidence.policyVersion,
            neuralShadowNormalizedWord: normalizedWord,
            neuralShadowObservation: neuralShadowObservation)
    }

    private static func replacingAdvisoryEvidence(
        _ advisoryEvidence: PronunciationAdvisoryEvidence,
        in decision: PronunciationAuditDecision
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: decision.blockID,
            wordStart: decision.wordStart,
            wordEnd: decision.wordEnd,
            normalizedWord: decision.normalizedWord,
            sourceWord: decision.sourceWord,
            sourceContext: decision.sourceContext,
            selectedIPA: decision.selectedIPA,
            kokoroTokenIDs: decision.kokoroTokenIDs,
            source: decision.source,
            ruleID: decision.ruleID,
            rationale: decision.rationale,
            candidateID: decision.candidateID,
            candidatePackVersion: decision.candidatePackVersion,
            derivationBase: decision.derivationBase,
            derivationRuleID: decision.derivationRuleID,
            contextualEvidence: decision.contextualEvidence,
            advisoryEvidence: advisoryEvidence,
            chapterIndex: decision.chapterIndex,
            chapterRelativeAudioRange: decision.chapterRelativeAudioRange,
            bookRelativeAudioRange: decision.bookRelativeAudioRange,
            timingPrecision: decision.timingPrecision)
    }

    private static func normalizedIPA(_ ipa: String) -> String {
        ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func advisoryAlternatives(
        for normalizedWord: String,
        excluding selectedIPA: String
    ) -> [PronunciationAdvisoryEvidence.Alternative] {
        guard let vocabulary = try? KokoroPhonemeVocab() else { return [] }
        let selected = normalizedIPA(selectedIPA)
        let candidates = auditPack.alternatives(for: normalizedWord)
            .sorted { lhs, rhs in
                if lhs.sourceID != rhs.sourceID { return lhs.sourceID < rhs.sourceID }
                return lhs.candidateID < rhs.candidateID
            }

        var seenIPAs: Set<String> = []
        return candidates.compactMap { candidate in
            let ipa = normalizedIPA(candidate.ipa)
            guard !ipa.isEmpty,
                ipa != selected,
                seenIPAs.insert(ipa).inserted,
                (try? vocabulary.validatedIDs(forPhonemes: ipa)) != nil
            else {
                return nil
            }
            return PronunciationAdvisoryEvidence.Alternative(
                candidateID: candidate.candidateID,
                ipa: ipa,
                source: candidate.sourceID,
                authority: .uncertain,
                validation: .shadow,
                policyVersion: auditPack.auditPackVersion)
        }
    }

    private func isComparisonScoped(
        decision: PronunciationDecisionSeed,
        fallbackHits: [PronunciationFallbackHit],
        alternatives: [PronunciationAdvisoryEvidence.Alternative],
        isWatchWord: Bool
    ) -> Bool {
        if !alternatives.isEmpty || isWatchWord || decision.selectedIPA.isEmpty {
            return true
        }
        if decision.source == .fallback
            || fallbackHits.contains(where: {
                PronunciationAuditContext.normalizedWord($0.word) == decision.normalizedWord
            })
        {
            return true
        }
        if ContextualPronunciationFamilies.family(for: decision.normalizedWord) != nil {
            return true
        }
        if productionPack.hasExplicitCandidate(for: decision.normalizedWord)
            && productionPack.automaticCandidate(for: decision.normalizedWord) == nil
        {
            return true
        }
        // A title-cased token alone is ambiguous at a sentence boundary. It is
        // not sufficient evidence of a proper noun, so only an acronym gets
        // this no-other-signal comparison path.
        return isLikelyAcronym(decision.sourceWord)
            || PronunciationAuditContext.isRejectedRawG2POutput(decision.selectedIPA)
    }

    private func selectionReason(
        for decision: PronunciationDecisionSeed,
        hasAlternatives: Bool
    ) -> PronunciationAdvisoryEvidence.SelectionReason {
        switch decision.source {
        case .occurrenceOverride: return .occurrenceOverride
        case .bookOverride: return .bookOverride
        case .globalOverride: return .globalOverride
        case .epubInline, .epubLexicon: return .trustedLexicon
        case .builtInOverride: return hasAlternatives ? .sourceDisagreement : .trustedLexicon
        case .contextualHomograph:
            return decision.contextualEvidence?.familyState == .graduated
                ? .qualifiedDeterministicContext : .contextShadow
        case .fallback: return .deterministicFallback
        case .supplementalLexicon, .derivedMorphology, .monitoredLexicon:
            return hasAlternatives ? .sourceDisagreement : .trustedLexicon
        }
    }

    private func selectedAuthority(
        for decision: PronunciationDecisionSeed
    ) -> PronunciationAdvisoryEvidence.Authority {
        switch decision.source {
        case .fallback:
            return .uncertain
        case .contextualHomograph:
            return decision.contextualEvidence?.familyState == .graduated
                ? .qualified : .uncertain
        case .occurrenceOverride, .bookOverride, .globalOverride, .epubInline, .epubLexicon,
            .builtInOverride,
            .supplementalLexicon, .derivedMorphology, .monitoredLexicon:
            return .trusted
        }
    }

    private func isOverride(_ source: PronunciationAuditDecision.Source) -> Bool {
        switch source {
        case .occurrenceOverride, .bookOverride, .globalOverride, .epubInline, .epubLexicon,
            .builtInOverride:
            return true
        case .contextualHomograph, .supplementalLexicon, .derivedMorphology,
            .monitoredLexicon, .fallback:
            return false
        }
    }

    private func isLikelyAcronym(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count > 1 else { return false }
        return letters.allSatisfy(\.isUppercase)
    }

    private func normalizedIPA(_ ipa: String) -> String {
        ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
