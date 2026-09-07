// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationRenderPlanTests {
    private func block(
        id: String,
        text: String?,
        kind: String = "paragraph",
        index: Int
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book", spineHref: "c.xhtml",
            spineIndex: 0, blockIndex: index, sequenceIndex: index,
            blockKind: kind, text: text, htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, createdAt: nil, modifiedAt: nil)
    }

    @Test func plannedDecisionUsesExactFinalChunkPhonemeAndIDSlice() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "The process is startable.", index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]))
        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(plannedBlock.pronunciationDecisions.first)
        #expect(plannedBlock.pronunciationDecisions.count == 1)
        #expect(!plannedBlock.pronunciationDecisions.contains {
            $0.normalizedWord == "the"
        })
        let evidence = try #require(
            chunk.pronunciationTokenEvidence.first {
                PronunciationAuditContext.normalizedWord($0.text) == "startable"
            })
        let phonemeRange = try #require(evidence.phonemeCharacterRange)
        let lowerBound = chunk.phonemes.index(
            chunk.phonemes.startIndex,
            offsetBy: phonemeRange.lowerBound)
        let upperBound = chunk.phonemes.index(
            chunk.phonemes.startIndex,
            offsetBy: phonemeRange.upperBound)
        let exactFinalIPA = String(chunk.phonemes[lowerBound..<upperBound])
        let interiorIDs = Array(chunk.phonemeIDs.dropFirst().dropLast())
        let exactFinalIDs = Array(interiorIDs[phonemeRange])

        #expect(decision.blockID == "b0")
        #expect(decision.wordStart == 3)
        #expect(decision.wordEnd == 3)
        #expect(decision.normalizedWord == "startable")
        #expect(decision.sourceWord == "startable")
        #expect(decision.sourceContext == "The process is startable.")
        #expect(exactFinalIPA == "stˈɑɹTəbəl")
        #expect(decision.selectedIPA == exactFinalIPA)
        #expect(decision.kokoroTokenIDs == exactFinalIDs)
        #expect(!decision.kokoroTokenIDs.isEmpty)
        #expect(decision.kokoroTokenIDs.allSatisfy { $0 != KokoroPhonemeVocab.boundaryTokenId })
        #expect(decision.source == .builtInOverride)
        #expect(decision.ruleID == "override.built-in.startable")
        #expect(decision.rationale == "Built-in override matched “startable”.")
        #expect(decision.chapterIndex == nil)
        #expect(decision.chapterRelativeAudioRange == nil)
        #expect(decision.bookRelativeAudioRange == nil)
        #expect(decision.timingPrecision == nil)

        let encoded = try JSONEncoder().encode(decision)
        #expect(
            try JSONDecoder().decode(PronunciationAuditDecision.self, from: encoded) == decision)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"source\":\"builtInOverride\""))
    }

    @Test func quotedSentenceBoundaryPreservesAuditWordIndexes() throws {
        let text =
            "You open an assistant and ask it to rewrite a paragraph. It does a decent job. "
            + "You reply, “Make it less formal.” The second answer usually makes sense even "
            + "though you did not paste the paragraph again. Something from the earlier "
            + "exchange remained available."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "quoted-boundary", text: text, index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]))
        let plannedBlock = try #require(plan.blocks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first {
                $0.normalizedWord == "available"
            })

        #expect(
            plannedBlock.synthesisChunks.reduce(0) { $0 + $1.wordCount }
                == WordTokenizer.words(in: text).count)
        #expect(decision.wordStart == 43)
        #expect(decision.wordEnd == 43)
        #expect(decision.sourceContext == "from the earlier exchange remained available.")
    }

    @Test func normalizedDashAndHTMLCommentPreserveAuditEvidence() throws {
        let text =
            "Is it ready? — The filesystem lives here; agents live here. "
            + "<!-- G088 --> Re-check the startable system."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "reported-seams", text: text, index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]))
        let plannedBlock = try #require(plan.blocks.first)
        let decisions = Dictionary(
            uniqueKeysWithValues: plannedBlock.pronunciationDecisions.map {
                ($0.normalizedWord, $0)
            })

        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
        #expect(decisions["filesystem"]?.source == .builtInOverride)
        #expect(decisions["startable"]?.source == .builtInOverride)
        #expect(decisions["re"]?.source == .builtInOverride)
        #expect(decisions["live"]?.source == .contextualHomograph)
        #expect(decisions["lives"]?.source == .contextualHomograph)
        #expect(
            plannedBlock.synthesisChunks.reduce(0) { $0 + $1.wordCount }
                == WordTokenizer.words(in: TextNormalizer.normalize(text)).count)
    }

    @Test func lifecycleOverrideKeepsCompleteEvidenceBesideClaudeMarkdownToken() throws {
        let text =
            "Different backgrounds create different gaps. An experienced backend architect may "
            + "already understand queues, retries, access control, and observability while "
            + "remaining unfamiliar with model-driven tool selection or context limits. A daily "
            + "Claude Code user may know how to steer a coding session yet never have implemented "
            + "the API loop that passes a tool result back to Claude. An engineer who has built an "
            + "extraction service may understand schemas and evaluation while having little "
            + "experience with shared CLAUDE.md files, lifecycle hooks, or isolated subagents. "
            + "Each person has transferable strengths. Each still needs direct practice in the "
            + "missing domains."
        let overrides = PronunciationOverrides.withBuiltInDefaults([:])
        let rewrite = overrides.rewrite(
            to: TextNormalizer.normalize(text),
            blockID: "reported-lifecycle")
        let rewriteLifecycle = try #require(
            rewrite.decisionSeeds.first {
                $0.normalizedWord == "lifecycle"
            })
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "reported-lifecycle", text: text, index: 0)],
            overrides: overrides)
        let plannedBlock = try #require(plan.blocks.first)
        let lifecycle = try #require(
            plannedBlock.pronunciationDecisions.first {
                $0.normalizedWord == "lifecycle"
            })

        #expect(lifecycle.wordStart == rewriteLifecycle.wordStart)
        #expect(lifecycle.wordEnd == rewriteLifecycle.wordEnd)
        #expect(lifecycle.source == .builtInOverride)
        #expect(lifecycle.ruleID == "override.built-in.lifecycle")
        #expect(lifecycle.selectedIPA == "lˈIfsˌIkəl")
        #expect(plannedBlock.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func aggregatePhonemeMismatchSuppressesDecisionAndMakesAuditIncomplete() throws {
        let validation = PronunciationEvidenceValidator.validate(
            snapshots: [
                PronunciationEvidenceValidator.Snapshot(
                    text: "startable",
                    whitespace: "",
                    selectedPhonemes: "stˈɑɹɾəbᵊl",
                    lexicalTag: "Noun",
                    rating: 5)
            ],
            displayText: "startable",
            finalPhonemes: "stˈɑɹTəbᵊl")
        let chunk = PlannedSynthesisChunk(
            displayText: "startable",
            g2pInputText: "[startable](/stˈɑɹɾəbᵊl/)",
            phonemes: "stˈɑɹTəbᵊl",
            phonemeIDs: [KokoroPhonemeVocab.boundaryTokenId]
                + Array(repeating: 1, count: "stˈɑɹTəbᵊl".count)
                + [KokoroPhonemeVocab.boundaryTokenId],
            wordCount: 1,
            pronunciationFallbackHits: [],
            pronunciationTokenEvidence: validation.evidence,
            pronunciationEvidenceValidation: validation.validation)
        let seed = PronunciationDecisionSeed(
            blockID: "mismatch",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "startable",
            sourceWord: "startable",
            sourceContext: "startable",
            selectedIPA: "stˈɑɹɾəbᵊl",
            source: .builtInOverride,
            ruleID: "override.built-in.startable",
            rationale: "Built-in override matched “startable”.")
        let materialization = NarrationRenderPlanner.materializedPronunciationEvidence(
            from: [seed],
            synthesisChunks: [chunk])
        let plannedBlock = NarrationPlannedBlock(
            blockID: "mismatch",
            originalBlock: block(id: "mismatch", text: "startable", index: 0),
            synthesisChunks: [chunk],
            pronunciationDecisions: materialization.decisions,
            pronunciationDecisionDiagnostics: materialization.diagnostics,
            trailingSilence: nil)
        let diagnostic = try #require(plannedBlock.pronunciationAuditDiagnostics.first)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/mismatch.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["startable"],
            decisions: materialization.decisions,
            diagnostics: plannedBlock.pronunciationAuditDiagnostics)

        #expect(validation.evidence.isEmpty)
        #expect(materialization.decisions.isEmpty)
        #expect(materialization.diagnostics.isEmpty)
        #expect(diagnostic.reason == .phonemeSequenceMismatch)
        #expect(diagnostic.finalPhonemes == "stˈɑɹTəbᵊl")
        #expect(diagnostic.reconstructedTokenPhonemes == "stˈɑɹɾəbᵊl")
        #expect(manifest.coverage == .incompleteEvidence)
    }

    @Test func rawBleUserOverrideMatchesFinalPreTTSPhonemesAndReceipt() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "possible", text: "This is possible.", index: 0)],
            overrides: PronunciationOverrides(entries: ["possible": "pˈɑsəbᵊl"]),
            maxPhonemes: 420)

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(plannedBlock.pronunciationDecisions.first)
        let expectedIPA = "pˈɑsəbəl"
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: expectedIPA)

        #expect(chunk.g2pInputText == "This is [possible](/pˈɑsəbᵊl/).")
        #expect(chunk.phonemes.contains(expectedIPA))
        #expect(!chunk.phonemes.contains("bᵊl"))
        #expect(decision.selectedIPA == expectedIPA)
        #expect(decision.kokoroTokenIDs == expectedIDs)
        #expect(plannedBlock.pronunciationDecisionDiagnostics.isEmpty)
    }

    @Test func unprovenUnencodablePlannerResultStillFailsPlanning() throws {
        let injectedPlanner = try PronunciationPlanner(
            g2pResult: { _, _ in
                KokoroG2P.Result(
                    phonemes: "\u{0000}",
                    fallbackHits: [],
                    tokenEvidence: [.init(
                        text: "ordinary",
                        selectedPhonemes: "ə",
                        lexicalTag: nil,
                        rating: 3,
                        displayCharacterRange: 0..<8,
                        phonemeCharacterRange: 0..<1,
                        usedFallback: false)],
                    pronunciationEvidenceValidation: .matched)
            })

        #expect(throws: Error.self) {
            _ = try NarrationRenderPlanner.make(
                blocks: [block(id: "unproven", text: "ordinary", index: 0)],
                overrides: PronunciationOverrides.withBuiltInDefaults([:]),
                pronunciationPlanner: injectedPlanner)
        }
    }

    @Test func verifiedInvalidRawG2PUsesOneDeterministicSpellingRescueChunk() throws {
        let rawResult = KokoroG2P.Result(
            phonemes: "\u{0000}",
            fallbackHits: [.init(word: "ordinary", ipa: "\u{0000}")],
            tokenEvidence: [.init(
                text: "ordinary",
                selectedPhonemes: "\u{0000}",
                lexicalTag: nil,
                rating: 1,
                displayCharacterRange: 0..<8,
                phonemeCharacterRange: 0..<1,
                usedFallback: true)],
            pronunciationEvidenceValidation: .matched)
        let planner = try PronunciationPlanner(g2pResult: { _, _ in rawResult })

        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "invalid-g2p-rescue", text: "ordinary", index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]),
            pronunciationPlanner: planner)
        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(plannedBlock.pronunciationDecisions.first)

        #expect(plannedBlock.synthesisChunks.count == 1)
        #expect(chunk.displayText == "ordinary")
        #expect(chunk.g2pInputText == "o r d i n a r y")
        #expect(!chunk.phonemes.isEmpty)
        #expect(!chunk.phonemeIDs.isEmpty)
        #expect(chunk.wordCount == 1)
        #expect(
            plannedBlock.synthesisChunks.flatMap {
                WordTokenizer.words(in: $0.displayText).map(String.init)
            } == ["ordinary"])
        #expect(decision.selectedIPA == "\u{0000}")
        #expect(decision.kokoroTokenIDs.isEmpty)
        #expect(decision.isEvidenceOnlyInvalidOutputAdvisory)
    }

    @Test func matchedOOVMarkerKeepsTheHistoricalSynthesisPathOutOfInvalidOutputReceipts()
        throws
    {
        let marker = String(KokoroPhonemeVocab.oovMarker)
        let planner = try PronunciationPlanner(
            g2pResult: { _, _ in
                KokoroG2P.Result(
                    phonemes: marker,
                    fallbackHits: [.init(word: "ordinary", ipa: marker)],
                    tokenEvidence: [.init(
                        text: "ordinary",
                        selectedPhonemes: marker,
                        lexicalTag: nil,
                        rating: 1,
                        displayCharacterRange: 0..<8,
                        phonemeCharacterRange: 0..<1,
                        usedFallback: true)],
                    pronunciationEvidenceValidation: .matched)
            })

        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "marker", text: "ordinary", index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]),
            pronunciationPlanner: planner)
        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)

        #expect(chunk.phonemes.isEmpty)
        #expect(plannedBlock.pronunciationDecisions.isEmpty)
        #expect(plannedBlock.pronunciationDecisionDiagnostics.isEmpty)
        #expect(!plannedBlock.pronunciationDecisions.contains {
            $0.kokoroTokenIDs.isEmpty && $0.selectedIPA == marker
        })

        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 1,
            anchors: [],
            pronunciationEvidence: .init(
                decisions: plannedBlock.pronunciationDecisions,
                diagnostics: plannedBlock.pronunciationDecisionDiagnostics))
        #expect(try HeadlessNarrationRunner.capturePayloadSHA256(capture).count == 64)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("af_heart"),
            captureCoverage: .incompleteEvidence,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/oov-marker.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: plannedBlock.pronunciationDecisions,
            diagnostics: plannedBlock.pronunciationDecisionDiagnostics)
        #expect(try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: manifest.encoded()) == manifest)
    }

    @Test func monitoredLexiconRawInvalidReceiptMaterializesOnlyUnderItsExactContract() throws {
        let validEvidence = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: nil,
            alternatives: [],
            selectionReason: .trustedLexicon,
            overrideSuppressedAutomation: false,
            policyVersion: "fixture-v1")
        let validSeed = PronunciationDecisionSeed(
            blockID: "monitored-invalid",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "ordinary",
            sourceWord: "ordinary",
            sourceContext: "ordinary",
            selectedIPA: "\u{0000}",
            source: .monitoredLexicon,
            ruleID: "g2p.lexicon.ordinary",
            rationale: "Raw G2P output was rejected.",
            advisoryEvidence: validEvidence)
        let valid = NarrationRenderPlanner.materializedPronunciationEvidence(
            from: [validSeed],
            synthesisChunks: [])

        let decision = try #require(valid.decisions.first)
        #expect(valid.decisions.count == 1)
        #expect(decision.advisoryEvidence?.isValid(for: decision) == true)
        #expect(decision.isEvidenceOnlyInvalidOutputAdvisory)

        let tamperedEvidence = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .trusted,
            selectedCandidateID: nil,
            alternatives: [],
            selectionReason: .sourceDisagreement,
            overrideSuppressedAutomation: false,
            policyVersion: "fixture-v1")
        let tamperedSeed = PronunciationDecisionSeed(
            blockID: validSeed.blockID,
            wordStart: validSeed.wordStart,
            wordEnd: validSeed.wordEnd,
            normalizedWord: validSeed.normalizedWord,
            sourceWord: validSeed.sourceWord,
            sourceContext: validSeed.sourceContext,
            selectedIPA: validSeed.selectedIPA,
            source: validSeed.source,
            ruleID: validSeed.ruleID,
            rationale: validSeed.rationale,
            advisoryEvidence: tamperedEvidence)
        let tampered = NarrationRenderPlanner.materializedPronunciationEvidence(
            from: [tamperedSeed],
            synthesisChunks: [])
        #expect(tampered.decisions.isEmpty)
    }

    @Test func matchedOOVMarkerPlusValidIPAStaysOnTheOrdinaryMaterializedPath()
        throws
    {
        let marker = String(KokoroPhonemeVocab.oovMarker)
        let rawIPA = marker + "ə"
        let planner = try PronunciationPlanner(
            g2pResult: { _, _ in
                KokoroG2P.Result(
                    phonemes: rawIPA,
                    fallbackHits: [.init(word: "ordinary", ipa: rawIPA)],
                    tokenEvidence: [.init(
                        text: "ordinary",
                        selectedPhonemes: rawIPA,
                        lexicalTag: nil,
                        rating: 1,
                        displayCharacterRange: 0..<8,
                        phonemeCharacterRange: 0..<1,
                        usedFallback: true)],
                    pronunciationEvidenceValidation: .matched)
            })

        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "mixed-marker", text: "ordinary", index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]),
            pronunciationPlanner: planner)
        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(plannedBlock.pronunciationDecisions.first)

        #expect(chunk.phonemes == "ə")
        #expect(!chunk.phonemeIDs.isEmpty)
        #expect(plannedBlock.synthesisChunks.count == 1)
        #expect(plannedBlock.pronunciationDecisions.count == 1)
        #expect(plannedBlock.pronunciationDecisionDiagnostics.isEmpty)
        #expect(decision.selectedIPA == "ə")
        #expect(!decision.kokoroTokenIDs.isEmpty)
        #expect(!decision.isEvidenceOnlyInvalidOutputAdvisory)

        let capture = HeadlessNarrationRunner.ChapterCapture(
            duration: 1,
            anchors: [],
            pronunciationEvidence: .init(
                decisions: plannedBlock.pronunciationDecisions,
                diagnostics: plannedBlock.pronunciationDecisionDiagnostics))
        #expect(try HeadlessNarrationRunner.capturePayloadSHA256(capture).count == 64)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 15,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/mixed-oov-marker.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: plannedBlock.pronunciationDecisions,
            diagnostics: plannedBlock.pronunciationDecisionDiagnostics)
        #expect(try JSONDecoder().decode(
            PronunciationAuditManifest.self,
            from: manifest.encoded()) == manifest)
    }

    @Test func sameSpanWrongFinalIPASuppressesRuleAndMakesAuditIncomplete() throws {
        let chunk = try PronunciationPlanner().planResolved("[record](/ɹəkˈɔɹd/)")
        let seed = PronunciationDecisionSeed(
            blockID: "wrong-ipa",
            wordStart: 0,
            wordEnd: 0,
            normalizedWord: "record",
            sourceWord: "record",
            sourceContext: "record",
            selectedIPA: "ɹˈɛkəɹd",
            source: .contextualHomograph,
            ruleID: "homograph.record.noun.fallback",
            rationale: "Noun pronunciation selected for “record”.")
        let materialization = NarrationRenderPlanner.materializedPronunciationEvidence(
            from: [seed],
            synthesisChunks: [chunk])
        let plannedBlock = NarrationPlannedBlock(
            blockID: "wrong-ipa",
            originalBlock: block(id: "wrong-ipa", text: "record", index: 0),
            synthesisChunks: [chunk],
            pronunciationDecisions: materialization.decisions,
            pronunciationDecisionDiagnostics: materialization.diagnostics,
            trailingSilence: nil)
        let diagnostic = try #require(plannedBlock.pronunciationAuditDiagnostics.first)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/wrong-ipa.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["record"],
            decisions: materialization.decisions,
            diagnostics: plannedBlock.pronunciationAuditDiagnostics)

        #expect(materialization.decisions.isEmpty)
        #expect(materialization.diagnostics.count == 1)
        #expect(diagnostic.reason == .decisionEvidenceMismatch)
        #expect(diagnostic.finalPhonemes == "ɹəkˈɔɹd")
        #expect(manifest.coverage == .incompleteEvidence)
    }

    @Test func decisionSourceRawValuesAreStableSchemaValues() {
        let sources: [PronunciationAuditDecision.Source] = [
            .occurrenceOverride,
            .bookOverride,
            .globalOverride,
            .builtInOverride,
            .contextualHomograph,
            .monitoredLexicon,
            .fallback,
        ]

        #expect(
            sources.map(\.rawValue) == [
                "occurrenceOverride",
                "bookOverride",
                "globalOverride",
                "builtInOverride",
                "contextualHomograph",
                "monitoredLexicon",
                "fallback",
            ])
    }

    @Test func preparedOccurrenceDecisionWinsOverBookOverride() throws {
        let sourceBlock = block(id: "b0", text: "The content stays here.", index: 0)
        let occurrence = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "b0",
                wordStart: 1,
                wordEnd: 1,
                word: "content",
                ipa: "kˈɑntɛnt")
        ]).rewrite(to: sourceBlock.text ?? "", blockID: "b0")
        var rewrittenBlock = sourceBlock
        rewrittenBlock.text = occurrence.text
        let prepared = NarrationPreparedBlock(
            block: rewrittenBlock,
            pronunciationDecisionSeeds: occurrence.decisionSeeds)

        let plan = try NarrationRenderPlanner.make(
            preparedBlocks: [prepared],
            overrides: PronunciationOverrides(
                entries: ["content": "kəntˈɛnt"],
                source: .bookOverride))

        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        #expect(plan.blocks.first?.pronunciationDecisions.count == 1)
        #expect(decision.source == .occurrenceOverride)
        #expect(decision.selectedIPA == "kˈɑntɛnt")
        #expect(
            plan.blocks.first?.synthesisChunks.first?.g2pInputText.contains("[content](/kˈɑntɛnt/)")
                == true)
    }

    @Test func standaloneContentHeadingUsesMaterialNounFallback() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "heading", text: "Content", kind: "heading", index: 0)],
            overrides: PronunciationOverrides(entries: [:]))

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first {
                $0.normalizedWord == "content"
            })

        #expect(chunk.displayText == "Content")
        #expect(chunk.g2pInputText == "Content")
        #expect(chunk.phonemes == "kˈɑntɛnt")
        #expect(decision.source == .monitoredLexicon)
        #expect(decision.ruleID == "g2p.lexicon.content")
        #expect(decision.selectedIPA == "kˈɑntɛnt")
    }

    @Test func bookOverrideWinsOverGlobalOverrideWithBookProvenance() throws {
        let overrides = PronunciationOverrides.merging(
            global: PronunciationOverrides(entries: ["record": "ɹˈɛkəɹd"]),
            book: ["record": "ɹəkˈɔɹd"])
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "Please record the result.", index: 0)],
            overrides: overrides)

        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        #expect(plan.blocks.first?.pronunciationDecisions.count == 1)
        #expect(decision.source == .bookOverride)
        #expect(decision.ruleID == "override.book.record")
        #expect(decision.selectedIPA == "ɹəkˈɔɹd")
    }

    @Test func globalOverrideWinsOverBuiltInWithGlobalProvenance() throws {
        let overrides = PronunciationOverrides.withBuiltInDefaults([
            "STARTABLE": "stˈɑɹtəbəl"
        ])
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "The process is startable.", index: 0)],
            overrides: overrides)

        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        #expect(plan.blocks.first?.pronunciationDecisions.count == 1)
        #expect(decision.source == .globalOverride)
        #expect(decision.ruleID == "override.global.startable")
        #expect(decision.selectedIPA == "stˈɑɹtəbəl")
    }

    @Test func builtInScopedOverrideWinsOverContextualResolution() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "Please record the result.", index: 0)],
            overrides: PronunciationOverrides(
                entries: ["record": "ɹˈɛkəɹd"],
                source: .builtInOverride))

        let decision = try #require(plan.blocks.first?.pronunciationDecisions.first)
        #expect(plan.blocks.first?.pronunciationDecisions.count == 1)
        #expect(decision.source == .builtInOverride)
        #expect(decision.ruleID == "override.built-in.record")
        #expect(decision.selectedIPA == "ɹˈɛkəɹd")
    }

    @Test func auditsSixWordWatchMatrixAndFallbackFromPlannedChunks() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [
                block(
                    id: "watch",
                    text:
                        "The process is startable. The filesystem was verified. "
                        + "They live there. Their lives changed. Please record it.",
                    index: 0),
                block(id: "fallback", text: "A Xyzqwf appears.", index: 1),
            ],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]),
            maxPhonemes: 35)

        let watchBlock = try #require(plan.blocks.first { $0.blockID == "watch" })
        #expect(watchBlock.synthesisChunks.count > 1)
        let decisions = Dictionary(
            uniqueKeysWithValues: watchBlock.pronunciationDecisions.map {
                ($0.normalizedWord, $0)
            })

        let startable = try #require(decisions["startable"])
        #expect(startable.wordStart == 3)
        #expect(startable.wordEnd == 3)
        #expect(startable.source == .builtInOverride)
        #expect(startable.ruleID == "override.built-in.startable")

        let filesystem = try #require(decisions["filesystem"])
        #expect(filesystem.wordStart == 5)
        #expect(filesystem.wordEnd == 5)
        #expect(filesystem.source == .builtInOverride)
        #expect(filesystem.ruleID == "override.built-in.filesystem")

        let verified = try #require(decisions["verified"])
        #expect(verified.wordStart == 7)
        #expect(verified.wordEnd == 7)
        #expect(verified.source == .monitoredLexicon)
        #expect(verified.selectedIPA == "vˈɛɹəfˌId")
        #expect(
            verified.kokoroTokenIDs
                == (try PronunciationPlanner().phonemeIDs(forIPA: verified.selectedIPA)))
        #expect(verified.ruleID == "g2p.lexicon.verified")

        let live = try #require(decisions["live"])
        #expect(live.wordStart == 9)
        #expect(live.wordEnd == 9)
        #expect(live.source == .contextualHomograph)
        #expect(live.ruleID == "homograph.live.verb.preceder")

        let lives = try #require(decisions["lives"])
        #expect(lives.wordStart == 12)
        #expect(lives.wordEnd == 12)
        #expect(lives.source == .contextualHomograph)
        #expect(lives.ruleID == "homograph.lives.noun.preceder")

        let record = try #require(decisions["record"])
        #expect(record.wordStart == 15)
        #expect(record.wordEnd == 15)
        #expect(record.source == .contextualHomograph)
        #expect(record.ruleID == "homograph.record.verb.preceder")

        let fallbackBlock = try #require(plan.blocks.first { $0.blockID == "fallback" })
        let fallback = try #require(
            fallbackBlock.pronunciationDecisions.first {
                $0.normalizedWord == "xyzqwf"
            })
        #expect(fallback.wordStart == 1)
        #expect(fallback.wordEnd == 1)
        #expect(fallback.source == .fallback)
        #expect(fallback.selectedIPA == "zˈizkwf")
        #expect(fallback.ruleID == "g2p.fallback.xyzqwf")
        #expect(!fallback.kokoroTokenIDs.isEmpty)

        let keys = plan.blocks.flatMap(\.pronunciationDecisions).map {
            "\($0.blockID):\($0.wordStart):\($0.wordEnd)"
        }
        #expect(Set(keys).count == keys.count)
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func watchVocabularyRemainsGlobalWhenABlockOmitsWatchedTerms() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "verified-only", text: "It was verified.", index: 0)],
            overrides: PronunciationOverrides(entries: [:]))

        #expect(
            plan.blocks.first?.pronunciationDecisions.map(\.normalizedWord)
                == ["verified"])
        #expect(
            PronunciationWatchVocabulary.words.isSuperset(
                of: Set(["startable", "filesystem", "verified", "live", "lives", "record"])))
    }

    @Test func mismatchedEvidenceRemainsAuditIncompleteAcrossPlanningBoundaries() throws {
        let planner = try PronunciationPlanner()
        let fallbackChunk = try planner.plan(
            displayText: "different",
            g2pInputText: "Xyzqwf")
        let lexiconChunk = try planner.plan(
            displayText: "another",
            g2pInputText: "verified")

        #expect(!fallbackChunk.phonemes.isEmpty)
        #expect(fallbackChunk.pronunciationTokenEvidence.isEmpty)
        #expect(
            fallbackChunk.pronunciationEvidenceValidation
                == .mismatch(
                    expectedDisplayText: "different",
                    reconstructedSpokenSurface: "Xyzqwf"))
        #expect(!fallbackChunk.pronunciationFallbackHits.isEmpty)

        let plannedBlock = NarrationPlannedBlock(
            blockID: "mismatch",
            originalBlock: block(id: "mismatch", text: "different", index: 0),
            synthesisChunks: [fallbackChunk, lexiconChunk],
            pronunciationDecisions: [],
            pronunciationDecisionDiagnostics: [],
            trailingSilence: nil)
        let renderPlan = NarrationRenderPlan(blocks: [plannedBlock])

        #expect(plannedBlock.pronunciationDecisions.isEmpty)
        #expect(plannedBlock.pronunciationAuditDiagnostics.count == 2)
        let fallbackDiagnostic = try #require(
            plannedBlock.pronunciationAuditDiagnostics.first)
        #expect(fallbackDiagnostic.reason == .spokenSurfaceMismatch)
        #expect(fallbackDiagnostic.blockID == "mismatch")
        #expect(fallbackDiagnostic.chunkIndex == 0)
        #expect(fallbackDiagnostic.expectedDisplayText == "different")
        #expect(fallbackDiagnostic.reconstructedSpokenSurface == "Xyzqwf")
        #expect(fallbackDiagnostic.fallbackHits == fallbackChunk.pronunciationFallbackHits)

        let noFallbackDiagnostic = plannedBlock.pronunciationAuditDiagnostics[1]
        #expect(noFallbackDiagnostic.chunkIndex == 1)
        #expect(noFallbackDiagnostic.fallbackHits.isEmpty)
        #expect(
            renderPlan.pronunciationAuditDiagnostics == plannedBlock.pronunciationAuditDiagnostics)

        let encoded = try JSONEncoder().encode(renderPlan.pronunciationAuditDiagnostics)
        #expect(
            try JSONDecoder().decode(
                [PronunciationAuditDiagnostic].self,
                from: encoded) == renderPlan.pronunciationAuditDiagnostics)
    }

    @Test func plansSpeechBlocksWithNormalizedOverrideText() throws {
        let blocks = [
            block(id: "b0", text: "Deploy Kubernetes — now.", index: 0)
        ]
        let overrides = PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])

        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: overrides,
            maxChars: 350)

        #expect(plan.blocks.count == 1)
        #expect(plan.blocks[0].blockID == "b0")
        // The spaced dash normalizes to a *standalone* comma, so the planned text
        // keeps one whitespace-delimited word per source word — the invariant the
        // sidecar's word rows are indexed by.
        #expect(
            plan.blocks[0].synthesisChunks.map(\.g2pInputText)
                == ["Deploy [Kubernetes](/kuːbərˈnɛtɪs/) , now."])
        #expect(
            plan.blocks[0].synthesisChunks.reduce(0) { $0 + $1.wordCount }
                == WordTokenizer.words(in: "Deploy Kubernetes — now.").count)
        #expect(plan.blocks[0].trailingSilence == nil)
    }

    @Test(arguments: [
        ("$100 billion", "one hundred billion dollars"),
        ("$5.50 million", "five point five million dollars"),
        ("-$2 billion", "minus two billion dollars"),
        ("+£1 billion", "plus one billion pounds"),
        (
            "£1,234.56",
            "one thousand, two hundred and thirty-four pounds and fifty-six pence"
        ),
        ("€2 trillion", "two trillion euros"),
    ])
    func validCurrencyReachesSemanticG2PThroughNarrationPlan(
        source: String,
        expectedSpoken: String
    ) throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "currency", text: source, index: 0)],
            overrides: PronunciationOverrides(entries: [:]))
        let plannedBlock = try #require(plan.blocks.first)
        #expect(plannedBlock.synthesisChunks.count == 1)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let semanticEvidence = try #require(
            chunk.pronunciationTokenEvidence.first { $0.text == source && $0.rating == 4 })

        #expect(chunk.displayText == source)
        #expect(chunk.g2pInputText == source)
        #expect(chunk.phonemes == KokoroG2P().phonemes(for: expectedSpoken))
        #expect(semanticEvidence.selectedPhonemes == chunk.phonemes)
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test(arguments: [
        ("$2-3", "$2"),
        ("£2-3", "£2"),
        ("$2 bn", "$2"),
        ("€2 bn", "€2"),
        ("$2 quadrillion", "$2"),
        ("$1,23", "$1,23"),
        ("A$5", "$5"),
        ("--$2", "-$2"),
        ("-$-2", "$-2"),
    ])
    func rejectedCurrencyReachesNarrationPlanAndAuditManifestIntact(
        source: String,
        rejectedSemanticSurface: String
    ) throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "currency", text: source, index: 0)],
            overrides: PronunciationOverrides(entries: [:]))
        let plannedBlock = try #require(plan.blocks.first)
        #expect(plannedBlock.synthesisChunks.count == 1)
        let chunk = try #require(plannedBlock.synthesisChunks.first)

        #expect(chunk.displayText == source)
        #expect(chunk.g2pInputText == source)
        #expect(!chunk.phonemes.isEmpty)
        #expect(
            !chunk.pronunciationTokenEvidence.contains {
                $0.text == rejectedSemanticSurface && $0.rating == 4
            })
        #expect(plan.pronunciationAuditDiagnostics.count == 1)
        let diagnostic = try #require(plan.pronunciationAuditDiagnostics.first)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/currency-rejection.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: plannedBlock.pronunciationDecisions,
            diagnostics: plan.pronunciationAuditDiagnostics)

        #expect(diagnostic.reason == .currencyNormalizationRejected)
        #expect(diagnostic.blockID == "currency")
        #expect(diagnostic.chunkIndex == 0)
        #expect(diagnostic.expectedDisplayText.isEmpty)
        #expect(diagnostic.reconstructedSpokenSurface.isEmpty)
        #expect(diagnostic.fallbackHits.isEmpty)
        #expect(diagnostic.finalPhonemes == nil)
        #expect(diagnostic.reconstructedTokenPhonemes == nil)
        #expect(manifest.diagnostics == [diagnostic])
        #expect(manifest.coverage == .incompleteEvidence)
    }

    @Test func currencyProtectionStillNormalizesNearbyProse() throws {
        let source = "Dr. Ada reported $100 billion at 3:30."
        let expected = "Doctor Ada reported $100 billion at three thirty."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "currency-context", text: source, index: 0)],
            overrides: PronunciationOverrides(entries: [:]))
        let plannedBlock = try #require(plan.blocks.first)
        #expect(plannedBlock.synthesisChunks.count == 1)
        let chunk = try #require(plannedBlock.synthesisChunks.first)

        #expect(chunk.displayText == expected)
        #expect(chunk.g2pInputText == expected)
        #expect(
            chunk.pronunciationTokenEvidence.contains {
                $0.text == "$100 billion" && $0.rating == 4
            })
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func rawBlockOverloadResolvesCodeCueAndFallbackBeforePlanning() throws {
        var captioned = block(
            id: "captioned-code",
            text: "let value = answer + 42",
            kind: EPubBlockRecord.Kind.code.rawValue,
            index: 0)
        captioned.narrationText = "Example value assignment."
        var fallback = block(
            id: "fallback-code",
            text: "print(rawSyntaxMustNotBeSpoken)",
            kind: EPubBlockRecord.Kind.code.rawValue,
            index: 1)
        fallback.narrationText = "   "

        let plan = try NarrationRenderPlanner.make(
            blocks: [captioned, fallback],
            overrides: PronunciationOverrides(entries: ["example": "tˈɛst"]))
        let displayText = plan.blocks.flatMap(\.synthesisChunks).map(\.displayText)

        #expect(displayText == ["Example value assignment.", NarrationCodeBlockCue.fallback])
        #expect(!displayText.contains { $0.contains("answer") })
        #expect(!displayText.contains { $0.contains("rawSyntaxMustNotBeSpoken") })
        #expect(plan.blocks.allSatisfy { $0.pronunciationDecisions.isEmpty })
    }

    @Test func decorativeBlockBecomesSectionBreakSilenceOnly() throws {
        let blocks = [
            block(id: "b0", text: "Before.", index: 0),
            block(id: "b1", text: "* * *", index: 1),
            block(id: "b2", text: "After.", index: 2),
        ]

        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks.map(\.blockID) == ["b0", "b1", "b2"])
        #expect(plan.blocks[0].synthesisChunks.map(\.displayText) == ["Before."])
        #expect(plan.blocks[0].trailingSilence == nil)
        #expect(plan.blocks[1].synthesisChunks.isEmpty)
        #expect(plan.blocks[1].trailingSilence == .sectionBreak)
        #expect(plan.blocks[2].synthesisChunks.map(\.displayText) == ["After."])
    }

    @Test func finalSpeakableBlockHasNoTrailingParagraphPause() throws {
        let blocks = [
            block(id: "b0", text: "Before.", index: 0),
            block(id: "b1", text: "After.", index: 1),
        ]

        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks[0].trailingSilence == .paragraph)
        #expect(plan.blocks[1].trailingSilence == nil)
    }

    @Test func headingGetsLongerPauseThanParagraph() throws {
        let blocks = [
            block(id: "h", text: "Chapter One", kind: "heading", index: 0),
            block(id: "p", text: "The first paragraph.", index: 1),
        ]

        let plan = try NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks[0].trailingSilence == .heading)
        #expect(plan.blocks[1].trailingSilence == nil)
    }

    @Test func resolvesFullBlockBeforePlanningChunks() throws {
        let overrides = PronunciationOverrides(entries: ["filesystem": "fˈIl sˌɪstəm"])
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "b0", text: "They live by the filesystem.", index: 0)],
            overrides: overrides,
            maxPhonemes: 420
        )

        let chunk = try #require(plan.blocks.first?.synthesisChunks.first)
        #expect(chunk.displayText == "They live by the filesystem.")
        #expect(chunk.g2pInputText.contains("[live](/lˈɪv/)"))
        #expect(chunk.g2pInputText.contains("[filesystem](/fˈIl sˌɪstəm/)"))
        #expect(chunk.phonemeIDs.count > 2)
    }

    @Test func naturalContextHomographsReachPlannedTTS() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [
                block(
                    id: "lives",
                    text: "That gap is where this entire subject lives.",
                    index: 0),
                block(
                    id: "record",
                    text: "Listen and record whatever it says.",
                    index: 1),
            ],
            overrides: PronunciationOverrides(entries: [:]),
            maxPhonemes: 420
        )

        let chunks = plan.blocks.flatMap(\.synthesisChunks)
        let g2pInputText = chunks.map(\.g2pInputText).joined(separator: " ")
        let phonemes = chunks.map(\.phonemes).joined(separator: " ")

        #expect(g2pInputText.contains("[lives](/lˈɪvz/)"))
        #expect(g2pInputText.contains("[record](/ɹəkˈɔɹd/)"))
        #expect(phonemes.contains("lˈɪvz"))
        #expect(phonemes.contains("ɹəkˈɔɹd"))
    }

    @Test func trailingMaterialLivesRuleReachesExactPreTTSPlanAndReceipt() throws {
        let source = "That gap is where this entire subject lives today."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "lives-today", text: source, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            maxPhonemes: 420)

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first { $0.normalizedWord == "lives" })
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: "lˈɪvz")

        #expect(chunk.displayText == source)
        #expect(
            chunk.g2pInputText
                == "That gap is where this entire subject [lives](/lˈɪvz/) today.")
        #expect(chunk.phonemes.contains("lˈɪvz"))
        #expect(decision.selectedIPA == "lˈɪvz")
        #expect(decision.kokoroTokenIDs == expectedIDs)
        #expect(decision.source == .contextualHomograph)
        #expect(decision.ruleID == "homograph.lives.verb.subject")
    }

    @Test func descriptiveLivesNounRuleReachesExactPreTTSPlanAndReceipt() throws {
        let source = "This is one of the strangest lives in the story."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "lives-superlative", text: source, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            maxPhonemes: 420)

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first { $0.normalizedWord == "lives" })
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: "lˈIvz")

        #expect(chunk.displayText == source)
        #expect(
            chunk.g2pInputText
                == "This is one of the strangest [lives](/lˈIvz/) in the story.")
        #expect(chunk.phonemes.contains("lˈIvz"))
        #expect(decision.selectedIPA == "lˈIvz")
        #expect(decision.kokoroTokenIDs == expectedIDs)
        #expect(decision.source == .contextualHomograph)
        #expect(decision.ruleID == "homograph.lives.noun.one-of-superlative")
    }

    @Test func superpositionLongUReachesExactPreTTSPlanAndReceipt() throws {
        let source = "Researchers call this superposition."
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "superposition", text: source, index: 0)],
            overrides: PronunciationOverrides.withBuiltInDefaults([:]),
            maxPhonemes: 420)

        let plannedBlock = try #require(plan.blocks.first)
        let chunk = try #require(plannedBlock.synthesisChunks.first)
        let decision = try #require(
            plannedBlock.pronunciationDecisions.first {
                $0.normalizedWord == "superposition"
            })
        let expectedIPA = "sˌuːpɚpəzˈɪʃən"
        let expectedIDs = try PronunciationPlanner().phonemeIDs(forIPA: expectedIPA)

        #expect(chunk.displayText == source)
        #expect(
            chunk.g2pInputText
                == "Researchers call this [superposition](/sˌuːpɚpəzˈɪʃən/).")
        #expect(chunk.phonemes.contains(expectedIPA))
        #expect(decision.selectedIPA == expectedIPA)
        #expect(decision.kokoroTokenIDs == expectedIDs)
        #expect(decision.source == .builtInOverride)
        #expect(decision.ruleID == "override.built-in.superposition")
    }

    @Test func naturalContextFalsePositivesStayOutOfPlannedTTS() throws {
        let sourceText = [
            "Where should we meet? Lives changed.",
            "They remember where lives were lost.",
            "They remember where innocent lives were lost.",
            "They cited the world record, which still stands.",
        ]
        let plan = try NarrationRenderPlanner.make(
            blocks: sourceText.enumerated().map { index, text in
                block(id: "negative-\(index)", text: text, index: index)
            },
            overrides: PronunciationOverrides(entries: [:]),
            maxPhonemes: 420
        )

        let g2pInputText = plan.blocks
            .flatMap(\.synthesisChunks)
            .map(\.g2pInputText)

        #expect(g2pInputText == sourceText)
        #expect(!g2pInputText.contains { $0.contains("[lives](/lˈɪvz/)") })
        #expect(!g2pInputText.contains { $0.contains("[record](/ɹəkˈɔɹd/)") })
    }

    @Test func universalResolutionRunsAfterOverridesAndBeforeContextualHomographs() throws {
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            automaticEntries: [
                "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ"),
                "record": ("cmudict.record.fixture", "wrong"),
            ])
        let plan = try NarrationRenderPlanner.make(
            blocks: [
                block(
                    id: "universal",
                    text: "Please record foobar and startable.",
                    index: 0)
            ],
            overrides: PronunciationOverrides(entries: [:]),
            pronunciationPack: pack)

        let planned = try #require(plan.blocks.first)
        let resolved = planned.synthesisChunks.map(\.g2pInputText).joined(separator: " ")
        let decisions = Dictionary(
            uniqueKeysWithValues: planned.pronunciationDecisions.map {
                ($0.normalizedWord, $0)
            })

        #expect(resolved.contains("[record](/ɹəkˈɔɹd/)"))
        #expect(resolved.contains("[foobar](/fˈubɑɹ/)"))
        #expect(resolved.contains("[startable](/stˈɑɹtəbəl/)"))
        #expect(decisions["record"]?.source == .contextualHomograph)
        #expect(decisions["foobar"]?.source == .supplementalLexicon)
        #expect(decisions["startable"]?.source == .derivedMorphology)
    }

    @Test func straightAndCurlyApostropheCandidatesMaterializeIdenticalAuditProvenance() throws {
        let candidateID = "cmudict.aujourd'hui.fixture"
        let packVersion =
            "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        let ipa = "oʒuɹdɥˈi"
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion: packVersion,
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            automaticEntries: [
                "aujourd'hui": (candidateID, ipa)
            ])
        let authoredWords = ["aujourd'hui", "aujourd’hui"]
        let plan = try NarrationRenderPlanner.make(
            blocks: authoredWords.enumerated().map { index, word in
                block(id: "apostrophe-\(index)", text: "An \(word) example.", index: index)
            },
            overrides: PronunciationOverrides(entries: [:]),
            pronunciationPack: pack)

        #expect(plan.blocks.count == authoredWords.count)
        for (index, authoredWord) in authoredWords.enumerated() {
            let planned = plan.blocks[index]
            let chunk = try #require(planned.synthesisChunks.first)
            let decision = try #require(planned.pronunciationDecisions.first)

            #expect(planned.pronunciationDecisions.count == 1)
            #expect(planned.pronunciationDecisionDiagnostics.isEmpty)
            #expect(planned.pronunciationAuditDiagnostics.isEmpty)
            #expect(chunk.g2pInputText == "An [\(authoredWord)](/\(ipa)/) example.")
            #expect(chunk.phonemes.contains(ipa))
            #expect(decision.normalizedWord == "aujourd'hui")
            #expect(decision.sourceWord == authoredWord)
            #expect(decision.wordStart == 1)
            #expect(decision.wordEnd == 1)
            #expect(decision.selectedIPA == ipa)
            #expect(!decision.kokoroTokenIDs.isEmpty)
            #expect(decision.source == .supplementalLexicon)
            #expect(decision.candidateID == candidateID)
            #expect(decision.candidatePackVersion == packVersion)
        }
    }

    @Test func overrideWinsUniversalCandidateAndFirstSeedForSpanStaysFrozen() throws {
        let pack = EnglishPronunciationPack.emptyForTesting(
            packVersion:
                "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            kokoroVocabularyVersion:
                "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            automaticEntries: [
                "foobar": ("cmudict.foobar.fixture", "fˈubɑɹ")
            ])
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "override", text: "A foobar appeared.", index: 0)],
            overrides: PronunciationOverrides(
                entries: ["foobar": "fˈoʊbɑɹ"],
                source: .globalOverride),
            pronunciationPack: pack)

        let planned = try #require(plan.blocks.first)
        let decision = try #require(planned.pronunciationDecisions.first)
        #expect(planned.pronunciationDecisions.count == 1)
        #expect(decision.source == .globalOverride)
        #expect(decision.selectedIPA == "fˈoʊbɑɹ")
        #expect(
            planned.synthesisChunks.first?.g2pInputText
                == "A [foobar](/fˈoʊbɑɹ/) appeared.")
    }

    @Test func contextualEvidenceAttachesOnlyToItsExactSourceDecision() throws {
        let text = "Please record this."
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: text,
                blockID: "context"
            ).first)
        let evidence = contextualEvidence(for: occurrence, slot: .b)
        let key = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)

        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "context", text: text, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            contextualEvidence: [key: evidence])
        let decision = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "record"
            })

        #expect(decision.contextualEvidence == evidence)
        #expect(decision.selectedIPA == "ɹəkˈɔɹd")
        #expect(decision.contextualEvidence?.modelCandidateID == "record.verb")
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func hyphenatedMonitoredLexiconDecisionReceivesContextualEvidence() throws {
        let text = "Use read-only access."
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: text,
                blockID: "hyphenated-context"
            ).first)
        let evidence = contextualEvidence(for: occurrence, slot: .a)
        let key = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)

        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "hyphenated-context", text: text, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            contextualEvidence: [key: evidence])
        let decision = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "read"
            })

        #expect(decision.wordStart == 1)
        #expect(decision.wordEnd == 1)
        #expect(decision.selectedIPA == "ɹˈid")
        #expect(decision.source == .monitoredLexicon)
        #expect(decision.contextualEvidence == evidence)
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func hyphenatedCompoundFamilySeedSurvivesAuditComparisonComponent() throws {
        // Regression: with an audit-pack entry for "re", the "re" token of
        // "re-read" minted a comparison-candidate seed at the same whitespace
        // word span as the family "read" seed, won first-wins dedup, consumed
        // the span-keyed contextual evidence, and failed phase-two identity
        // validation — aborting the whole render.
        let text = "A figure resurfaces; a wall of prose mostly does not get re-read."
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: text,
                blockID: "hyphenated-audit-context"
            ).first)
        let evidence = contextualEvidence(for: occurrence, slot: .a)
        let key = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)

        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "hyphenated-audit-context", text: text, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            pronunciationAuditPack: auditPack(coveringWords: ["re"]),
            contextualEvidence: [key: evidence])
        let decision = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "read"
            })

        #expect(decision.wordStart == occurrence.wordStart)
        #expect(decision.wordEnd == occurrence.wordEnd)
        #expect(decision.source == .monitoredLexicon)
        #expect(decision.contextualEvidence == evidence)
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func hyphenatedCompoundClassFamilyDecisionsReceiveContextualEvidence() throws {
        // Same class as "re-read": the non-family component leads the
        // compound and carries an audit-pack comparison entry.
        let cases: [(text: String, familyWord: String)] = [
            ("She is well-read.", "read"),
            ("They pre-record the intro.", "record"),
            ("They re-record the intro.", "record"),
        ]
        let comparisonAuditPack = try auditPack(coveringWords: ["re", "pre", "well"])

        for (index, testCase) in cases.enumerated() {
            let blockID = "hyphenated-class-\(index)"
            let occurrence = try #require(
                ContextualPronunciationDiscovery.discover(
                    text: testCase.text,
                    blockID: blockID
                ).first,
                "Expected a contextual occurrence in \(testCase.text)")
            let evidence = contextualEvidence(for: occurrence, slot: .a)
            let key = ContextualPronunciationKey(
                blockID: occurrence.blockID,
                wordStart: occurrence.wordStart,
                wordEnd: occurrence.wordEnd)

            let plan = try NarrationRenderPlanner.make(
                blocks: [block(id: blockID, text: testCase.text, index: 0)],
                overrides: PronunciationOverrides(entries: [:]),
                pronunciationAuditPack: comparisonAuditPack,
                contextualEvidence: [key: evidence])
            let decision = try #require(
                plan.blocks.first?.pronunciationDecisions.first {
                    $0.normalizedWord == testCase.familyWord
                },
                "Expected a \(testCase.familyWord) decision for \(testCase.text)")

            #expect(decision.wordStart == occurrence.wordStart)
            #expect(decision.wordEnd == occurrence.wordEnd)
            #expect(decision.source == .monitoredLexicon)
            #expect(decision.contextualEvidence == evidence)
            #expect(plan.pronunciationAuditDiagnostics.isEmpty)
        }
    }

    @Test func emDashJoinedMonitoredLexiconDecisionReceivesContextualEvidence() throws {
        let text = "Generate code or content—so it works."
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: text,
                blockID: "em-dash-context"
            ).first)
        let evidence = contextualEvidence(for: occurrence, slot: .a)
        let key = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)

        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "em-dash-context", text: text, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            contextualEvidence: [key: evidence])
        let decision = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "content"
            })

        #expect(decision.wordStart == 3)
        #expect(decision.wordEnd == 3)
        #expect(decision.selectedIPA == "kˈɑntɛnt")
        #expect(decision.source == .monitoredLexicon)
        #expect(decision.contextualEvidence == evidence)
        #expect(plan.pronunciationAuditDiagnostics.isEmpty)
    }

    @Test func contextualEvidenceIdentityAndCandidatePackMismatchesFailClosed() throws {
        let text = "Please record this."
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: text,
                blockID: "context"
            ).first)
        let exactKey = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)
        let exact = contextualEvidence(for: occurrence, slot: .a)
        let malformed: [(ContextualPronunciationKey, ContextualPronunciationEvidence)] = [
            (
                ContextualPronunciationKey(
                    blockID: occurrence.blockID,
                    wordStart: occurrence.wordStart + 1,
                    wordEnd: occurrence.wordEnd + 1),
                exact
            ),
            (
                exactKey,
                replacingContextualEvidence(exact, familyID: "read")
            ),
            (
                exactKey,
                replacingContextualEvidence(
                    exact,
                    submittedCandidateIDs: ["record.noun"])
            ),
            (
                exactKey,
                replacingContextualEvidence(
                    exact,
                    candidatePackVersion: "context-candidates-unknown")
            ),
        ]

        for (key, evidence) in malformed {
            #expect(throws: NarrationRenderPlanError.self) {
                _ = try NarrationRenderPlanner.make(
                    blocks: [block(id: "context", text: text, index: 0)],
                    overrides: PronunciationOverrides(entries: [:]),
                    contextualEvidence: [key: evidence])
            }
        }
    }

    @Test func contradictoryPhaseTwoContextualEvidenceFailsPlannerAttachment() throws {
        let text = "Please record this."
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: text,
                blockID: "context"
            ).first)
        let exactKey = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)
        let exact = contextualEvidence(for: occurrence, slot: .a)
        let malformed = [
            replacingContextualEvidence(
                exact,
                occurrenceID: "unknown-occurrence"),
            replacingContextualEvidence(
                exact,
                modelCandidateID: .some(nil)),
            replacingContextualEvidence(
                exact,
                modelAbstained: true),
            replacingContextualEvidence(
                exact,
                modelCandidateID: .some(nil),
                modelAbstained: false,
                acceptanceReason: .shadowNeedsReview),
            replacingContextualEvidence(
                exact,
                modelAvailability: .deviceNotEligible,
                acceptanceReason: .shadowModelUnavailable),
            replacingContextualEvidence(
                exact,
                modelFailure: .some(.guardrail),
                acceptanceReason: .shadowModelFailure),
            replacingContextualEvidence(
                exact,
                modelCandidateID: .some(nil),
                modelFailure: .some(.cancelled),
                acceptanceReason: .shadowModelFailure),
            replacingContextualEvidence(
                exact,
                modelCandidateID: "record.unknown"),
            replacingContextualEvidence(
                exact,
                familyState: .graduated),
            replacingContextualEvidence(
                exact,
                humanCandidateID: .some("record.noun")),
            replacingContextualEvidence(
                exact,
                humanCorrectionScope: .some("book")),
            replacingContextualEvidence(
                exact,
                isLimited: true),
        ]

        for evidence in malformed {
            #expect(throws: NarrationRenderPlanError.self) {
                _ = try NarrationRenderPlanner.make(
                    blocks: [block(id: "context", text: text, index: 0)],
                    overrides: PronunciationOverrides(entries: [:]),
                    contextualEvidence: [exactKey: evidence])
            }
        }
    }

    @Test func contextualEvidenceCannotAttachToExactOccurrenceOverride() throws {
        let sourceBlock = block(
            id: "context",
            text: "Please record this.",
            index: 0)
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: sourceBlock.text ?? "",
                blockID: sourceBlock.id
            ).first)
        let overrideResult = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: occurrence.blockID,
                wordStart: occurrence.wordStart,
                wordEnd: occurrence.wordEnd,
                word: occurrence.targetWord,
                ipa: "ɹəkˈɔɹd")
        ]).rewrite(
            to: sourceBlock.text ?? "",
            blockID: sourceBlock.id)
        var rewrittenBlock = sourceBlock
        rewrittenBlock.text = overrideResult.text
        let prepared = NarrationPreparedBlock(
            block: rewrittenBlock,
            pronunciationDecisionSeeds: overrideResult.decisionSeeds)
        let key = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)
        let evidence = contextualEvidence(for: occurrence, slot: .a)

        #expect(throws: NarrationRenderPlanError.self) {
            _ = try NarrationRenderPlanner.make(
                preparedBlocks: [prepared],
                overrides: PronunciationOverrides(entries: [:]),
                contextualEvidence: [key: evidence],
                requiresContextualEvidence: true)
        }

        let overrideOnlyPlan = try NarrationRenderPlanner.make(
            preparedBlocks: [prepared],
            overrides: PronunciationOverrides(entries: [:]),
            requiresContextualEvidence: true)
        let decision = try #require(
            overrideOnlyPlan.blocks.first?.pronunciationDecisions.first)
        #expect(decision.source == .occurrenceOverride)
        #expect(decision.contextualEvidence == nil)
        #expect(
            overrideOnlyPlan.pronunciationAuditDiagnostics.contains {
                $0.reason == .missingContextualEvidence
            } == false)
    }

    @Test func sharedOccurrenceIdentityMatchesTheLockedDiscoveryVector() throws {
        let expected = "ed3e920bcc956ebe419bfd4894cbc424262293101d20b8e8762aa66815e6f0d8"
        let discovered = try #require(
            ContextualPronunciationDiscovery.discover(
                text: "read",
                blockID: "b1"
            ).first)

        #expect(
            ContextualPronunciationOccurrenceID.make(
                blockID: "b1",
                wordStart: 0,
                wordEnd: 0,
                normalizedWord: "read")
                == expected)
        #expect(discovered.occurrenceID == expected)
    }

    @Test func evaluatedContextualDecisionWithoutEvidenceIsDiagnosed() throws {
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "missing", text: "Please record this.", index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            contextualEvidence: [:],
            requiresContextualEvidence: true)

        let decision = try #require(
            plan.blocks.first?.pronunciationDecisions.first {
                $0.normalizedWord == "record"
            })
        let diagnostic = try #require(
            plan.pronunciationAuditDiagnostics.first {
                $0.reason == .missingContextualEvidence
            })

        #expect(decision.contextualEvidence == nil)
        #expect(diagnostic.blockID == "missing")
        #expect(diagnostic.expectedDisplayText == "record")
    }

    @Test func frozenRetryAndTimingCopiesPreserveContextWithoutChangingSelectedIPA() throws {
        let text =
            "Please record this careful synthetic sentence, then continue with enough words "
            + "to force the immutable retry plan into more than one bounded slice."
        let occurrence = try #require(
            ContextualPronunciationDiscovery.discover(
                text: text,
                blockID: "retry"
            ).first)
        let evidence = contextualEvidence(for: occurrence, slot: .a)
        let key = ContextualPronunciationKey(
            blockID: occurrence.blockID,
            wordStart: occurrence.wordStart,
            wordEnd: occurrence.wordEnd)
        let plan = try NarrationRenderPlanner.make(
            blocks: [block(id: "retry", text: text, index: 0)],
            overrides: PronunciationOverrides(entries: [:]),
            contextualEvidence: [key: evidence])
        let planned = try #require(plan.blocks.first)
        let parent = try #require(planned.synthesisChunks.first)
        let decision = try #require(
            planned.pronunciationDecisions.first {
                $0.normalizedWord == "record"
            })
        let retrySlices = parent.frozenRetrySlices(maxPhonemes: 32)
        try #require(retrySlices.count > 1)

        let timed = decision.attachingRenderTiming(
            chapterIndex: 2,
            chapterRelativeAudioRange: .init(start: 1, end: 1.4),
            timingPrecision: .exactSynthesisWord
        )
        .attachingBookTiming(chapterIndex: 2, chapterOffset: 10)

        #expect(retrySlices.map(\.phonemes).joined() == parent.phonemes)
        #expect(
            retrySlices.flatMap { $0.phonemeIDs.dropFirst().dropLast() }
                == parent.phonemeIDs.dropFirst().dropLast())
        #expect(timed.contextualEvidence == evidence)
        #expect(timed.selectedIPA == decision.selectedIPA)
        #expect(timed.kokoroTokenIDs == decision.kokoroTokenIDs)
        #expect(timed.contextualEvidence?.modelCandidateID == "record.noun")
    }

    /// Builds a valid audit pack whose entries cover exactly `words`, cloning
    /// the bundled "record" entry's candidates so the pack's structural
    /// invariants (source roles, disagreement, Kokoro vocabulary) hold, then
    /// recomputing candidate IDs and digests for the new words.
    private func auditPack(
        coveringWords words: [String]
    ) throws -> EnglishPronunciationAuditPack {
        func digest(_ data: Data) -> String {
            "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func canonicalData(_ object: Any) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes])
        }

        let url = try #require(NarrationResources.url(
            forResource: "us_pronunciation_audit_pack", withExtension: "json"))
        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let entries = try #require(root["entries"] as? [String: Any])
        let donor = try #require(entries["record"] as? [String: Any])
        let donorCandidates = try #require(donor["candidates"] as? [[String: Any]])

        var clonedEntries: [String: Any] = [:]
        var candidateCount = 0
        for word in words {
            let candidates = try donorCandidates.map { candidate -> [String: Any] in
                var clone = candidate
                let sourceID = try #require(candidate["sourceID"] as? String)
                let ipa = try #require(candidate["ipa"] as? String)
                let idDigest = SHA256.hash(data: Data("\(sourceID)\0\(word)\0\(ipa)".utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                clone["candidateID"] = "\(sourceID).\(word).\(idDigest.prefix(12))"
                return clone
            }
            clonedEntries[word] = ["normalizedWord": word, "candidates": candidates]
            candidateCount += candidates.count
        }
        root["entries"] = clonedEntries
        root["entryCount"] = words.count
        root["candidateCount"] = candidateCount
        root["report"] = [
            "overlaps": words.count,
            "disagreements": words.count,
            "incompatible": 0,
        ]
        let entriesDigest = digest(try canonicalData(clonedEntries))
        root["normalizedDataSHA256"] = entriesDigest
        var identity = try #require(root["semanticIdentityPayload"] as? [String: Any])
        identity["normalizedDataSHA256"] = entriesDigest
        root["semanticIdentityPayload"] = identity
        root["auditPackVersion"] = digest(try canonicalData(identity))
        return try EnglishPronunciationAuditPack(data: try canonicalData(root))
    }

    private func contextualEvidence(
        for occurrence: ContextualPronunciationOccurrence,
        slot: ContextualCandidateSlot
    ) -> ContextualPronunciationEvidence {
        let modelCandidateID = occurrence.candidates.first { $0.slot == slot }?.candidateID
        return ContextualPronunciationEvidence(
            occurrenceID: occurrence.occurrenceID,
            familyID: occurrence.familyID,
            candidatePackVersion: ContextualPronunciationFamilies.candidatePackVersion,
            submittedCandidateIDs: occurrence.candidates.map(\.candidateID),
            deterministicCandidateID: occurrence.deterministicCandidateID,
            deterministicRuleID: occurrence.deterministicRuleID,
            deterministicStrength: occurrence.deterministicStrength,
            modelCandidateID: modelCandidateID,
            modelAbstained: slot == .needsReview,
            modelAvailability: .available,
            modelFailure: nil,
            familyState: .shadow,
            acceptanceReason: slot == .needsReview ? .shadowNeedsReview : .shadowObserved,
            promptSchemaVersion: ContextualPronunciationFamilies.promptSchemaVersion,
            platform: "test",
            osBuild: "test-build",
            qualifiedRuntimeFamilyID: "test-runtime",
            humanCandidateID: nil,
            humanCorrectionScope: nil,
            isLimited: false)
    }

    private func replacingContextualEvidence(
        _ evidence: ContextualPronunciationEvidence,
        occurrenceID: String? = nil,
        familyID: String? = nil,
        candidatePackVersion: String? = nil,
        submittedCandidateIDs: [String]? = nil,
        modelCandidateID: String?? = nil,
        modelAbstained: Bool? = nil,
        modelAvailability: ContextualModelAvailability? = nil,
        modelFailure: ContextualModelFailure?? = nil,
        familyState: ContextualFamilyState? = nil,
        acceptanceReason: ContextualAcceptanceReason? = nil,
        humanCandidateID: String?? = nil,
        humanCorrectionScope: String?? = nil,
        isLimited: Bool? = nil
    ) -> ContextualPronunciationEvidence {
        ContextualPronunciationEvidence(
            occurrenceID: occurrenceID ?? evidence.occurrenceID,
            familyID: familyID ?? evidence.familyID,
            candidatePackVersion: candidatePackVersion ?? evidence.candidatePackVersion,
            submittedCandidateIDs: submittedCandidateIDs ?? evidence.submittedCandidateIDs,
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
            platform: evidence.platform,
            osBuild: evidence.osBuild,
            qualifiedRuntimeFamilyID: evidence.qualifiedRuntimeFamilyID,
            humanCandidateID: humanCandidateID ?? evidence.humanCandidateID,
            humanCorrectionScope: humanCorrectionScope ?? evidence.humanCorrectionScope,
            isLimited: isLimited ?? evidence.isLimited)
    }
}
