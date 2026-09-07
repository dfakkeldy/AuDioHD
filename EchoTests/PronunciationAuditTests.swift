// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationAuditTests {
    @Test func diagnosticReasonVocabularyIncludesRejectedCurrencyNormalization() {
        let reasons: Set<PronunciationAuditDiagnostic.Reason> = [
            .spokenSurfaceMismatch,
            .phonemeSequenceMismatch,
            .decisionEvidenceMismatch,
            .incompleteRender,
            .qualityRejected,
            .missingContextualEvidence,
            .currencyNormalizationRejected,
        ]

        #expect(
            reasons.map(\.rawValue).sorted() == [
                "currencyNormalizationRejected",
                "decisionEvidenceMismatch",
                "incompleteRender",
                "missingContextualEvidence",
                "phonemeSequenceMismatch",
                "qualityRejected",
                "spokenSurfaceMismatch",
            ])
    }

    private static let schemaThreeManifestJSON = #"""
        {
          "schemaVersion": 3,
          "renderVersion": 15,
          "voice": "af_heart",
          "chapterVoices": {},
          "coverage": "complete",
          "legacyChapterIndexes": [],
          "audiobookFileName": "book.m4b",
          "audiobookSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "listeningReelFileName": null,
          "listeningReelSHA256": null,
          "watchCounts": {},
          "decisions": [],
          "diagnostics": []
        }
        """#

    private func advisoryEvidence(
        alternatives: [PronunciationAdvisoryEvidence.Alternative] = [
            .init(
                candidateID: "record.noun",
                ipa: "ɹˈɛkəɹd",
                source: "fixture",
                authority: .qualified,
                validation: .shadow,
                policyVersion: "policy-v1")
        ]
    ) -> PronunciationAdvisoryEvidence {
        PronunciationAdvisoryEvidence(
            category: .contextual,
            selectedAuthority: .qualified,
            selectedCandidateID: "record.verb",
            alternatives: alternatives,
            selectionReason: .qualifiedDeterministicContext,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
    }

    private func monitoredLexiconAdvisoryEvidence() -> PronunciationAdvisoryEvidence {
        PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: "record.verb",
            alternatives: [
                .init(
                    candidateID: "record.noun",
                    ipa: "ɹˈɛkəɹd",
                    source: "fixture",
                    authority: .qualified,
                    validation: .shadow,
                    policyVersion: "policy-v1")
            ],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
    }

    private func decision(
        word: String,
        ruleID: String,
        chapterIndex: Int,
        blockID: String? = nil,
        range: PronunciationAuditDecision.AudioRange? = .init(start: 1, end: 1.4)
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: blockID ?? "s\(chapterIndex)-b0",
            wordStart: 2,
            wordEnd: 2,
            normalizedWord: word,
            sourceWord: word,
            sourceContext: "The result was \(word) in this bounded context",
            selectedIPA: "ə",
            kokoroTokenIDs: [11, 22, 33],
            source: .monitoredLexicon,
            ruleID: ruleID,
            rationale: "A stable test rationale for \(word).",
            chapterIndex: chapterIndex,
            chapterRelativeAudioRange: range,
            bookRelativeAudioRange: range.map {
                .init(
                    start: Double(chapterIndex * 10) + $0.start,
                    end: Double(chapterIndex * 10) + $0.end)
            },
            timingPrecision: range == nil ? nil : .exactSynthesisWord)
    }

    private func invalidRawG2PDecision(
        source: PronunciationAuditDecision.Source = .fallback,
        ruleID: String = "g2p.fallback.ordinary",
        advisoryEvidence: PronunciationAdvisoryEvidence? = nil,
        chapterRelativeAudioRange: PronunciationAuditDecision.AudioRange? = nil,
        bookRelativeAudioRange: PronunciationAuditDecision.AudioRange? = nil,
        timingPrecision: PronunciationAuditDecision.TimingPrecision? = nil
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: "invalid-g2p",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "ordinary",
            sourceWord: "ordinary",
            sourceContext: "ordinary",
            selectedIPA: "\u{0000}",
            kokoroTokenIDs: [],
            source: source,
            ruleID: ruleID,
            rationale: "Raw G2P output was rejected.",
            advisoryEvidence: advisoryEvidence
                ?? .init(
                    category: .lexical,
                    selectedAuthority: .uncertain,
                    selectedCandidateID: nil,
                    alternatives: [],
                    selectionReason: .deterministicFallback,
                    overrideSuppressedAutomation: false,
                    policyVersion: "fixture-v1"),
            chapterRelativeAudioRange: chapterRelativeAudioRange,
            bookRelativeAudioRange: bookRelativeAudioRange,
            timingPrecision: timingPrecision)
    }

    private func manifest(with decisions: [PronunciationAuditDecision])
        -> PronunciationAuditManifest
    {
        PronunciationAuditManifest.make(
            renderVersion: 15,
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
    }

    private func diagnostic(
        chapterIndex: Int = 1
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: .spokenSurfaceMismatch,
            blockID: "s\(chapterIndex)-b0",
            chunkIndex: 0,
            chapterIndex: chapterIndex,
            expectedDisplayText: "verified filesystem",
            reconstructedSpokenSurface: "verified file system",
            fallbackHits: [])
    }

    private func contextualEvidence(
        availability: ContextualModelAvailability = .available,
        failure: ContextualModelFailure? = nil
    ) -> ContextualPronunciationEvidence {
        ContextualPronunciationEvidence(
            occurrenceID: ContextualPronunciationOccurrenceID.make(
                blockID: "context", wordStart: 1, wordEnd: 1, normalizedWord: "record"),
            familyID: "record",
            candidatePackVersion: ContextualPronunciationFamilies.candidatePackVersion,
            submittedCandidateIDs: ["record.noun", "record.verb"],
            deterministicCandidateID: "record.noun",
            deterministicRuleID: "record.noun.fixture",
            deterministicStrength: .definitive,
            modelCandidateID: availability == .available && failure == nil
                ? "record.verb"
                : nil,
            modelAbstained: false,
            modelAvailability: availability,
            modelFailure: failure,
            familyState: .shadow,
            acceptanceReason: failure != nil
                ? .shadowModelFailure
                : availability == .available
                    ? .shadowObserved
                    : availability == .notRequested ? .shadowNotRequested : .shadowModelUnavailable,
            promptSchemaVersion: ContextualPronunciationFamilies.promptSchemaVersion,
            platform: "test",
            osBuild: "test-build",
            qualifiedRuntimeFamilyID: "test-runtime",
            humanCandidateID: nil,
            humanCorrectionScope: nil,
            isLimited: false)
    }

    private func contextualDecision(
        evidence: ContextualPronunciationEvidence?,
        source: PronunciationAuditDecision.Source = .contextualHomograph
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: "context",
            wordStart: 1,
            wordEnd: 1,
            normalizedWord: "record",
            sourceWord: "record",
            sourceContext: "Please record this bounded fixture",
            selectedIPA: "ɹəkˈɔɹd",
            kokoroTokenIDs: [1, 2, 3],
            source: source,
            ruleID: "homograph.record.verb",
            rationale: "Deterministic production decision.",
            candidateID:
                source == .supplementalLexicon || source == .derivedMorphology
                ? "record.verb"
                : nil,
            candidatePackVersion:
                source == .supplementalLexicon || source == .derivedMorphology
                ? ContextualPronunciationFamilies.candidatePackVersion
                : nil,
            derivationBase: source == .derivedMorphology ? "record" : nil,
            derivationRuleID:
                source == .derivedMorphology
                ? "morphology.record.fixture"
                : nil,
            contextualEvidence: evidence,
            chapterIndex: 0,
            chapterRelativeAudioRange: .init(start: 1, end: 1.2),
            bookRelativeAudioRange: .init(start: 1, end: 1.2),
            timingPrecision: .exactSynthesisWord)
    }

    @Test func englishKeyNormalizationCanonicalizesInternalCurlyApostrophe() {
        #expect(PronunciationAuditContext.normalizedWord("aujourd'hui") == "aujourd'hui")
        #expect(PronunciationAuditContext.normalizedWord("aujourd’hui") == "aujourd'hui")
        #expect(PronunciationAuditContext.normalizedWord("Aujourd’hui") == "aujourd'hui")
    }

    @Test func manifestPreservesStableEvidenceAndCountsEveryWatchedWord() {
        let second = decision(
            word: "filesystem", ruleID: "override.builtin.filesystem", chapterIndex: 2)
        let first = decision(word: "verified", ruleID: "g2p.lexicon.verified", chapterIndex: 0)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/private/books/question-machine.m4b"),
            reelURL: URL(fileURLWithPath: "/private/books/question-machine.pronunciation-reel.m4b"),
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: String(repeating: "b", count: 64),
            watchWords: ["verified", "startable", "filesystem"],
            decisions: [first, second],
            diagnostics: [])

        #expect(manifest.schemaVersion == 6)
        #expect(manifest.renderVersion == 11)
        #expect(manifest.voice == "af_heart")
        #expect(manifest.coverage == .complete)
        #expect(manifest.legacyChapterIndexes.isEmpty)
        #expect(manifest.audiobookFileName == "question-machine.m4b")
        #expect(manifest.audiobookSHA256 == String(repeating: "a", count: 64))
        #expect(manifest.listeningReelFileName == "question-machine.pronunciation-reel.m4b")
        #expect(manifest.listeningReelSHA256 == String(repeating: "b", count: 64))
        #expect(manifest.watchCounts == ["filesystem": 1, "startable": 0, "verified": 1])
        #expect(manifest.decisions == [first, second])
        #expect(manifest.decisions[0].chapterRelativeAudioRange == .init(start: 1, end: 1.4))
        #expect(manifest.decisions[0].bookRelativeAudioRange == .init(start: 1, end: 1.4))
        #expect(manifest.decisions[0].kokoroTokenIDs == [11, 22, 33])
        #expect(manifest.diagnostics.isEmpty)
    }

    @Test func mixedVoiceManifestPreservesCompleteChapterProvenance() throws {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("mixed"),
            chapterVoices: [0: VoiceID("af_heart"), 4: VoiceID("bf_emma")],
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/voice-sampler.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])

        #expect(manifest.voice == "mixed")
        #expect(manifest.chapterVoices == ["0": "af_heart", "4": "bf_emma"])
        #expect(throws: Never.self) { _ = try manifest.encoded() }
    }

    @Test func planManifestBindsCompleteBlockVoiceProvenance() throws {
        let audiobookSHA256 = String(repeating: "a", count: 64)
        let reelSHA256 = String(repeating: "b", count: 64)
        let provenance = PronunciationBlockVoiceProvenance(
            voicePlanSHA256: String(repeating: "c", count: 64),
            blockVoices: [
                "s0-b1": VoiceID("bf_emma"),
                "s0-b0": VoiceID("am_michael"),
            ])
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("am_michael"),
            chapterVoices: [:],
            blockVoiceProvenance: provenance,
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/voice-plan.m4b"),
            reelURL: URL(fileURLWithPath: "/tmp/voice-plan.pronunciation-reel.m4b"),
            audiobookSHA256: audiobookSHA256,
            listeningReelSHA256: reelSHA256,
            watchWords: [],
            decisions: [],
            diagnostics: [])

        #expect(manifest.schemaVersion == 7)
        #expect(manifest.voice == "mixed")
        #expect(manifest.chapterVoices.isEmpty)
        #expect(manifest.voicePlanSHA256 == provenance.voicePlanSHA256)
        #expect(manifest.blockVoices == ["s0-b0": "am_michael", "s0-b1": "bf_emma"])
        #expect(manifest.audiobookSHA256 == audiobookSHA256)
        #expect(manifest.listeningReelSHA256 == reelSHA256)

        let encoded = try String(decoding: manifest.encoded(), as: UTF8.self)
        let firstBlock = try #require(encoded.range(of: "\"s0-b0\""))
        let secondBlock = try #require(encoded.range(of: "\"s0-b1\""))
        #expect(firstBlock.lowerBound < secondBlock.lowerBound)
    }

    @Test func planManifestAcceptsImportedDecisionIDMatchingPortableVoiceProvenance() throws {
        let importedBlockID = "epub-runner-voice-plan-fixture.epub-s0-b0"
        let provenance = PronunciationBlockVoiceProvenance(
            voicePlanSHA256: String(repeating: "c", count: 64),
            blockVoices: ["s0-b0": VoiceID("am_michael")])
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("am_michael"),
            blockVoiceProvenance: provenance,
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/voice-plan.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [
                decision(
                    word: "record",
                    ruleID: "g2p.lexicon.record",
                    chapterIndex: 0,
                    blockID: importedBlockID),
            ],
            diagnostics: [])

        let encoded = try manifest.encoded()
        let decoded = try JSONDecoder().decode(PronunciationAuditManifest.self, from: encoded)
        #expect(decoded.blockVoices == ["s0-b0": "am_michael"])
        #expect(decoded.decisions.map(\.blockID) == [importedBlockID])
    }

    @Test func planManifestRejectsIncompleteOrInvalidBlockVoiceProvenance() throws {
        let provenance = PronunciationBlockVoiceProvenance(
            voicePlanSHA256: String(repeating: "c", count: 64),
            blockVoices: ["s0-b0": VoiceID("am_michael")])
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("am_michael"),
            blockVoiceProvenance: provenance,
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/voice-plan.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])
        let validObject = try #require(
            JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any])

        let invalidObjects: [[String: Any]] = [
            validObject.merging(["voicePlanSHA256": NSNull()]) { _, new in new },
            validObject.merging(["blockVoices": NSNull()]) { _, new in new },
            validObject.merging(["voicePlanSHA256": "not-a-sha256"]) { _, new in new },
            validObject.merging(["blockVoices": ["s0-b0": "not_a_voice"]]) { _, new in new },
            validObject.merging(["blockVoices": ["not-a-portable-block": "am_michael"]]) {
                _, new in new
            },
            validObject.merging(["blockVoices": ["s١-b٢": "am_michael"]]) {
                _, new in new
            },
        ]

        for object in invalidObjects {
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(PronunciationAuditManifest.self, from: data)
            }
        }

        let absentBlockDecision = decision(
            word: "mara",
            ruleID: "g2p.lexicon.mara",
            chapterIndex: 1,
            blockID: "epub-runner-voice-plan-fixture.epub-s1-b0")
        let objectWithAbsentDecision = validObject.merging(
            ["decisions": try JSONSerialization.jsonObject(with: JSONEncoder().encode([absentBlockDecision]))]
        ) { _, new in new }
        let absentDecisionData = try JSONSerialization.data(withJSONObject: objectWithAbsentDecision)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PronunciationAuditManifest.self, from: absentDecisionData)
        }
    }

    @Test func planArtifactValidationRejectsDriftFromResolvedProvenance() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let audiobookURL = tmp.appendingPathComponent("voice-plan.m4b")
        try Data("exact audiobook bytes".utf8).write(to: audiobookURL)
        let provenance = PronunciationBlockVoiceProvenance(
            voicePlanSHA256: String(repeating: "c", count: 64),
            blockVoices: [
                "s0-b0": VoiceID("am_michael"),
                "s0-b1": VoiceID("am_michael"),
            ])
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("am_michael"),
            blockVoiceProvenance: provenance,
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: audiobookURL,
            reelURL: nil,
            audiobookSHA256: try PronunciationArtifactIntegrity.sha256Hex(of: audiobookURL),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])
        let validObject = try #require(
            JSONSerialization.jsonObject(with: manifest.encoded()) as? [String: Any])

        let driftedObjects: [[String: Any]] = [
            validObject.merging(["blockVoices": ["s0-b0": "am_michael"]]) { _, new in new },
            validObject.merging([
                "blockVoices": [
                    "s0-b0": "am_michael",
                    "s0-b1": "am_michael",
                    "s9-b9": "am_michael",
                ],
            ]) { _, new in new },
            validObject.merging(["voicePlanSHA256": String(repeating: "d", count: 64)]) {
                _, new in new
            },
        ]

        try manifest.validateArtifacts(
            audiobookURL: audiobookURL,
            reelURL: nil,
            expectedBlockVoiceProvenance: provenance)

        for object in driftedObjects {
            let decoded = try JSONDecoder().decode(
                PronunciationAuditManifest.self,
                from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: (any Error).self) {
                try decoded.validateArtifacts(
                    audiobookURL: audiobookURL,
                    reelURL: nil,
                    expectedBlockVoiceProvenance: provenance)
            }
        }
    }

    @Test func manifestRejectsMalformedChapterVoiceProvenance() throws {
        let valid = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("mixed"),
            chapterVoices: [0: VoiceID("af_heart"), 4: VoiceID("bf_emma")],
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/voice-sampler.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])
        let validObject = try #require(
            JSONSerialization.jsonObject(with: valid.encoded()) as? [String: Any])

        for malformedVoices in [
            ["-1": "af_heart", "4": "bf_emma"],
            ["01": "af_heart", "4": "bf_emma"],
            ["chapter-one": "af_heart", "4": "bf_emma"],
            ["0": "not_a_voice", "4": "bf_emma"],
        ] {
            var object = validObject
            object["chapterVoices"] = malformedVoices
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: data)
            }
        }
    }

    @Test func manifestCountsDecisionsOutsideConfiguredWatchVocabulary() {
        let mara = decision(word: "mara", ruleID: "g2p.lexicon.mara", chapterIndex: 0)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 13,
            voice: VoiceID("am_michael"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [mara],
            diagnostics: [])

        #expect(manifest.watchCounts == ["mara": 1, "verified": 0])
    }

    @Test func manifestDistinguishesLegacyCaptureFromEvidenceDiagnostics() {
        let evidenceDiagnostic = diagnostic()
        let incompleteEvidence = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [evidenceDiagnostic])
        let legacy = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .incompleteLegacyCapture,
            legacyChapterIndexes: [1, 7],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [evidenceDiagnostic])

        #expect(incompleteEvidence.coverage == .incompleteEvidence)
        #expect(incompleteEvidence.diagnostics == [evidenceDiagnostic])
        #expect(legacy.coverage == .incompleteLegacyCapture)
        #expect(legacy.legacyChapterIndexes == [1, 7])
    }

    @Test func contextualEvidenceSurvivesMaterializationTimingAndSchemaFourJSON() throws {
        let evidence = contextualEvidence()
        let seed = PronunciationDecisionSeed(
            blockID: "context",
            wordStart: 1,
            wordEnd: 1,
            normalizedWord: "record",
            sourceWord: "record",
            sourceContext: "Please record this bounded fixture",
            selectedIPA: "ɹəkˈɔɹd",
            source: .contextualHomograph,
            ruleID: "homograph.record.verb",
            rationale: "Deterministic production decision.",
            contextualEvidence: evidence)
        let decision = seed.materialized(
            selectedIPA: "ɹəkˈɔɹd",
            kokoroTokenIDs: [1, 2, 3]
        )
        .attachingRenderTiming(
            chapterIndex: 2,
            chapterRelativeAudioRange: .init(start: 1, end: 1.2),
            timingPrecision: .exactSynthesisWord
        )
        .attachingBookTiming(chapterIndex: 2, chapterOffset: 10)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/context.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [decision],
            diagnostics: [])
        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: manifest.encoded())

        #expect(decoded.coverage == .complete)
        #expect(decoded.decisions.first?.contextualEvidence == evidence)
        #expect(decoded.decisions.first?.selectedIPA == "ɹəkˈɔɹd")
        #expect(
            decoded.decisions.first?.bookRelativeAudioRange
                == .init(start: 11, end: 11.2))
    }

    @Test func taskSevenOutcomeEnvelopesAreCompleteButMissingEvidenceIsIncomplete() throws {
        let selected = contextualDecision(evidence: contextualEvidence())
        let needsReview = contextualDecision(
            evidence: replacingContextualEvidence(
                contextualEvidence(),
                modelCandidateID: .some(nil),
                modelAbstained: true,
                acceptanceReason: .shadowNeedsReview))
        let unavailable = contextualDecision(
            evidence: contextualEvidence(availability: .deviceNotEligible))
        let failure = contextualDecision(
            evidence: contextualEvidence(failure: .guardrail))
        let missing = contextualDecision(evidence: nil)
        func manifest(for decision: PronunciationAuditDecision) -> PronunciationAuditManifest {
            PronunciationAuditManifest.make(
                renderVersion: NarrationFileNaming.renderVersion,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                audiobookURL: URL(fileURLWithPath: "/tmp/context.m4b"),
                reelURL: nil,
                audiobookSHA256: String(repeating: "a", count: 64),
                listeningReelSHA256: nil,
                watchWords: [],
                decisions: [decision],
                diagnostics: [])
        }

        let notRequested = contextualDecision(evidence: contextualEvidence(availability: .notRequested))
        for decision in [selected, needsReview, unavailable, failure, notRequested] {
            let receipt = manifest(for: decision)
            #expect(receipt.coverage == .complete)
            let decoded = try JSONDecoder().decode(
                PronunciationAuditManifest.self,
                from: receipt.encoded())
            #expect(decoded.coverage == .complete)
            #expect(decoded.decisions.first?.contextualEvidence == decision.contextualEvidence)
        }
        #expect(manifest(for: missing).coverage == .incompleteEvidence)
    }

    @Test func malformedPhaseTwoEvidenceFailsClosedForCoverageEncodingAndDecoding() throws {
        let valid = contextualEvidence()
        let malformed = [
            replacingContextualEvidence(
                valid,
                occurrenceID: "unknown-occurrence"),
            replacingContextualEvidence(
                valid,
                modelCandidateID: .some(nil)),
            replacingContextualEvidence(
                valid,
                modelAbstained: true),
            replacingContextualEvidence(
                valid,
                modelCandidateID: .some(nil),
                modelAbstained: false,
                acceptanceReason: .shadowNeedsReview),
            replacingContextualEvidence(
                valid,
                modelAvailability: .deviceNotEligible,
                acceptanceReason: .shadowModelUnavailable),
            replacingContextualEvidence(
                valid,
                modelFailure: .some(.guardrail),
                acceptanceReason: .shadowModelFailure),
            replacingContextualEvidence(
                valid,
                modelCandidateID: .some(nil),
                modelFailure: .some(.cancelled),
                acceptanceReason: .shadowModelFailure),
            replacingContextualEvidence(
                valid,
                modelCandidateID: "record.unknown"),
            replacingContextualEvidence(
                valid,
                familyState: .graduated),
            replacingContextualEvidence(
                contextualEvidence(availability: .deviceNotEligible),
                acceptanceReason: .shadowObserved),
            replacingContextualEvidence(
                valid,
                humanCandidateID: .some("record.noun")),
            replacingContextualEvidence(
                valid,
                humanCorrectionScope: .some("book")),
            replacingContextualEvidence(
                valid,
                isLimited: true),
            replacingContextualEvidence(
                valid,
                platform: ""),
            replacingContextualEvidence(
                valid,
                osBuild: ""),
            replacingContextualEvidence(
                valid,
                qualifiedRuntimeFamilyID: ""),
        ]

        for evidence in malformed {
            let manifest = PronunciationAuditManifest.make(
                renderVersion: NarrationFileNaming.renderVersion,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                audiobookURL: URL(fileURLWithPath: "/tmp/context.m4b"),
                reelURL: nil,
                audiobookSHA256: String(repeating: "a", count: 64),
                listeningReelSHA256: nil,
                watchWords: [],
                decisions: [contextualDecision(evidence: evidence)],
                diagnostics: [])

            #expect(manifest.coverage == .incompleteEvidence)
            #expect(throws: (any Error).self) {
                _ = try manifest.encoded()
            }
            #expect(throws: (any Error).self) {
                _ = try JSONEncoder().encode(manifest)
            }
        }
    }

    @Test func contextualEvidenceRejectsOverrideSourcesAndPermitsOtherSources() throws {
        let sources: [PronunciationAuditDecision.Source] = [
            .occurrenceOverride,
            .bookOverride,
            .globalOverride,
            .builtInOverride,
            .contextualHomograph,
            .supplementalLexicon,
            .derivedMorphology,
            .monitoredLexicon,
            .fallback,
        ]
        let overrideSources: [PronunciationAuditDecision.Source] = [
            .occurrenceOverride,
            .bookOverride,
            .globalOverride,
            .builtInOverride,
        ]
        func manifest(
            evidence: ContextualPronunciationEvidence?,
            source: PronunciationAuditDecision.Source
        ) -> PronunciationAuditManifest {
            PronunciationAuditManifest.make(
                renderVersion: NarrationFileNaming.renderVersion,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                audiobookURL: URL(fileURLWithPath: "/tmp/context.m4b"),
                reelURL: nil,
                audiobookSHA256: String(repeating: "a", count: 64),
                listeningReelSHA256: nil,
                watchWords: [],
                decisions: [contextualDecision(evidence: evidence, source: source)],
                diagnostics: [])
        }

        for source in sources {
            let receipt = manifest(
                evidence: contextualEvidence(),
                source: source)
            if overrideSources.contains(source) {
                #expect(receipt.coverage == .incompleteEvidence)
                #expect(throws: (any Error).self) {
                    _ = try receipt.encoded()
                }
                #expect(throws: (any Error).self) {
                    _ = try JSONEncoder().encode(receipt)
                }
            } else {
                #expect(receipt.coverage == .complete)
                let decoded = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: receipt.encoded())
                #expect(decoded.coverage == .complete)
            }
        }

        for source in overrideSources {
            let receipt = manifest(evidence: nil, source: source)
            #expect(receipt.coverage == .complete)
            #expect(
                try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: receipt.encoded()
                ).coverage == .complete)
        }
    }

    @Test func legacyChapterListWinsOverOtherwiseCompleteOrDiagnosticCoverage() {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .incompleteEvidence,
            legacyChapterIndexes: [9, 2, 9],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [diagnostic()])

        #expect(manifest.coverage == .incompleteLegacyCapture)
        #expect(manifest.legacyChapterIndexes == [2, 9])
    }

    @Test func zeroDecisionManifestStillCarriesAllZeroWatchCountsAndNoReel() {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified", "filesystem", "verified"],
            decisions: [],
            diagnostics: [])

        #expect(manifest.decisions.isEmpty)
        #expect(manifest.watchCounts == ["filesystem": 0, "verified": 0])
        #expect(manifest.listeningReelFileName == nil)
        #expect(manifest.coverage == .complete)
    }

    @Test func manifestEncodingIsPrettySortedAndAtomicallyReplacesExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("book.pronunciation-audit.json")

        let oldManifest = PronunciationAuditManifest.make(
            renderVersion: 10,
            voice: VoiceID("old_voice"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: tmp.appendingPathComponent("book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "c", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [decision(word: "verified", ruleID: "old", chapterIndex: 0)],
            diagnostics: [])
        let newManifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: tmp.appendingPathComponent("book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "d", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified", "filesystem"],
            decisions: [],
            diagnostics: [])

        try oldManifest.write(to: destination)
        try newManifest.write(to: destination)

        let data = try Data(contentsOf: destination)
        let text = try #require(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(PronunciationAuditManifest.self, from: data)
        let audiobookKey = try #require(text.range(of: "\"audiobookFileName\""))
        let coverageKey = try #require(text.range(of: "\"coverage\""))
        let schemaKey = try #require(text.range(of: "\"schemaVersion\""))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil)

        #expect(text.hasPrefix("{\n"))
        #expect(audiobookKey.lowerBound < coverageKey.lowerBound)
        #expect(coverageKey.lowerBound < schemaKey.lowerBound)
        #expect(decoded == newManifest)
        #expect(siblings.map(\.lastPathComponent) == [destination.lastPathComponent])
        #expect(!text.contains(tmp.path))
    }

    @Test func manifestEncodingRejectsMalformedOrUnpairedArtifactHashes() {
        let malformed = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: "NOT-A-SHA256",
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])
        let unpaired = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: URL(fileURLWithPath: "/tmp/book.pronunciation-reel.m4b"),
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])

        #expect(throws: Error.self) { _ = try malformed.encoded() }
        #expect(throws: Error.self) { _ = try unpaired.encoded() }
    }

    @Test func schemaThreeAndFourAuditsDiscardInjectedAdvisoryEvidenceAndReencodeAsSchemaSix()
        throws
    {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [decision(word: "verified", ruleID: "legacy", chapterIndex: 0)],
            diagnostics: [])
        let encoded = try manifest.encoded()
        var schemaThree = try #require(
            JSONSerialization.jsonObject(
                with: encoded) as? [String: Any])
        schemaThree["schemaVersion"] = 3
        var schemaFour = schemaThree
        schemaFour["schemaVersion"] = 4
        let wellFormedEvidence = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(advisoryEvidence())) as? [String: Any])
        let injectedPayloads: [[String: Any]] = [
            wellFormedEvidence,
            ["category": "future-category"],
        ]

        for legacyRoot in [schemaThree, schemaFour] {
            for injectedPayload in injectedPayloads {
                var root = legacyRoot
                var decisions = try #require(root["decisions"] as? [[String: Any]])
                decisions[0]["advisoryEvidence"] = injectedPayload
                root["decisions"] = decisions

                let decoded = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: JSONSerialization.data(withJSONObject: root))
                let reencoded = try #require(
                    JSONSerialization.jsonObject(with: decoded.encoded())
                        as? [String: Any])
                let reencodedDecisions = try #require(
                    reencoded["decisions"] as? [[String: Any]])

                #expect(decoded.schemaVersion == root["schemaVersion"] as? Int)
                #expect(
                    decoded.coverage
                        == (decoded.schemaVersion == 3
                            ? .incompleteEvidence
                            : .complete))
                #expect(decoded.decisions.first?.advisoryEvidence == nil)
                #expect(reencoded["schemaVersion"] as? Int == 6)
                #expect(reencodedDecisions.first?["advisoryEvidence"] == nil)
            }
        }

        let currentManifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [
                PronunciationAuditDecision(
                    blockID: "context",
                    wordStart: 1,
                    wordEnd: 1,
                    normalizedWord: "record",
                    sourceWord: "record",
                    sourceContext: "bounded context",
                    selectedIPA: "ɹəkˈɔɹd",
                    kokoroTokenIDs: [1],
                    source: .monitoredLexicon,
                    ruleID: "g2p.lexicon.record",
                    rationale: "Fixture.",
                    candidateID: "record.verb",
                    candidatePackVersion: "fixture-v1")
            ],
            diagnostics: [])
        var schemaSix = try #require(
            JSONSerialization.jsonObject(with: currentManifest.encoded()) as? [String: Any])
        var schemaSixDecisions = try #require(schemaSix["decisions"] as? [[String: Any]])
        let monitoredEvidence = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(monitoredLexiconAdvisoryEvidence())) as? [String: Any])
        schemaSixDecisions[0]["advisoryEvidence"] = monitoredEvidence
        schemaSix["decisions"] = schemaSixDecisions
        let current = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: JSONSerialization.data(withJSONObject: schemaSix))

        #expect(current.decisions.first?.advisoryEvidence == monitoredLexiconAdvisoryEvidence())

        schemaSixDecisions[0]["advisoryEvidence"] = ["category": "future-category"]
        schemaSix["decisions"] = schemaSixDecisions
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(
                PronunciationAuditManifest.self,
                from: JSONSerialization.data(withJSONObject: schemaSix))
        }
    }

    @Test func schemaSixBindsAdvisoryEvidenceToTheSelectedDecision() throws {
        let selected = PronunciationAuditDecision(
            blockID: "context",
            wordStart: 1,
            wordEnd: 1,
            normalizedWord: "record",
            sourceWord: "record",
            sourceContext: "bounded context",
            selectedIPA: "ɹəkˈɔɹd",
            kokoroTokenIDs: [1],
            source: .monitoredLexicon,
            ruleID: "g2p.lexicon.record",
            rationale: "Fixture.",
            candidateID: "record.verb",
            candidatePackVersion: "fixture-v1",
            advisoryEvidence: monitoredLexiconAdvisoryEvidence())
        let encoded = try manifest(with: [selected]).encoded()
        #expect(
            try JSONDecoder().decode(
                PronunciationAuditManifest.self, from: encoded
            ).decisions == [selected])

        let validRoot = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var malformedRoots: [[String: Any]] = []

        var wrongIdentity = validRoot
        var wrongIdentityDecisions = try #require(
            wrongIdentity["decisions"] as? [[String: Any]])
        var wrongIdentityEvidence = try #require(
            wrongIdentityDecisions[0]["advisoryEvidence"] as? [String: Any])
        wrongIdentityEvidence["selectedCandidateID"] = "record.other"
        wrongIdentityDecisions[0]["advisoryEvidence"] = wrongIdentityEvidence
        wrongIdentity["decisions"] = wrongIdentityDecisions
        malformedRoots.append(wrongIdentity)

        var wrongAuthority = validRoot
        var wrongAuthorityDecisions = try #require(
            wrongAuthority["decisions"] as? [[String: Any]])
        var wrongAuthorityEvidence = try #require(
            wrongAuthorityDecisions[0]["advisoryEvidence"] as? [String: Any])
        wrongAuthorityEvidence["selectedAuthority"] = "uncertain"
        wrongAuthorityDecisions[0]["advisoryEvidence"] = wrongAuthorityEvidence
        wrongAuthority["decisions"] = wrongAuthorityDecisions
        malformedRoots.append(wrongAuthority)

        var wrongSource = validRoot
        var wrongSourceDecisions = try #require(
            wrongSource["decisions"] as? [[String: Any]])
        wrongSourceDecisions[0]["source"] = "fallback"
        wrongSource["decisions"] = wrongSourceDecisions
        malformedRoots.append(wrongSource)

        var selectedIPACollision = validRoot
        var selectedIPADecisions = try #require(
            selectedIPACollision["decisions"] as? [[String: Any]])
        var selectedIPAEvidence = try #require(
            selectedIPADecisions[0]["advisoryEvidence"] as? [String: Any])
        var alternatives = try #require(
            selectedIPAEvidence["alternatives"] as? [[String: Any]])
        alternatives[0]["ipa"] = " ɹəkˈɔɹd "
        selectedIPAEvidence["alternatives"] = alternatives
        selectedIPADecisions[0]["advisoryEvidence"] = selectedIPAEvidence
        selectedIPACollision["decisions"] = selectedIPADecisions
        malformedRoots.append(selectedIPACollision)

        for malformed in malformedRoots {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: JSONSerialization.data(withJSONObject: malformed))
            }
        }
    }

    @Test func legacyReceiptCannotReencodeAnInvalidCurrentSchemaSixShape() throws {
        var legacyRoot = try #require(
            JSONSerialization.jsonObject(
                with: manifest(with: [invalidRawG2PDecision()]).encoded()) as? [String: Any])
        legacyRoot["schemaVersion"] = 4

        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: JSONSerialization.data(withJSONObject: legacyRoot))

        #expect(decoded.schemaVersion == 4)
        #expect(decoded.decisions.first?.advisoryEvidence == nil)
        #expect(throws: (any Error).self) { _ = try decoded.encoded() }
    }

    @Test func schemaSixRejectsMalformedInvalidG2PReceiptsAndRetainsTheVerifiedShape()
        throws
    {
        let genuine = manifest(with: [invalidRawG2PDecision()])
        let genuineData = try genuine.encoded()
        #expect(
            try JSONDecoder().decode(
                PronunciationAuditManifest.self,
                from: genuineData) == genuine)

        let root = try #require(
            JSONSerialization.jsonObject(with: genuineData) as? [String: Any])
        let validLexicalEvidence = try #require(
            root["decisions"].flatMap { $0 as? [[String: Any]] }?.first?["advisoryEvidence"]
                as? [String: Any])

        var occurrenceOverride = root
        var occurrenceDecisions = try #require(occurrenceOverride["decisions"] as? [[String: Any]])
        occurrenceDecisions[0]["source"] = "occurrenceOverride"
        occurrenceDecisions[0]["ruleID"] = "override.occurrence.ordinary"
        occurrenceOverride["decisions"] = occurrenceDecisions

        var wrongSourceRule = root
        var wrongSourceRuleDecisions = try #require(
            wrongSourceRule["decisions"] as? [[String: Any]])
        wrongSourceRuleDecisions[0]["source"] = "monitoredLexicon"
        wrongSourceRuleDecisions[0]["ruleID"] = "g2p.fallback.ordinary"
        wrongSourceRuleDecisions[0]["advisoryEvidence"] = validLexicalEvidence.merging([
            "selectedAuthority": "trusted",
            "selectionReason": "trustedLexicon",
        ]) { _, new in new }
        wrongSourceRule["decisions"] = wrongSourceRuleDecisions

        var partialTiming = root
        var partialTimingDecisions = try #require(partialTiming["decisions"] as? [[String: Any]])
        partialTimingDecisions[0]["chapterRelativeAudioRange"] = ["start": 0.0, "end": 0.5]
        partialTiming["decisions"] = partialTimingDecisions

        var fakeTokenID = occurrenceOverride
        var fakeTokenIDDecisions = try #require(fakeTokenID["decisions"] as? [[String: Any]])
        fakeTokenIDDecisions[0]["kokoroTokenIDs"] = [42]
        fakeTokenID["decisions"] = fakeTokenIDDecisions

        for malformed in [occurrenceOverride, wrongSourceRule, partialTiming, fakeTokenID] {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: JSONSerialization.data(withJSONObject: malformed))
            }
        }
    }

    @Test func rejectedRawG2PClassificationStripsOOVMarkersBeforeValidation() {
        let marker = String(KokoroPhonemeVocab.oovMarker)

        #expect(PronunciationAuditContext.isRejectedRawG2POutput(""))
        #expect(!PronunciationAuditContext.isRejectedRawG2POutput(marker))
        #expect(!PronunciationAuditContext.isRejectedRawG2POutput(marker + marker))
        #expect(!PronunciationAuditContext.isRejectedRawG2POutput(marker + "ə"))
        #expect(PronunciationAuditContext.isRejectedRawG2POutput(marker + "\u{0000}"))
    }

    @Test func schemaThreeLegacyLimitationRemainsStronger() throws {
        var root = try #require(
            JSONSerialization.jsonObject(
                with: Data(Self.schemaThreeManifestJSON.utf8)) as? [String: Any])
        root["coverage"] = "incompleteLegacyCapture"
        root["legacyChapterIndexes"] = [2]

        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: JSONSerialization.data(withJSONObject: root))

        #expect(decoded.schemaVersion == 3)
        #expect(decoded.coverage == .incompleteLegacyCapture)
        #expect(decoded.legacyChapterIndexes == [2])
    }

    @Test func unsupportedAuditSchemasAreRejectedDuringDecoding() throws {
        for schemaVersion in [2, 7] {
            var root = try #require(
                JSONSerialization.jsonObject(
                    with: Data(Self.schemaThreeManifestJSON.utf8)) as? [String: Any])
            root["schemaVersion"] = schemaVersion

            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(
                    PronunciationAuditManifest.self,
                    from: JSONSerialization.data(withJSONObject: root))
            }
        }
    }

    @Test func derivedProvenanceSurvivesMaterializationTimingAndJSONRoundTrip() throws {
        let seed = PronunciationDecisionSeed(
            blockID: "s0-b0",
            wordStart: 3,
            wordEnd: 3,
            normalizedWord: "startable",
            sourceWord: "startable",
            sourceContext: "The widget is startable now",
            selectedIPA: "stˈɑɹtəbəl",
            source: .derivedMorphology,
            ruleID: "universal.morphology",
            rationale: "One validated base and one versioned rule.",
            candidateID: "morphology.startable.0123456789ab",
            candidatePackVersion: "morphology-v1:sha256:"
                + String(repeating: "a", count: 64),
            derivationBase: "start",
            derivationRuleID: "morphology.able.exact-base.v1")

        let materialized = seed.materialized(
            selectedIPA: "stˈɑɹtəbəl",
            kokoroTokenIDs: [10, 20, 30])
        let rendered = materialized.attachingRenderTiming(
            chapterIndex: 4,
            chapterRelativeAudioRange: .init(start: 2, end: 2.5),
            timingPrecision: .exactSynthesisWord)
        let booked = rendered.attachingBookTiming(
            chapterIndex: 4,
            chapterOffset: 100)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [booked],
            diagnostics: [])
        let decoded = try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: manifest.encoded())
        let decision = try #require(decoded.decisions.first)

        #expect(decoded.schemaVersion == 6)
        #expect(decision.candidateID == "morphology.startable.0123456789ab")
        #expect(
            decision.candidatePackVersion
                == "morphology-v1:sha256:" + String(repeating: "a", count: 64))
        #expect(decision.derivationBase == "start")
        #expect(decision.derivationRuleID == "morphology.able.exact-base.v1")
        #expect(
            decision.chapterRelativeAudioRange
                == PronunciationAuditDecision.AudioRange(start: 2, end: 2.5))
        #expect(
            decision.bookRelativeAudioRange
                == PronunciationAuditDecision.AudioRange(start: 102, end: 102.5))
    }

    @Test func supplementalProvenanceSurvivesWithoutMorphologyFields() throws {
        let decision = PronunciationDecisionSeed(
            blockID: "b1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "example",
            sourceWord: "Example",
            sourceContext: "Example",
            selectedIPA: "ɪɡzˈæmpəl",
            source: .supplementalLexicon,
            ruleID: "universal.supplemental",
            rationale: "One validated supplemental candidate.",
            candidateID: "cmudict.example.63ea23914424",
            candidatePackVersion: "sha256:" + String(repeating: "b", count: 64)
        )
        .materialized(
            selectedIPA: "ɪɡzˈæmpəl",
            kokoroTokenIDs: [1, 2, 3])

        #expect(decision.candidateID == "cmudict.example.63ea23914424")
        #expect(
            decision.candidatePackVersion
                == "sha256:" + String(repeating: "b", count: 64))
        #expect(decision.derivationBase == nil)
        #expect(decision.derivationRuleID == nil)
    }

    @Test func advisoryEvidenceSurvivesMaterializationAndBothTimingCopies() throws {
        let evidence = advisoryEvidence()
        let decision = PronunciationDecisionSeed(
            blockID: "context",
            wordStart: 1,
            wordEnd: 1,
            normalizedWord: "record",
            sourceWord: "record",
            sourceContext: "Private context must remain on the audit decision only.",
            selectedIPA: "ɹəkˈɔɹd",
            source: .contextualHomograph,
            ruleID: "homograph.record.verb",
            rationale: "Fixture.",
            advisoryEvidence: evidence
        )
        .materialized(selectedIPA: "ɹəkˈɔɹd", kokoroTokenIDs: [1])
        .attachingRenderTiming(
            chapterIndex: 2,
            chapterRelativeAudioRange: .init(start: 1, end: 1.2),
            timingPrecision: .exactSynthesisWord
        )
        .attachingBookTiming(chapterIndex: 2, chapterOffset: 10)

        #expect(decision.advisoryEvidence == evidence)
        #expect(decision.chapterRelativeAudioRange == .init(start: 1, end: 1.2))
        #expect(decision.bookRelativeAudioRange == .init(start: 11, end: 11.2))
    }

    @Test func manifestRejectsDuplicateAdvisoryCandidateIDsAndIPAs() {
        let duplicateCandidateID = advisoryEvidence(alternatives: [
            .init(
                candidateID: "record.same",
                ipa: "ɹˈɛkəɹd",
                source: "fixture-a",
                authority: .qualified,
                validation: .shadow,
                policyVersion: "policy-v1"),
            .init(
                candidateID: "record.same",
                ipa: "ɹəkˈɔɹd",
                source: "fixture-b",
                authority: .uncertain,
                validation: .rejected,
                policyVersion: "policy-v1"),
        ])
        let duplicateIPA = advisoryEvidence(alternatives: [
            .init(
                candidateID: "record.noun",
                ipa: "ɹˈɛkəɹd",
                source: "fixture-a",
                authority: .qualified,
                validation: .shadow,
                policyVersion: "policy-v1"),
            .init(
                candidateID: "record.alias",
                ipa: "ɹˈɛkəɹd",
                source: "fixture-b",
                authority: .uncertain,
                validation: .rejected,
                policyVersion: "policy-v1"),
        ])

        for evidence in [duplicateCandidateID, duplicateIPA] {
            let manifest = PronunciationAuditManifest.make(
                renderVersion: 15,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
                reelURL: nil,
                audiobookSHA256: String(repeating: "a", count: 64),
                listeningReelSHA256: nil,
                watchWords: [],
                decisions: [
                    PronunciationAuditDecision(
                        blockID: "context",
                        wordStart: 1,
                        wordEnd: 1,
                        normalizedWord: "record",
                        sourceWord: "record",
                        sourceContext: "bounded context",
                        selectedIPA: "ɹəkˈɔɹd",
                        kokoroTokenIDs: [1],
                        source: .contextualHomograph,
                        ruleID: "homograph.record.verb",
                        rationale: "Fixture.",
                        advisoryEvidence: evidence)
                ],
                diagnostics: [])
            #expect(throws: (any Error).self) { _ = try manifest.encoded() }
        }
    }

    @Test func universalDecisionsRejectIncompleteProvenanceCombinations() throws {
        let validSupplemental = PronunciationAuditDecision(
            blockID: "b1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "example",
            sourceWord: "example",
            sourceContext: "example",
            selectedIPA: "ipa",
            kokoroTokenIDs: [1],
            source: .supplementalLexicon,
            ruleID: "universal.supplemental",
            rationale: "fixture",
            candidateID: "cmudict.example.fixture",
            candidatePackVersion: "sha256:" + String(repeating: "c", count: 64))
        let validDerived = PronunciationAuditDecision(
            blockID: "b1",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "startable",
            sourceWord: "startable",
            sourceContext: "startable",
            selectedIPA: "ipa",
            kokoroTokenIDs: [1],
            source: .derivedMorphology,
            ruleID: "universal.morphology",
            rationale: "fixture",
            candidateID: "morphology.startable.fixture",
            candidatePackVersion: "morphology-v1:sha256:"
                + String(repeating: "d", count: 64),
            derivationBase: "start",
            derivationRuleID: "morphology.able.exact-base.v1")

        let invalid = [
            replacingProvenance(validSupplemental, candidateID: .some(nil)),
            replacingProvenance(validSupplemental, candidatePackVersion: .some(nil)),
            replacingProvenance(validSupplemental, derivationBase: "example"),
            replacingProvenance(validDerived, candidateID: ""),
            replacingProvenance(validDerived, candidatePackVersion: ""),
            replacingProvenance(validDerived, derivationBase: ""),
            replacingProvenance(validDerived, derivationRuleID: ""),
        ]

        for decision in invalid {
            let manifest = PronunciationAuditManifest.make(
                renderVersion: 15,
                voice: VoiceID("af_heart"),
                captureCoverage: .complete,
                legacyChapterIndexes: [],
                audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
                reelURL: nil,
                audiobookSHA256: String(repeating: "a", count: 64),
                listeningReelSHA256: nil,
                watchWords: [],
                decisions: [decision],
                diagnostics: [])
            #expect(throws: (any Error).self) { _ = try manifest.encoded() }
            #expect(throws: (any Error).self) {
                _ = try JSONEncoder().encode(manifest)
            }
        }
    }

    private func replacingProvenance(
        _ decision: PronunciationAuditDecision,
        candidateID: String?? = nil,
        candidatePackVersion: String?? = nil,
        derivationBase: String?? = nil,
        derivationRuleID: String?? = nil
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
            candidateID: candidateID ?? decision.candidateID,
            candidatePackVersion: candidatePackVersion ?? decision.candidatePackVersion,
            derivationBase: derivationBase ?? decision.derivationBase,
            derivationRuleID: derivationRuleID ?? decision.derivationRuleID)
    }

    private func replacingContextualEvidence(
        _ evidence: ContextualPronunciationEvidence,
        occurrenceID: String? = nil,
        modelCandidateID: String?? = nil,
        modelAbstained: Bool? = nil,
        modelAvailability: ContextualModelAvailability? = nil,
        modelFailure: ContextualModelFailure?? = nil,
        familyState: ContextualFamilyState? = nil,
        acceptanceReason: ContextualAcceptanceReason? = nil,
        platform: String? = nil,
        osBuild: String? = nil,
        qualifiedRuntimeFamilyID: String? = nil,
        humanCandidateID: String?? = nil,
        humanCorrectionScope: String?? = nil,
        isLimited: Bool? = nil
    ) -> ContextualPronunciationEvidence {
        ContextualPronunciationEvidence(
            occurrenceID: occurrenceID ?? evidence.occurrenceID,
            familyID: evidence.familyID,
            candidatePackVersion: evidence.candidatePackVersion,
            submittedCandidateIDs: evidence.submittedCandidateIDs,
            deterministicCandidateID: evidence.deterministicCandidateID,
            deterministicRuleID: evidence.deterministicRuleID,
            deterministicStrength: evidence.deterministicStrength,
            modelCandidateID: modelCandidateID ?? evidence.modelCandidateID,
            modelAbstained: modelAbstained ?? evidence.modelAbstained,
            modelAvailability: modelAvailability ?? evidence.modelAvailability,
            modelFailure: modelFailure ?? evidence.modelFailure,
            familyState: familyState ?? evidence.familyState,
            acceptanceReason: acceptanceReason ?? evidence.acceptanceReason,
            promptSchemaVersion: evidence.promptSchemaVersion,
            platform: platform ?? evidence.platform,
            osBuild: osBuild ?? evidence.osBuild,
            qualifiedRuntimeFamilyID:
                qualifiedRuntimeFamilyID ?? evidence.qualifiedRuntimeFamilyID,
            humanCandidateID: humanCandidateID ?? evidence.humanCandidateID,
            humanCorrectionScope: humanCorrectionScope ?? evidence.humanCorrectionScope,
            isLimited: isLimited ?? evidence.isLimited)
    }
}
