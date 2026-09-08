// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Portable, advisory-only provenance for a pronunciation decision. This does
/// not select a pronunciation or alter audio generation; it records the
/// versioned alternatives that a later policy may safely inspect.
nonisolated struct PronunciationAdvisoryEvidence: Codable, Equatable, Sendable {
    /// Schema 5 is an historical decoding contract. These literals must not
    /// follow the current neural identity if a later schema changes it.
    static let schemaFiveNeuralSource =
        "mini-bart-g2p@f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06"
        + "|mini-bart-arpabet-to-kokoro-v1|kokoro-vocab-validation-v1"
    static let schemaFiveNeuralPolicyVersion = "mini-bart-g2p-beam5-max20-v1"

    enum Authority: String, Codable, Sendable {
        case trusted
        case qualified
        case uncertain
    }

    enum Category: String, Codable, Sendable {
        case lexical
        case contextual
        case acoustic
    }

    enum Validation: String, Codable, Sendable {
        case eligible
        case shadow
        case rejected
    }

    enum SelectionReason: String, Codable, Sendable {
        case occurrenceOverride
        case bookOverride
        case globalOverride
        case qualifiedDeterministicContext
        case trustedLexicon
        case qualifiedNeuralOOV
        case deterministicFallback
        case sourceDisagreement
        case shadowCandidate
        case shadowAgreementSelected
        case shadowAgreementExistingAlternative
        case invalidCandidate
        case modelUnavailable
        case modelIntegrityFailure
        case modelInferenceFailure
        case contextShadow
        case contextUnavailable
        case acousticRetryRejected
    }

    enum NeuralShadowObservation: String, Codable, Sendable {
        case candidate
        case unstableEvaluation
        case agreementSelected
        case agreementExistingAlternative
        case selectedCandidateIDConflict
        case existingAlternativeCandidateIDConflict
        case invalidCandidate
        case modelUnavailable
        case modelIntegrityFailure
        case modelInferenceFailure
    }

    struct Alternative: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let source: String
        let authority: Authority
        let validation: Validation
        let policyVersion: String
    }

    let category: Category
    let selectedAuthority: Authority
    let selectedCandidateID: String?
    let alternatives: [Alternative]
    let selectionReason: SelectionReason
    let overrideSuppressedAutomation: Bool
    let policyVersion: String
    let neuralShadowNormalizedWord: String?
    let neuralShadowObservation: NeuralShadowObservation?

    init(
        category: Category,
        selectedAuthority: Authority,
        selectedCandidateID: String?,
        alternatives: [Alternative],
        selectionReason: SelectionReason,
        overrideSuppressedAutomation: Bool,
        policyVersion: String,
        neuralShadowNormalizedWord: String? = nil,
        neuralShadowObservation: NeuralShadowObservation? = nil
    ) {
        self.category = category
        self.selectedAuthority = selectedAuthority
        self.selectedCandidateID = selectedCandidateID
        self.alternatives = alternatives.sorted(by: Self.isOrderedBefore)
        self.selectionReason = selectionReason
        self.overrideSuppressedAutomation = overrideSuppressedAutomation
        self.policyVersion = policyVersion
        self.neuralShadowNormalizedWord = neuralShadowNormalizedWord
        self.neuralShadowObservation = neuralShadowObservation
    }

    /// Current-schema evidence recomputes every governed candidate identity
    /// from its persisted word and canonical IPA.
    func isValid() -> Bool {
        guard hasValidBaseShape(claimsNeuralNamespace: Self.claimsNeuralNamespace) else {
            return false
        }
        let neuralAlternatives = alternatives.filter(Self.claimsNeuralNamespace)
        switch neuralShadowObservation {
        case nil:
            guard neuralShadowNormalizedWord == nil, neuralAlternatives.isEmpty else {
                return false
            }
        case .some(.candidate):
            guard neuralAlternatives.count == 1 else { return false }
        case .some(.unstableEvaluation):
            guard neuralAlternatives.count <= 2 else { return false }
        case .some(.agreementSelected), .some(.agreementExistingAlternative),
            .some(.selectedCandidateIDConflict), .some(.existingAlternativeCandidateIDConflict),
            .some(.invalidCandidate), .some(.modelUnavailable), .some(.modelIntegrityFailure),
            .some(.modelInferenceFailure):
            guard neuralAlternatives.isEmpty else { return false }
        }
        if neuralShadowObservation != nil {
            guard let word = neuralShadowNormalizedWord,
                !word.isEmpty,
                PronunciationAuditContext.normalizedWord(word) == word,
                neuralAlternatives.allSatisfy({
                    Self.isCurrentGovernedNeuralShadowAlternative($0, normalizedWord: word)
                })
            else {
                return false
            }
        }
        return hasValidNeuralShadowObservation(
            claimsNeuralNamespace: Self.claimsNeuralNamespace)
    }

    /// Schema 5 predated word-bound candidate IDs. Its full advisory shape is
    /// readable only under this explicit legacy contract and is never used to
    /// validate a schema-6 projection.
    func isValidLegacySchemaFive() -> Bool {
        guard
            hasValidBaseShape(
                claimsNeuralNamespace: Self.claimsSchemaFiveNeuralNamespace),
            neuralShadowNormalizedWord == nil
        else { return false }
        let neuralAlternatives = alternatives.filter(Self.claimsSchemaFiveNeuralNamespace)
        guard neuralAlternatives.allSatisfy(Self.isLegacyGovernedNeuralShadowAlternative)
        else {
            return false
        }
        switch neuralShadowObservation {
        case nil:
            guard neuralAlternatives.count <= 1 else { return false }
        case .some(.candidate):
            guard neuralAlternatives.count == 1 else { return false }
        case .some(.unstableEvaluation):
            return false
        case .some(.agreementSelected), .some(.agreementExistingAlternative),
            .some(.selectedCandidateIDConflict), .some(.existingAlternativeCandidateIDConflict),
            .some(.invalidCandidate), .some(.modelUnavailable), .some(.modelIntegrityFailure),
            .some(.modelInferenceFailure):
            guard neuralAlternatives.isEmpty else { return false }
        }
        return hasValidNeuralShadowObservation(
            claimsNeuralNamespace: Self.claimsSchemaFiveNeuralNamespace)
    }

    private func hasValidBaseShape(
        claimsNeuralNamespace: (Alternative) -> Bool
    ) -> Bool {
        let normalizedPolicyVersion = policyVersion.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !normalizedPolicyVersion.isEmpty,
            normalizedPolicyVersion == policyVersion,
            alternatives == alternatives.sorted(by: Self.isOrderedBefore)
        else {
            return false
        }

        var candidateIDs: Set<String> = []
        if let selectedCandidateID {
            candidateIDs.insert(
                selectedCandidateID.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var ipas: Set<String> = []
        for alternative in alternatives {
            let candidateID = alternative.candidateID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let ipa = Self.normalizedIPA(alternative.ipa)
            let source = alternative.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let alternativePolicyVersion = alternative.policyVersion.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !candidateID.isEmpty,
                candidateID == alternative.candidateID,
                !ipa.isEmpty,
                !source.isEmpty,
                source == alternative.source,
                !alternativePolicyVersion.isEmpty,
                alternativePolicyVersion == alternative.policyVersion,
                candidateIDs.insert(candidateID).inserted,
                ipas.insert(ipa).inserted
            else {
                return false
            }
        }
        let neuralAlternatives = alternatives.filter(claimsNeuralNamespace)
        guard neuralAlternatives.count <= 2 else { return false }
        return selectedCandidateID.map {
            !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? true
    }

    /// Current evidence is meaningful only when its accepted identity and
    /// neural word binding match the exact synthesis decision stored beside it.
    func isValid(for decision: PronunciationAuditDecision) -> Bool {
        guard isValid(),
            neuralShadowObservation == nil
                || neuralShadowNormalizedWord == decision.normalizedWord,
            selectedCandidateID == decision.candidateID,
            selectedAuthority == Self.expectedAuthority(for: decision)
        else {
            return false
        }
        return hasValidDecisionBinding(decision)
    }

    func isValidLegacySchemaFive(for decision: PronunciationAuditDecision) -> Bool {
        guard isValidLegacySchemaFive(),
            selectedCandidateID == decision.candidateID,
            selectedAuthority == Self.expectedAuthority(for: decision)
        else {
            return false
        }
        return hasValidDecisionBinding(decision)
    }

    private func hasValidDecisionBinding(_ decision: PronunciationAuditDecision) -> Bool {
        if let rawInvalidClassification = rawInvalidClassification(
            for: decision,
            advisoryEvidenceIsValid: true)
        {
            guard case .verified(let expectedSelectionReason) = rawInvalidClassification,
                decision.kokoroTokenIDs.isEmpty,
                decision.chapterRelativeAudioRange == nil,
                decision.bookRelativeAudioRange == nil,
                decision.timingPrecision == nil,
                selectionReason == expectedSelectionReason
            else {
                return false
            }
        } else if neuralShadowObservation != nil,
            selectionReason == .deterministicFallback
        {
            return false
        }

        // Evidence-only advisories intentionally accept no candidate. The
        // synthesized decision IPA may still appear among the alternatives,
        // but it is not an advisory selection and therefore cannot collide.
        guard selectedCandidateID != nil else { return true }

        let selectedIPA = Self.normalizedIPA(decision.selectedIPA)
        guard !selectedIPA.isEmpty else { return false }
        return !alternatives.contains { alternative in
            Self.normalizedIPA(alternative.ipa) == selectedIPA
        }
    }

    private func hasValidNeuralShadowObservation(
        claimsNeuralNamespace: (Alternative) -> Bool
    ) -> Bool {
        guard let neuralShadowObservation else { return true }
        guard category != .acoustic,
            selectedAuthority == .uncertain,
            !overrideSuppressedAutomation
        else {
            return false
        }

        switch neuralShadowObservation {
        case .candidate:
            return hasCompatibleReason(.shadowCandidate)
                && !alternatives.filter(claimsNeuralNamespace).isEmpty
        case .unstableEvaluation:
            switch selectionReason {
            case .shadowCandidate:
                return !alternatives.filter(claimsNeuralNamespace).isEmpty
            case .shadowAgreementExistingAlternative:
                return alternatives.contains { !claimsNeuralNamespace($0) }
            case .shadowAgreementSelected, .invalidCandidate, .modelUnavailable,
                .modelIntegrityFailure, .modelInferenceFailure:
                return true
            case .deterministicFallback:
                return category == .lexical && selectedCandidateID == nil
            case .occurrenceOverride, .bookOverride, .globalOverride,
                .qualifiedDeterministicContext, .trustedLexicon, .qualifiedNeuralOOV,
                .sourceDisagreement, .contextShadow, .contextUnavailable,
                .acousticRetryRejected:
                return false
            }
        case .agreementSelected:
            return selectionReason == .shadowAgreementSelected
        case .agreementExistingAlternative:
            return hasCompatibleReason(.shadowAgreementExistingAlternative)
                && !alternatives.isEmpty
        case .selectedCandidateIDConflict:
            return selectionReason == .invalidCandidate && selectedCandidateID != nil
        case .existingAlternativeCandidateIDConflict:
            return hasCompatibleReason(.invalidCandidate)
                && !alternatives.isEmpty
        case .invalidCandidate:
            return hasCompatibleReason(.invalidCandidate)
        case .modelUnavailable:
            return hasCompatibleReason(.modelUnavailable)
        case .modelIntegrityFailure:
            return hasCompatibleReason(.modelIntegrityFailure)
        case .modelInferenceFailure:
            return hasCompatibleReason(.modelInferenceFailure)
        }
    }

    private func hasCompatibleReason(_ reason: SelectionReason) -> Bool {
        selectionReason == reason
            || (selectionReason == .deterministicFallback
                && category == .lexical
                && selectedAuthority == .uncertain
                && selectedCandidateID == nil
                && !overrideSuppressedAutomation)
    }

    private static func claimsNeuralNamespace(_ alternative: Alternative) -> Bool {
        NeuralG2PGovernedIdentity.claimsNamespace(
            source: alternative.source,
            selectionPolicyVersion: alternative.policyVersion)
    }

    private static func isLegacyGovernedNeuralShadowAlternative(
        _ alternative: Alternative
    ) -> Bool {
        alternative.authority == .uncertain
            && alternative.validation == .shadow
            && alternative.source == schemaFiveNeuralSource
            && alternative.policyVersion == schemaFiveNeuralPolicyVersion
            && hasValidSchemaFiveCandidateIDSyntax(alternative.candidateID)
            && isValidSchemaFiveKokoroIPA(alternative.ipa)
    }

    private static func isCurrentGovernedNeuralShadowAlternative(
        _ alternative: Alternative,
        normalizedWord: String
    ) -> Bool {
        alternative.authority == .uncertain
            && alternative.validation == .shadow
            && alternative.source == NeuralG2PGovernedIdentity.alternativeSource
            && alternative.policyVersion == NeuralG2PGovernedIdentity.selectionPolicyVersion
            && NeuralG2PGovernedIdentity.hasValidCandidateIDSyntax(alternative.candidateID)
            && NeuralG2PGovernedIdentity.normalizedKokoroIPA(alternative.ipa)
                == alternative.ipa
            && NeuralG2PGovernedIdentity.candidateID(
                normalizedWord: normalizedWord,
                ipa: alternative.ipa) == alternative.candidateID
    }

    private static func claimsSchemaFiveNeuralNamespace(_ alternative: Alternative) -> Bool {
        alternative.source.hasPrefix("mini-bart-g2p")
            || alternative.policyVersion.hasPrefix("mini-bart-g2p")
    }

    private static func hasValidSchemaFiveCandidateIDSyntax(_ candidateID: String) -> Bool {
        let prefix = "sha256:"
        guard candidateID.hasPrefix(prefix) else { return false }
        let digest = candidateID.dropFirst(prefix.count)
        return digest.utf8.count == 64
            && digest.utf8.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
    }

    private static func isValidSchemaFiveKokoroIPA(_ ipa: String) -> Bool {
        let normalized = ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == ipa else { return false }
        return normalized.unicodeScalars.allSatisfy {
            schemaFiveKokoroVocabularyScalars.contains($0.value)
        }
    }

    // Literal scalar inventory from the schema-5 Kokoro vocabulary snapshot.
    // It is intentionally independent of the current bundled vocabulary file.
    private static let schemaFiveKokoroVocabularyScalars: Set<UInt32> = [
        0x0020, 0x0021, 0x0022, 0x0028, 0x0029, 0x002C, 0x002E, 0x003A, 0x003B,
        0x003F, 0x0041, 0x0049, 0x004F, 0x0051, 0x0053, 0x0054, 0x0057, 0x0059,
        0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0068, 0x0069, 0x006A,
        0x006B, 0x006C, 0x006D, 0x006E, 0x006F, 0x0070, 0x0071, 0x0072, 0x0073,
        0x0074, 0x0075, 0x0076, 0x0077, 0x0078, 0x0079, 0x007A, 0x00E6, 0x00E7,
        0x00F0, 0x00F8, 0x014B, 0x0153, 0x0250, 0x0251, 0x0252, 0x0254, 0x0255,
        0x0256, 0x0259, 0x025A, 0x025B, 0x025C, 0x025F, 0x0261, 0x0263, 0x0264,
        0x0265, 0x0268, 0x026A, 0x026F, 0x0270, 0x0272, 0x0273, 0x0274, 0x0278,
        0x0279, 0x027B, 0x027D, 0x027E, 0x0281, 0x0282, 0x0283, 0x0288, 0x028A,
        0x028B, 0x028C, 0x028E, 0x0292, 0x0294, 0x029D, 0x02A3, 0x02A4, 0x02A5,
        0x02A6, 0x02A7, 0x02A8, 0x02B0, 0x02B2, 0x02C8, 0x02CC, 0x02D0, 0x0303,
        0x03B2, 0x03B8, 0x03C7, 0x1D4A, 0x1D5D, 0x1D7B, 0x2014, 0x201C, 0x201D,
        0x2026, 0x2192, 0x2193, 0x2197, 0x2198, 0xAB67,
    ]

    private func rawInvalidClassification(
        for decision: PronunciationAuditDecision,
        advisoryEvidenceIsValid: Bool
    ) -> InvalidG2PAuditReceipt.Classification? {
        InvalidG2PAuditReceipt.classification(
            normalizedWord: decision.normalizedWord,
            sourceWord: decision.sourceWord,
            selectedIPA: decision.selectedIPA,
            source: decision.source,
            ruleID: decision.ruleID,
            candidateID: decision.candidateID,
            candidatePackVersion: decision.candidatePackVersion,
            derivationBase: decision.derivationBase,
            derivationRuleID: decision.derivationRuleID,
            contextualEvidence: decision.contextualEvidence,
            advisoryEvidence: self,
            advisoryEvidenceIsValid: advisoryEvidenceIsValid)
    }

    private static func isOrderedBefore(_ lhs: Alternative, _ rhs: Alternative) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.candidateID != rhs.candidateID { return lhs.candidateID < rhs.candidateID }
        if lhs.ipa != rhs.ipa { return lhs.ipa < rhs.ipa }
        if lhs.authority != rhs.authority { return lhs.authority.rawValue < rhs.authority.rawValue }
        if lhs.validation != rhs.validation {
            return lhs.validation.rawValue < rhs.validation.rawValue
        }
        return lhs.policyVersion < rhs.policyVersion
    }

    private static func normalizedIPA(_ ipa: String) -> String {
        ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expectedAuthority(
        for decision: PronunciationAuditDecision
    ) -> Authority {
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
}

/// Issue-local metadata that cannot be reconstructed after advisory decisions
/// are grouped into one review row. The advisory receipt stays unchanged so it
/// can continue to round-trip through audit manifests and older decoders.
nonisolated struct PronunciationAdvisoryIssueEvidence: Codable, Equatable, Sendable {
    struct SelectedCandidate: Codable, Equatable, Sendable {
        let candidateID: String
        let ipa: String
        let source: PronunciationAuditDecision.Source
        let authority: PronunciationAdvisoryEvidence.Authority
        let validation: PronunciationAdvisoryEvidence.Validation
    }

    let advisoryEvidence: PronunciationAdvisoryEvidence
    let occurrenceCount: Int
    /// Builder-authored metadata for the accepted decision. Older advisory
    /// envelopes and evidence-only decisions legitimately omit this field.
    let selectedCandidate: SelectedCandidate?

    init(
        advisoryEvidence: PronunciationAdvisoryEvidence,
        occurrenceCount: Int,
        selectedCandidate: SelectedCandidate? = nil
    ) {
        self.advisoryEvidence = advisoryEvidence
        self.occurrenceCount = occurrenceCount
        self.selectedCandidate = selectedCandidate
    }

    func isValid() -> Bool {
        guard occurrenceCount > 0, advisoryEvidence.isValid() else { return false }
        guard let selectedCandidate else { return true }

        let candidateID = selectedCandidate.candidateID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIPA = Self.normalizedIPA(selectedCandidate.ipa)
        guard !candidateID.isEmpty,
            !selectedIPA.isEmpty,
            !selectedCandidate.source.rawValue.isEmpty,
            selectedCandidate.validation == .eligible,
            Self.authorityIsValid(
                selectedCandidate.authority,
                for: selectedCandidate.source),
            advisoryEvidence.selectedCandidateID == selectedCandidate.candidateID,
            advisoryEvidence.selectedAuthority == selectedCandidate.authority
        else {
            return false
        }

        return !advisoryEvidence.alternatives.contains { alternative in
            alternative.candidateID == selectedCandidate.candidateID
                || Self.normalizedIPA(alternative.ipa) == selectedIPA
        }
    }

    static func normalizedIPA(_ ipa: String) -> String {
        ipa.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func authorityIsValid(
        _ authority: PronunciationAdvisoryEvidence.Authority,
        for source: PronunciationAuditDecision.Source
    ) -> Bool {
        switch source {
        case .fallback:
            return authority == .uncertain
        case .contextualHomograph:
            return authority == .qualified || authority == .uncertain
        case .occurrenceOverride, .bookOverride, .globalOverride, .epubInline, .epubLexicon,
            .builtInOverride,
            .supplementalLexicon, .derivedMorphology, .monitoredLexicon:
            return authority == .trusted
        }
    }
}
