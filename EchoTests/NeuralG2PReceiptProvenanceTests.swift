// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NeuralG2PReceiptProvenanceTests {
    // Hand-checked from these exact bytes: UTF-8
    // `echo.neural-g2p.candidate.v2`, then one 0x00 byte, then six UInt64-big-endian
    // length-prefixed UTF-8 fields in this order: canonical normalized word,
    // canonical IPA, model revision, conversion policy, validation policy, and
    // selection policy. These literals do not reuse production hashing.
    private static let exactCandidateID =
        "sha256:aa7069d4801f3e5e6b7b2685b844cc249b3feec9d1c1ab5fc532959948344fbe"
    private static let secondCandidateID =
        "sha256:641a307b9c79068cd5cbd36a822926364e8c1a7206b3da66395bf52743592e88"
    private static let thirdCandidateID =
        "sha256:4f5d16ab17bb584db4b3b17bdf6d97bb2d1f79fa181495b8e7707bf852cd254a"

    @Test func schemaFiveCompatibilityIdentityIsFrozenAsHistoricalLiterals() {
        #expect(
            PronunciationAdvisoryEvidence.schemaFiveNeuralSource
                == "mini-bart-g2p@f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06|mini-bart-arpabet-to-kokoro-v1|kokoro-vocab-validation-v1"
        )
        #expect(
            PronunciationAdvisoryEvidence.schemaFiveNeuralPolicyVersion
                == "mini-bart-g2p-beam5-max20-v1")
    }

    @Test func schemaFiveCompatibilityUsesItsFrozenKokoroVocabulary() {
        func evidence(
            ipa: String,
            source: String =
                "mini-bart-g2p@f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06|mini-bart-arpabet-to-kokoro-v1|kokoro-vocab-validation-v1",
            policyVersion: String = "mini-bart-g2p-beam5-max20-v1"
        ) -> PronunciationAdvisoryEvidence {
            PronunciationAdvisoryEvidence(
                category: .lexical,
                selectedAuthority: .uncertain,
                selectedCandidateID: nil,
                alternatives: [
                    .init(
                        candidateID: "sha256:" + String(repeating: "1", count: 64),
                        ipa: ipa,
                        source: source,
                        authority: .uncertain,
                        validation: .shadow,
                        policyVersion: policyVersion)
                ],
                selectionReason: .deterministicFallback,
                overrideSuppressedAutomation: false,
                policyVersion: "fixture-v1")
        }

        #expect(evidence(ipa: "\u{1D4A}").isValidLegacySchemaFive())
        #expect(!evidence(ipa: "🙂").isValidLegacySchemaFive())
        #expect(!evidence(ipa: "\u{1D4A}").isValid())
        #expect(
            evidence(
                ipa: "z",
                source: "aminibart-g2pology",
                policyVersion: "other-policy-v1"
            ).isValidLegacySchemaFive())
        #expect(
            evidence(
                ipa: "z",
                source: "Mini-BART-G2P@revision",
                policyVersion: "other-policy-v1"
            ).isValidLegacySchemaFive())
        #expect(
            !evidence(
                ipa: "z",
                source: "mini-bart-g2pology",
                policyVersion: "other-policy-v1"
            ).isValidLegacySchemaFive())
    }

    @Test func schemaFiveNeuralCandidateWithoutLaterBindingIsReadableButNotPromotable()
        throws
    {
        var root = try manifestJSON(with: [fallbackDecision()])
        root["schemaVersion"] = 5
        var decisions = try #require(root["decisions"] as? [[String: Any]])
        var evidence = try #require(decisions[0]["advisoryEvidence"] as? [String: Any])
        evidence["alternatives"] = [
            [
                "candidateID": "sha256:" + String(repeating: "1", count: 64),
                "ipa": "zizkwf",
                "source":
                    "mini-bart-g2p@f277d1e0597e7e7d33fa1d6d27d764bc4d7acb06|mini-bart-arpabet-to-kokoro-v1|kokoro-vocab-validation-v1",
                "authority": "uncertain",
                "validation": "shadow",
                "policyVersion": "mini-bart-g2p-beam5-max20-v1",
            ]
        ]
        evidence.removeValue(forKey: "neuralShadowObservation")
        evidence.removeValue(forKey: "neuralShadowNormalizedWord")
        decisions[0]["advisoryEvidence"] = evidence
        root["decisions"] = decisions

        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: JSONSerialization.data(withJSONObject: root))
        #expect(decoded.schemaVersion == 5)
        #expect(decoded.decisions.first?.advisoryEvidence?.alternatives.count == 1)
        #expect(decoded.decisions.first?.advisoryEvidence?.neuralShadowObservation == nil)
        #expect(throws: (any Error).self) { _ = try decoded.encoded() }
    }

    @Test func currentCandidateIdentityIsRecomputedFromWordIPAAndGovernedIdentity() throws {
        #expect(
            NeuralG2PGovernedIdentity.candidateID(
                normalizedWord: "Xyzqwf",
                ipa: "  zizkwf\n") == Self.exactCandidateID)

        let original = fallbackDecision()
        let exact = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "zizkwf")),
            to: original)
        #expect(exact.advisoryEvidence?.neuralShadowObservation == .candidate)
        #expect(
            exact.advisoryEvidence?.alternatives.map(\.candidateID) == [
                Self.exactCandidateID
            ])
        #expect(exact.selectedIPA == original.selectedIPA)
        #expect(exact.kokoroTokenIDs == original.kokoroTokenIDs)
        #expect(exact.source == original.source)
        #expect(exact.ruleID == original.ruleID)
        #expect(NarrationFileNaming.renderVersion == 25)

        let canonicalizedIPA = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "  zizkwf\n")),
            to: original)
        #expect(canonicalizedIPA.advisoryEvidence?.neuralShadowObservation == .candidate)
        #expect(canonicalizedIPA.advisoryEvidence?.alternatives.map(\.ipa) == ["zizkwf"])

        let forged = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(
                candidate(
                    id: "sha256:" + String(repeating: "a", count: 64),
                    ipa: "zizkwf")),
            to: original)
        #expect(forged.advisoryEvidence?.neuralShadowObservation == .invalidCandidate)
        #expect(forged.advisoryEvidence?.alternatives.isEmpty == true)

        let wrongWord = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "zizkwf")),
            to: fallbackDecision(word: "otherword"))
        #expect(wrongWord.advisoryEvidence?.neuralShadowObservation == .invalidCandidate)

        let wrongIPA = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "bæd")),
            to: original)
        #expect(wrongIPA.advisoryEvidence?.neuralShadowObservation == .invalidCandidate)

        let wrongIdentities = [
            candidate(
                id: Self.exactCandidateID,
                ipa: "zizkwf",
                modelRevision: String(repeating: "0", count: 40)),
            candidate(
                id: Self.exactCandidateID,
                ipa: "zizkwf",
                conversionPolicyVersion: "other-conversion"),
            candidate(
                id: Self.exactCandidateID,
                ipa: "zizkwf",
                validationPolicyVersion: "other-validation"),
            candidate(
                id: Self.exactCandidateID,
                ipa: "zizkwf",
                selectionPolicyVersion: "other-selection"),
        ]
        for wrongIdentity in wrongIdentities {
            let attached = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
                .candidate(wrongIdentity),
                to: original)
            #expect(attached.advisoryEvidence?.neuralShadowObservation == .invalidCandidate)
        }
    }

    @Test func currentManifestRejectsPersistedCandidateIdentityMutations() throws {
        let decision = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "zizkwf")),
            to: fallbackDecision())
        let root = try manifestJSON(with: [decision])
        #expect(root["schemaVersion"] as? Int == 6)
        let decisions = try #require(root["decisions"] as? [[String: Any]])
        let evidence = try #require(decisions[0]["advisoryEvidence"] as? [String: Any])
        #expect(evidence["neuralShadowNormalizedWord"] as? String == "xyzqwf")

        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: JSONSerialization.data(withJSONObject: root))
        #expect(decoded.decisions == [decision])

        var forgedID = root
        try mutateFirstNeuralAlternative(in: &forgedID) {
            $0["candidateID"] = "sha256:" + String(repeating: "a", count: 64)
        }

        var wrongWord = root
        try mutateFirstDecision(in: &wrongWord) { $0["normalizedWord"] = "otherword" }

        var wrongIPA = root
        try mutateFirstNeuralAlternative(in: &wrongIPA) { $0["ipa"] = "bæd" }

        var missingBoundWord = root
        try mutateFirstEvidence(in: &missingBoundWord) {
            $0.removeValue(forKey: "neuralShadowNormalizedWord")
        }

        var wrongBoundWord = root
        try mutateFirstEvidence(in: &wrongBoundWord) {
            $0["neuralShadowNormalizedWord"] = "otherword"
        }

        var wrongSource = root
        try mutateFirstNeuralAlternative(in: &wrongSource) {
            $0["source"] = "mini-bart-g2p@other-revision"
        }

        var wrongPolicy = root
        try mutateFirstNeuralAlternative(in: &wrongPolicy) {
            $0["policyVersion"] = "mini-bart-g2p-other-policy"
        }

        for malformed in [
            forgedID, wrongWord, wrongIPA, missingBoundWord, wrongBoundWord, wrongSource,
            wrongPolicy,
        ] {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: JSONSerialization.data(withJSONObject: malformed))
            }
        }
    }

    @Test func currentStableFailurePersistsAndRequiresItsBoundNormalizedWord() throws {
        let decision = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .rejected(.unavailable),
            to: fallbackDecision())
        let root = try manifestJSON(with: [decision])
        #expect(root["schemaVersion"] as? Int == 6)
        let decisions = try #require(root["decisions"] as? [[String: Any]])
        let evidence = try #require(decisions[0]["advisoryEvidence"] as? [String: Any])
        #expect(evidence["neuralShadowNormalizedWord"] as? String == "xyzqwf")
        #expect((evidence["alternatives"] as? [[String: Any]])?.isEmpty == true)

        var missingBoundWord = root
        try mutateFirstEvidence(in: &missingBoundWord) {
            $0.removeValue(forKey: "neuralShadowNormalizedWord")
        }
        var wrongBoundWord = root
        try mutateFirstEvidence(in: &wrongBoundWord) {
            $0["neuralShadowNormalizedWord"] = "otherword"
        }

        for malformed in [missingBoundWord, wrongBoundWord] {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: JSONSerialization.data(withJSONObject: malformed))
            }
        }
    }

    @Test func repeatedEvaluationIsIdempotentThenIrreversiblyUnstable() throws {
        let original = fallbackDecision()
        let first = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "zizkwf")),
            to: original)
        let repeated = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "zizkwf")),
            to: first)
        #expect(repeated == first)

        let unstable = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.secondCandidateID, ipa: "bæd")),
            to: repeated)
        #expect(
            unstable.advisoryEvidence?.neuralShadowObservation?.rawValue
                == "unstableEvaluation")
        #expect(
            Set(unstable.advisoryEvidence?.alternatives.map(\.candidateID) ?? [])
                == Set([
                    Self.exactCandidateID,
                    Self.secondCandidateID,
                ]))

        let later = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.thirdCandidateID, ipa: "bɛd")),
            to: unstable)
        #expect(later == unstable)
        #expect(later.advisoryEvidence?.isValid(for: later) == true)

        let root = try manifestJSON(with: [unstable])
        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: JSONSerialization.data(withJSONObject: root))
        #expect(decoded.decisions == [unstable])
    }

    @Test func instabilityRetainsOnlyGovernedCandidatesObservedBeforeTheConflict() {
        let original = fallbackDecision()
        let candidateFirst = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "zizkwf")),
            to: original)
        let candidateThenFailure = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .rejected(.unavailable),
            to: candidateFirst)
        #expect(
            candidateThenFailure.advisoryEvidence?.neuralShadowObservation?.rawValue
                == "unstableEvaluation")
        #expect(
            candidateThenFailure.advisoryEvidence?.alternatives.map(\.candidateID) == [
                Self.exactCandidateID
            ])
        #expect(candidateThenFailure.advisoryEvidence?.isValid(for: candidateThenFailure) == true)

        let failureFirst = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .rejected(.unavailable),
            to: original)
        let repeatedFailure = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .rejected(.unavailable),
            to: failureFirst)
        #expect(repeatedFailure == failureFirst)

        let failureThenCandidate = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "zizkwf")),
            to: failureFirst)
        #expect(
            failureThenCandidate.advisoryEvidence?.neuralShadowObservation?.rawValue
                == "unstableEvaluation")
        #expect(
            failureThenCandidate.advisoryEvidence?.alternatives.map(\.candidateID) == [
                Self.exactCandidateID
            ])
        #expect(failureThenCandidate.advisoryEvidence?.isValid(for: failureThenCandidate) == true)

        let failuresOnly = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .rejected(.integrity),
            to: failureFirst)
        #expect(
            failuresOnly.advisoryEvidence?.neuralShadowObservation?.rawValue
                == "unstableEvaluation")
        #expect(failuresOnly.advisoryEvidence?.alternatives.isEmpty == true)
        #expect(failuresOnly.advisoryEvidence?.isValid(for: failuresOnly) == true)
    }

    @Test func monitoredLexiconRawInvalidReceiptIsAnExactNeuralAttachmentNoOp() {
        let evidence = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: nil,
            alternatives: [],
            selectionReason: .trustedLexicon,
            overrideSuppressedAutomation: false,
            policyVersion: "fixture-v1")
        let decision = PronunciationAuditDecision(
            blockID: "monitored-invalid",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "xyzqwf",
            sourceWord: "Xyzqwf",
            sourceContext: "Xyzqwf",
            selectedIPA: "\u{0000}",
            kokoroTokenIDs: [],
            source: .monitoredLexicon,
            ruleID: "g2p.lexicon.xyzqwf",
            rationale: "Fixture.",
            advisoryEvidence: evidence)
        #expect(decision.isEvidenceOnlyInvalidOutputAdvisory)

        let attached = PronunciationCandidateAnalyzer.attachingNeuralShadowResult(
            .candidate(candidate(id: Self.exactCandidateID, ipa: "zizkwf")),
            to: decision)

        #expect(attached == decision)
        #expect(attached.isEvidenceOnlyInvalidOutputAdvisory)
    }

    @Test func reservedNeuralNamespaceUsesCaseInsensitiveTokenBoundaries() {
        let claimed: [(source: String, policy: String)] = [
            ("Mini-BART-G2P@revision", "ordinary-policy"),
            ("vendor|mini-bart-g2p:revision", "ordinary-policy"),
            ("vendor/MiNi-BaRt-G2P.policy", "ordinary-policy"),
            ("ordinary-source", "vendor|MINI-BART-G2P@policy"),
        ]
        for claimed in claimed {
            #expect(
                NeuralG2PGovernedIdentity.claimsNamespace(
                    source: claimed.source,
                    selectionPolicyVersion: claimed.policy))
        }

        let ordinary: [(source: String, policy: String)] = [
            ("aminibart-g2pology", "ordinary-policy"),
            ("mini-bart-g2pology", "ordinary-policy"),
            ("my-mini-bart-g2pish", "ordinary-policy"),
            ("émini-bart-g2p", "ordinary-policy"),
            ("ordinary-source", "my-mini-bart-g2pish"),
        ]
        for ordinary in ordinary {
            #expect(
                !NeuralG2PGovernedIdentity.claimsNamespace(
                    source: ordinary.source,
                    selectionPolicyVersion: ordinary.policy))
        }
    }

    @Test func unstableObservationDecodesAndHasALocalizedQAName() throws {
        let observation = try JSONDecoder().decode(
            PronunciationAdvisoryEvidence.NeuralShadowObservation.self,
            from: Data(#""unstableEvaluation""#.utf8))

        #expect(
            NarrationQAReviewView.localizedNeuralShadowName(observation)
                == "Unstable evaluation")
    }

    private func candidate(
        id: String,
        ipa: String,
        modelRevision: String = NeuralG2PGovernedIdentity.modelRevision,
        conversionPolicyVersion: String = NeuralG2PGovernedIdentity.conversionPolicyVersion,
        validationPolicyVersion: String = NeuralG2PGovernedIdentity.validationPolicyVersion,
        selectionPolicyVersion: String = NeuralG2PGovernedIdentity.selectionPolicyVersion
    ) -> NeuralG2PCandidate {
        NeuralG2PCandidate(
            candidateID: id,
            ipa: ipa,
            modelRevision: modelRevision,
            conversionPolicyVersion: conversionPolicyVersion,
            validationPolicyVersion: validationPolicyVersion,
            selectionPolicyVersion: selectionPolicyVersion)
    }

    private func fallbackDecision(word: String = "xyzqwf") -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: "fallback",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: word,
            sourceWord: word,
            sourceContext: word,
            selectedIPA: "ə",
            kokoroTokenIDs: [1],
            source: .fallback,
            ruleID: "g2p.fallback.\(word)",
            rationale: "Fixture.",
            advisoryEvidence: PronunciationAdvisoryEvidence(
                category: .lexical,
                selectedAuthority: .uncertain,
                selectedCandidateID: nil,
                alternatives: [],
                selectionReason: .deterministicFallback,
                overrideSuppressedAutomation: false,
                policyVersion: "fixture-v1"))
    }

    private func manifestJSON(
        with decisions: [PronunciationAuditDecision]
    ) throws -> [String: Any] {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 22,
            voice: VoiceID("af_heart"),
            captureCoverage: .incompleteEvidence,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: decisions,
            diagnostics: [])
        return try #require(
            JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any])
    }

    private func mutateFirstDecision(
        in root: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) throws {
        var decisions = try #require(root["decisions"] as? [[String: Any]])
        mutation(&decisions[0])
        root["decisions"] = decisions
    }

    private func mutateFirstNeuralAlternative(
        in root: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) throws {
        try mutateFirstEvidence(in: &root) { evidence in
            var alternatives = evidence["alternatives"] as! [[String: Any]]
            mutation(&alternatives[0])
            evidence["alternatives"] = alternatives
        }
    }

    private func mutateFirstEvidence(
        in root: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) throws {
        try mutateFirstDecision(in: &root) { decision in
            var evidence = decision["advisoryEvidence"] as! [String: Any]
            mutation(&evidence)
            decision["advisoryEvidence"] = evidence
        }
    }
}
